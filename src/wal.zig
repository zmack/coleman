const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema");
const Table = @import("table").Table;

const MAGIC = "COLEMAN_WAL\x00";
const VERSION: u32 = 1;

pub const EntryType = enum(u8) {
    create_table = 1,
    add_record = 2,
};

pub const WALEntry = union(EntryType) {
    create_table: CreateTableEntry,
    add_record: AddRecordEntry,

    pub const CreateTableEntry = struct {
        table_name: []const u8,
        schema: schema.Schema,
    };

    pub const AddRecordEntry = struct {
        table_name: []const u8,
        values: []schema.Value,
    };
};

pub const WAL = struct {
    allocator: Allocator,
    file: std.fs.File,
    sequence: u64,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, path: []const u8) !*WAL {
        const wal = try allocator.create(WAL);
        errdefer allocator.destroy(wal);

        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();

        // Read existing sequence number or write header
        const file_size = try file.getEndPos();
        var sequence: u64 = 0;

        if (file_size == 0) {
            // New file - write header
            try file.writeAll(MAGIC);
            var version_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &version_bytes, VERSION, .little);
            try file.writeAll(&version_bytes);
        } else {
            // Existing file - verify header and scan for last sequence
            var magic_buf: [MAGIC.len]u8 = undefined;
            _ = try file.readAll(&magic_buf);
            if (!std.mem.eql(u8, &magic_buf, MAGIC)) {
                return error.InvalidWALMagic;
            }

            var version_bytes: [4]u8 = undefined;
            _ = try file.readAll(&version_bytes);
            const version = std.mem.readInt(u32, &version_bytes, .little);
            if (version != VERSION) {
                return error.InvalidWALVersion;
            }

            // Scan entries to find the last sequence number
            sequence = try scanLastSequence(file);
        }

        wal.* = .{
            .allocator = allocator,
            .file = file,
            .sequence = sequence,
            .mutex = .{},
        };

        return wal;
    }

    pub fn deinit(self: *WAL) void {
        self.file.close();
        self.allocator.destroy(self);
    }

    pub fn append(self: *WAL, entry: WALEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.sequence += 1;
        const seq = self.sequence;

        // Seek to end of file
        try self.file.seekFromEnd(0);

        // Write sequence number
        var seq_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_bytes, seq, .little);
        try self.file.writeAll(&seq_bytes);

        // Serialize entry
        var data_buffer: std.ArrayList(u8) = .{};
        defer data_buffer.deinit(self.allocator);

        const writer = data_buffer.writer(self.allocator);

        switch (entry) {
            .create_table => |ct| {
                try writer.writeByte(@intFromEnum(EntryType.create_table));
                try writeString(writer, ct.table_name);
                try writeSchema(writer, ct.schema);
            },
            .add_record => |ar| {
                try writer.writeByte(@intFromEnum(EntryType.add_record));
                try writeString(writer, ar.table_name);
                try writeValues(writer, ar.values);
            },
        }

        const data = data_buffer.items;

        // Write data length and data
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .little);
        try self.file.writeAll(&len_bytes);
        try self.file.writeAll(data);

        // Calculate and write CRC32
        const crc = std.hash.Crc32.hash(data);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc, .little);
        try self.file.writeAll(&crc_bytes);

        // Sync to disk
        try self.file.sync();
    }

    pub fn replay(self: *WAL, callback: *const fn (entry: WALEntry, allocator: Allocator) anyerror!void, allocator: Allocator) !void {
        try self.file.seekTo(MAGIC.len + 4); // Skip header

        while (true) {
            // Read sequence
            var seq_bytes: [8]u8 = undefined;
            _ = self.file.readAll(&seq_bytes) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const seq = std.mem.readInt(u64, &seq_bytes, .little);
            _ = seq;

            // Read data length
            var len_bytes: [4]u8 = undefined;
            _ = try self.file.readAll(&len_bytes);
            const data_len = std.mem.readInt(u32, &len_bytes, .little);

            // Read data
            const data = try allocator.alloc(u8, data_len);
            defer allocator.free(data);
            _ = try self.file.readAll(data);

            // Read and verify CRC32
            var crc_bytes: [4]u8 = undefined;
            _ = try self.file.readAll(&crc_bytes);
            const stored_crc = std.mem.readInt(u32, &crc_bytes, .little);
            const computed_crc = std.hash.Crc32.hash(data);
            if (stored_crc != computed_crc) {
                return error.WALCorruption;
            }

            // Parse entry
            var stream = std.io.fixedBufferStream(data);
            const reader = stream.reader();

            const entry_type_byte = try reader.readByte();
            const entry_type = std.meta.intToEnum(EntryType, entry_type_byte) catch {
                return error.InvalidEntryType;
            };

            const entry = switch (entry_type) {
                .create_table => blk: {
                    const table_name = try readString(reader, allocator);
                    const sch = try readSchema(reader, allocator);
                    break :blk WALEntry{
                        .create_table = .{
                            .table_name = table_name,
                            .schema = sch,
                        },
                    };
                },
                .add_record => blk: {
                    const table_name = try readString(reader, allocator);
                    const values = try readValues(reader, allocator);
                    break :blk WALEntry{
                        .add_record = .{
                            .table_name = table_name,
                            .values = values,
                        },
                    };
                },
            };

            try callback(entry, allocator);
        }
    }

    pub fn truncate(self: *WAL) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.file.setEndPos(MAGIC.len + 4); // Keep only header
        self.sequence = 0;
        try self.file.sync();
    }
};

fn scanLastSequence(file: std.fs.File) !u64 {
    var last_seq: u64 = 0;

    while (true) {
        var seq_bytes: [8]u8 = undefined;
        _ = file.readAll(&seq_bytes) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        const seq = std.mem.readInt(u64, &seq_bytes, .little);

        last_seq = seq;

        var len_bytes: [4]u8 = undefined;
        _ = try file.readAll(&len_bytes);
        const data_len = std.mem.readInt(u32, &len_bytes, .little);
        try file.seekBy(@intCast(data_len + 4)); // Skip data + CRC
    }

    return last_seq;
}

fn writeString(writer: anytype, s: []const u8) !void {
    try writer.writeInt(u32, @intCast(s.len), .little);
    try writer.writeAll(s);
}

fn readString(reader: anytype, allocator: Allocator) ![]u8 {
    const len = try reader.readInt(u32, .little);
    const s = try allocator.alloc(u8, len);
    _ = try reader.readAll(s);
    return s;
}

fn writeSchema(writer: anytype, sch: schema.Schema) !void {
    try writer.writeInt(u32, @intCast(sch.columns.len), .little);
    for (sch.columns) |col| {
        try writeString(writer, col.name);
        try writer.writeByte(@intFromEnum(col.column_type));
    }
}

fn readSchema(reader: anytype, allocator: Allocator) !schema.Schema {
    const num_columns = try reader.readInt(u32, .little);
    const columns = try allocator.alloc(schema.ColumnDef, num_columns);

    for (columns) |*col| {
        const name = try readString(reader, allocator);
        const type_byte = try reader.readByte();
        const col_type = std.meta.intToEnum(schema.ColumnType, type_byte) catch {
            return error.InvalidColumnType;
        };
        col.* = .{ .name = name, .column_type = col_type };
    }

    return schema.Schema{ .columns = columns, .allocator = allocator };
}

fn writeValues(writer: anytype, values: []schema.Value) !void {
    try writer.writeInt(u32, @intCast(values.len), .little);
    for (values) |val| {
        try writeValue(writer, val);
    }
}

fn readValues(reader: anytype, allocator: Allocator) ![]schema.Value {
    const num_values = try reader.readInt(u32, .little);
    const values = try allocator.alloc(schema.Value, num_values);

    for (values) |*val| {
        val.* = try readValue(reader, allocator);
    }

    return values;
}

fn writeValue(writer: anytype, val: schema.Value) !void {
    if (val.int_value) |v| {
        try writer.writeByte(1);
        try writer.writeInt(i64, v, .little);
    } else if (val.float_value) |v| {
        try writer.writeByte(2);
        try writer.writeInt(u64, @bitCast(v), .little);
    } else if (val.string_value) |v| {
        try writer.writeByte(3);
        try writeString(writer, v);
    } else if (val.bool_value) |v| {
        try writer.writeByte(4);
        try writer.writeByte(if (v) 1 else 0);
    } else {
        return error.InvalidValue;
    }
}

fn readValue(reader: anytype, allocator: Allocator) !schema.Value {
    const type_byte = try reader.readByte();
    return switch (type_byte) {
        1 => .{ .int_value = try reader.readInt(i64, .little) },
        2 => blk: {
            const bits = try reader.readInt(u64, .little);
            break :blk schema.Value{ .float_value = @bitCast(bits) };
        },
        3 => .{ .string_value = try readString(reader, allocator) },
        4 => .{ .bool_value = (try reader.readByte()) != 0 },
        else => error.InvalidValueType,
    };
}
