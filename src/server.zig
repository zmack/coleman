const std = @import("std");
const grpc = @import("grpc");
const log_proto = @import("proto/log.pb.zig");
const schema = @import("schema");
const table = @import("table");
const table_manager = @import("table_manager");

// Global table manager
var g_table_manager: table_manager.TableManager = undefined;
var gpa_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    g_table_manager = table_manager.TableManager.init(allocator);
    gpa_allocator = allocator;
}

pub fn deinit() void {
    g_table_manager.deinit();
}

// Legacy key-value storage handlers (kept for backwards compatibility)
// Note: These are not used with the new columnar storage system
fn handlePut(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = input;
    _ = allocator;
    return error.NotImplemented;
}

fn handleGet(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = input;
    _ = allocator;
    return error.NotImplemented;
}

// Helper function to convert protobuf ColumnType to schema.ColumnType
fn protoColumnTypeToSchema(proto_type: log_proto.ColumnType) !schema.ColumnType {
    return switch (proto_type) {
        .INT64 => .int64,
        .FLOAT64 => .float64,
        .STRING => .string,
        .BOOL => .bool,
    };
}

// Helper function to convert protobuf Value to table.Value
fn protoValueToTable(allocator: std.mem.Allocator, proto_value: log_proto.Value) !table.Value {
    if (proto_value.int64_value) |v| return table.Value.fromInt64(v);
    if (proto_value.float64_value) |v| return table.Value.fromFloat64(v);
    if (proto_value.string_value.len > 0) return table.Value.fromString(try allocator.dupe(u8, proto_value.string_value));
    if (proto_value.bool_value) |v| return table.Value.fromBool(v);
    return error.InvalidValue;
}

// Helper function to convert table.Value to protobuf Value
fn tableValueToProto(value: table.Value) log_proto.Value {
    return switch (value) {
        .int64 => |v| .{ .int64_value = v },
        .float64 => |v| .{ .float64_value = v },
        .string => |v| .{ .string_value = v },
        .bool => |v| .{ .bool_value = v },
    };
}

fn handleCreateTable(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    var any_reader = reader.any();

    const req = try log_proto.CreateTableRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);

    // Build schema from protobuf schema
    var cols: std.ArrayList(schema.ColumnDef) = .{};
    defer cols.deinit(allocator);

    if (req.schema) |proto_schema| {
        for (proto_schema.columns.items) |col_def| {
            const col_type = try protoColumnTypeToSchema(col_def.type);
            try cols.append(allocator, schema.ColumnDef.init(col_def.name, col_type));
        }
    }

    var table_schema = try schema.Schema.init(allocator, cols.items);
    errdefer table_schema.deinit();

    // Create table
    g_table_manager.createTable(req.table_name, table_schema) catch |err| {
        table_schema.deinit();
        var res = log_proto.CreateTableResponse{
            .success = false,
            .error_msg = @errorName(err),
        };
        var out_list: std.ArrayList(u8) = .{};
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    };

    var res = log_proto.CreateTableResponse{ .success = true };
    var out_list: std.ArrayList(u8) = .{};
    const writer = out_list.writer(allocator);
    try res.encode(&writer, allocator);
    return out_list.toOwnedSlice(allocator);
}

fn handleAddRecord(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    var any_reader = reader.any();

    const req = try log_proto.AddRecordRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);

    // Convert protobuf values to table values
    var values: std.ArrayList(table.Value) = .{};
    defer {
        for (values.items) |*val| {
            switch (val.*) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        values.deinit(allocator);
    }

    for (req.values.items) |proto_val| {
        const val = try protoValueToTable(allocator, proto_val);
        try values.append(allocator, val);
    }

    // Add record
    g_table_manager.addRecord(req.table_name, values.items) catch |err| {
        var res = log_proto.AddRecordResponse{
            .success = false,
            .error_msg = @errorName(err),
        };
        var out_list: std.ArrayList(u8) = .{};
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    };

    var res = log_proto.AddRecordResponse{ .success = true };
    var out_list: std.ArrayList(u8) = .{};
    const writer = out_list.writer(allocator);
    try res.encode(&writer, allocator);
    return out_list.toOwnedSlice(allocator);
}

fn handleScan(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    var any_reader = reader.any();

    const req = try log_proto.ScanRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);

    // Scan table
    const rows = g_table_manager.scan(allocator, req.table_name) catch |err| {
        var res = log_proto.ScanResponse{
            .error_msg = @errorName(err),
        };
        var out_list: std.ArrayList(u8) = .{};
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    };
    defer {
        for (rows) |row| {
            allocator.free(row);
        }
        allocator.free(rows);
    }

    // Convert to protobuf records ArrayList
    var records: std.ArrayList(log_proto.Record) = .{};
    defer {
        for (records.items) |*record| {
            record.values.deinit(allocator);
        }
        records.deinit(allocator);
    }

    for (rows) |row| {
        var proto_values: std.ArrayList(log_proto.Value) = .{};
        for (row) |val| {
            try proto_values.append(allocator, tableValueToProto(val));
        }
        try records.append(allocator, log_proto.Record{ .values = proto_values });
    }

    var res = log_proto.ScanResponse{ .records = records };
    var out_list: std.ArrayList(u8) = .{};
    const writer = out_list.writer(allocator);
    try res.encode(&writer, allocator);

    return out_list.toOwnedSlice(allocator);
}

pub fn runServer(limit: ?usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    init(allocator);
    defer deinit();

    var server = try grpc.GrpcServer.init(allocator, 50051, "secret-key", limit);
    defer server.deinit();

    // Legacy handlers (not implemented in columnar version)
    try server.handlers.append(allocator, .{
        .name = "log.LogService/Put",
        .handler_fn = handlePut,
    });

    try server.handlers.append(allocator, .{
        .name = "log.LogService/Get",
        .handler_fn = handleGet,
    });

    // New columnar storage handlers
    try server.handlers.append(allocator, .{
        .name = "log.LogService/CreateTable",
        .handler_fn = handleCreateTable,
    });

    try server.handlers.append(allocator, .{
        .name = "log.LogService/AddRecord",
        .handler_fn = handleAddRecord,
    });

    try server.handlers.append(allocator, .{
        .name = "log.LogService/Scan",
        .handler_fn = handleScan,
    });

    try server.start();
}
