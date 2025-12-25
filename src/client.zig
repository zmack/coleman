const std = @import("std");
const grpc = @import("grpc");
const log_proto = @import("proto/log.pb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    // Set authentication
    try client.setAuth("secret-key");

    std.debug.print("\n=== Coleman Columnar Storage Test ===\n\n", .{});

    // CreateTable Operation
    std.debug.print("1. Creating table 'users'...\n", .{});
    {
        // Build schema
        var columns: std.ArrayList(log_proto.ColumnDef) = .{};
        defer columns.deinit(allocator);

        try columns.append(allocator, .{
            .name = "id",
            .type = .INT64,
        });
        try columns.append(allocator, .{
            .name = "name",
            .type = .STRING,
        });
        try columns.append(allocator, .{
            .name = "age",
            .type = .INT64,
        });
        try columns.append(allocator, .{
            .name = "score",
            .type = .FLOAT64,
        });

        var req = log_proto.CreateTableRequest{
            .table_name = "users",
            .schema = .{ .columns = columns },
        };

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);

        const response_bytes = try client.call("log.LogService/CreateTable", list.items, .none);
        defer allocator.free(response_bytes);

        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.CreateTableResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);

        if (res.success) {
            std.debug.print("   ✓ Table created successfully!\n\n", .{});
        } else {
            std.debug.print("   ✗ Failed: {s}\n\n", .{res.error_msg});
        }
    }

    // AddRecord Operation - Record 1
    std.debug.print("2. Adding record 1: Alice, age 30, score 95.5\n", .{});
    {
        var values: std.ArrayList(log_proto.Value) = .{};
        defer values.deinit(allocator);

        try values.append(allocator, .{ .int64_value = 1 });
        try values.append(allocator, .{ .string_value = "Alice" });
        try values.append(allocator, .{ .int64_value = 30 });
        try values.append(allocator, .{ .float64_value = 95.5 });

        var req = log_proto.AddRecordRequest{
            .table_name = "users",
            .values = values,
        };

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);

        const response_bytes = try client.call("log.LogService/AddRecord", list.items, .none);
        defer allocator.free(response_bytes);

        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.AddRecordResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);

        if (res.success) {
            std.debug.print("   ✓ Record added successfully!\n\n", .{});
        } else {
            std.debug.print("   ✗ Failed: {s}\n\n", .{res.error_msg});
        }
    }

    // AddRecord Operation - Record 2
    std.debug.print("3. Adding record 2: Bob, age 25, score 87.3\n", .{});
    {
        var values: std.ArrayList(log_proto.Value) = .{};
        defer values.deinit(allocator);

        try values.append(allocator, .{ .int64_value = 2 });
        try values.append(allocator, .{ .string_value = "Bob" });
        try values.append(allocator, .{ .int64_value = 25 });
        try values.append(allocator, .{ .float64_value = 87.3 });

        var req = log_proto.AddRecordRequest{
            .table_name = "users",
            .values = values,
        };

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);

        const response_bytes = try client.call("log.LogService/AddRecord", list.items, .none);
        defer allocator.free(response_bytes);

        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.AddRecordResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);

        if (res.success) {
            std.debug.print("   ✓ Record added successfully!\n\n", .{});
        } else {
            std.debug.print("   ✗ Failed: {s}\n\n", .{res.error_msg});
        }
    }

    // AddRecord Operation - Record 3
    std.debug.print("4. Adding record 3: Charlie, age 35, score 92.1\n", .{});
    {
        var values: std.ArrayList(log_proto.Value) = .{};
        defer values.deinit(allocator);

        try values.append(allocator, .{ .int64_value = 3 });
        try values.append(allocator, .{ .string_value = "Charlie" });
        try values.append(allocator, .{ .int64_value = 35 });
        try values.append(allocator, .{ .float64_value = 92.1 });

        var req = log_proto.AddRecordRequest{
            .table_name = "users",
            .values = values,
        };

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);

        const response_bytes = try client.call("log.LogService/AddRecord", list.items, .none);
        defer allocator.free(response_bytes);

        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.AddRecordResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);

        if (res.success) {
            std.debug.print("   ✓ Record added successfully!\n\n", .{});
        } else {
            std.debug.print("   ✗ Failed: {s}\n\n", .{res.error_msg});
        }
    }

    // Scan Operation
    std.debug.print("5. Scanning all records from 'users' table...\n", .{});
    {
        var req = log_proto.ScanRequest{
            .table_name = "users",
        };

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);

        const response_bytes = try client.call("log.LogService/Scan", list.items, .none);
        defer allocator.free(response_bytes);

        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.ScanResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);

        if (res.error_msg.len > 0) {
            std.debug.print("   ✗ Scan failed: {s}\n\n", .{res.error_msg});
        } else {
            std.debug.print("   ✓ Found {} records:\n", .{res.records.items.len});
            std.debug.print("   | ID | Name    | Age | Score |\n", .{});
            std.debug.print("   |----|---------|-----|-------|\n", .{});

            for (res.records.items) |record| {
                const id = record.values.items[0].int64_value orelse 0;
                const name = record.values.items[1].string_value;
                const age = record.values.items[2].int64_value orelse 0;
                const score = record.values.items[3].float64_value orelse 0.0;

                std.debug.print("   | {d:2} | {s: <7} | {d:3} | {d:5.1} |\n", .{ id, name, age, score });
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("=== Test Complete ===\n", .{});
}
