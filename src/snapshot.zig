const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema");
const Table = @import("table").Table;
const Value = @import("table").Value;

const MAGIC = "COLEMAN_SNAP";
const VERSION: u32 = 1;

pub const SnapshotManager = struct {
    allocator: Allocator,
    snapshot_dir: []const u8,

    pub fn init(allocator: Allocator, snapshot_dir: []const u8) !*SnapshotManager {
        const mgr = try allocator.create(SnapshotManager);
        errdefer allocator.destroy(mgr);

        // Create snapshot directory if it doesn't exist
        std.fs.cwd().makeDir(snapshot_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const owned_dir = try allocator.dupe(u8, snapshot_dir);

        mgr.* = .{
            .allocator = allocator,
            .snapshot_dir = owned_dir,
        };

        return mgr;
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.allocator.free(self.snapshot_dir);
        self.allocator.destroy(self);
    }

    pub fn save(self: *SnapshotManager, tables: anytype) !void {
        // Create temporary snapshot file
        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/snapshot.tmp",
            .{self.snapshot_dir},
        );
        defer self.allocator.free(temp_path);

        const final_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/snapshot.dat",
            .{self.snapshot_dir},
        );
        defer self.allocator.free(final_path);

        // Write to temp file
        const file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        defer file.close();

        // Write header
        try file.writeAll(MAGIC);
        var version_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &version_bytes, VERSION, .little);
        try file.writeAll(&version_bytes);

        // Count tables
        var table_count: u32 = 0;
        var iter = tables.valueIterator();
        while (iter.next()) |_| {
            table_count += 1;
        }

        // Write table count
        var count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_bytes, table_count, .little);
        try file.writeAll(&count_bytes);

        // Write each table
        var table_iter = tables.valueIterator();
        while (table_iter.next()) |table_ptr_ptr| {
            try writeTable(file, table_ptr_ptr.*.*, self.allocator);
        }

        // Sync and close
        try file.sync();

        // Atomic rename
        try std.fs.cwd().rename(temp_path, final_path);
    }

    pub fn load(self: *SnapshotManager, table_loader: *const fn (table: Table) anyerror!void) !void {
        const snapshot_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/snapshot.dat",
            .{self.snapshot_dir},
        );
        defer self.allocator.free(snapshot_path);

        // Check if snapshot exists
        const file = std.fs.cwd().openFile(snapshot_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No snapshot - that's ok
                return;
            }
            return err;
        };
        defer file.close();

        // Read and verify header
        var magic_buf: [MAGIC.len]u8 = undefined;
        _ = try file.readAll(&magic_buf);
        if (!std.mem.eql(u8, &magic_buf, MAGIC)) {
            return error.InvalidSnapshotMagic;
        }

        var version_bytes: [4]u8 = undefined;
        _ = try file.readAll(&version_bytes);
        const version = std.mem.readInt(u32, &version_bytes, .little);
        if (version != VERSION) {
            return error.InvalidSnapshotVersion;
        }

        // Read table count
        var count_bytes: [4]u8 = undefined;
        _ = try file.readAll(&count_bytes);
        const table_count = std.mem.readInt(u32, &count_bytes, .little);

        // Load each table
        var i: u32 = 0;
        while (i < table_count) : (i += 1) {
            const table = try readTable(file, self.allocator);
            try table_loader(table);
        }
    }

    pub fn exists(self: *SnapshotManager) bool {
        const snapshot_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/snapshot.dat",
            .{self.snapshot_dir},
        ) catch return false;
        defer self.allocator.free(snapshot_path);

        std.fs.cwd().access(snapshot_path, .{}) catch return false;
        return true;
    }
};

fn writeTable(file: std.fs.File, table: Table, allocator: Allocator) !void {
    // Write table name
    try writeString(file, table.name);

    // Write schema
    try writeSchema(file, table.table_schema);

    // Write row count
    var row_count_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &row_count_bytes, @intCast(table.row_count), .little);
    try file.writeAll(&row_count_bytes);

    // Write all rows
    var row: usize = 0;
    while (row < table.row_count) : (row += 1) {
        const values = try table.getRow(allocator, row);
        defer allocator.free(values);

        for (values) |val| {
            try writeValue(file, val);
        }
    }
}

fn readTable(file: std.fs.File, allocator: Allocator) !Table {
    // Read table name
    const name = try readString(file, allocator);
    errdefer allocator.free(name);

    // Read schema
    var table_schema = try readSchema(file, allocator);
    errdefer table_schema.deinit();

    // Create table
    var table = try Table.init(allocator, name, table_schema);
    errdefer table.deinit();

    // Read row count
    var row_count_bytes: [8]u8 = undefined;
    _ = try file.readAll(&row_count_bytes);
    const row_count = std.mem.readInt(u64, &row_count_bytes, .little);

    // Read all rows
    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        const values = try allocator.alloc(Value, table.columns.len);
        defer allocator.free(values);

        for (values) |*val| {
            val.* = try readValue(file, allocator);
        }

        try table.addRecord(values);
    }

    return table;
}

fn writeString(file: std.fs.File, s: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(s.len), .little);
    try file.writeAll(&len_bytes);
    try file.writeAll(s);
}

fn readString(file: std.fs.File, allocator: Allocator) ![]u8 {
    var len_bytes: [4]u8 = undefined;
    _ = try file.readAll(&len_bytes);
    const len = std.mem.readInt(u32, &len_bytes, .little);
    const s = try allocator.alloc(u8, len);
    _ = try file.readAll(s);
    return s;
}

fn writeSchema(file: std.fs.File, sch: schema.Schema) !void {
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(sch.columns.len), .little);
    try file.writeAll(&count_bytes);
    for (sch.columns) |col| {
        try writeString(file, col.name);
        const type_byte = [1]u8{@intFromEnum(col.column_type)};
        try file.writeAll(&type_byte);
    }
}

fn readSchema(file: std.fs.File, allocator: Allocator) !schema.Schema {
    var count_bytes: [4]u8 = undefined;
    _ = try file.readAll(&count_bytes);
    const num_columns = std.mem.readInt(u32, &count_bytes, .little);
    const columns = try allocator.alloc(schema.ColumnDef, num_columns);

    for (columns) |*col| {
        const name = try readString(file, allocator);
        var type_byte_buf: [1]u8 = undefined;
        _ = try file.readAll(&type_byte_buf);
        const col_type = std.meta.intToEnum(schema.ColumnType, type_byte_buf[0]) catch {
            return error.InvalidColumnType;
        };
        col.* = .{ .name = name, .column_type = col_type };
    }

    return schema.Schema{ .columns = columns, .allocator = allocator };
}

fn writeValue(file: std.fs.File, val: Value) !void {
    switch (val) {
        .int64 => |v| {
            const type_byte = [1]u8{1};
            try file.writeAll(&type_byte);
            var val_bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &val_bytes, v, .little);
            try file.writeAll(&val_bytes);
        },
        .float64 => |v| {
            const type_byte = [1]u8{2};
            try file.writeAll(&type_byte);
            var val_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &val_bytes, @bitCast(v), .little);
            try file.writeAll(&val_bytes);
        },
        .string => |v| {
            const type_byte = [1]u8{3};
            try file.writeAll(&type_byte);
            try writeString(file, v);
        },
        .bool => |v| {
            const type_byte = [1]u8{4};
            try file.writeAll(&type_byte);
            const val_byte = [1]u8{if (v) 1 else 0};
            try file.writeAll(&val_byte);
        },
    }
}

fn readValue(file: std.fs.File, allocator: Allocator) !Value {
    var type_byte_buf: [1]u8 = undefined;
    _ = try file.readAll(&type_byte_buf);
    const type_byte = type_byte_buf[0];
    return switch (type_byte) {
        1 => blk: {
            var val_bytes: [8]u8 = undefined;
            _ = try file.readAll(&val_bytes);
            break :blk Value{ .int64 = std.mem.readInt(i64, &val_bytes, .little) };
        },
        2 => blk: {
            var val_bytes: [8]u8 = undefined;
            _ = try file.readAll(&val_bytes);
            const bits = std.mem.readInt(u64, &val_bytes, .little);
            break :blk Value{ .float64 = @bitCast(bits) };
        },
        3 => .{ .string = try readString(file, allocator) },
        4 => blk: {
            var val_byte_buf: [1]u8 = undefined;
            _ = try file.readAll(&val_byte_buf);
            break :blk Value{ .bool = val_byte_buf[0] != 0 };
        },
        else => error.InvalidValueType,
    };
}
