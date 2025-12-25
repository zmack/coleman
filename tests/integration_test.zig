const std = @import("std");
const grpc = @import("grpc");
const log_proto = @import("proto");

// Integration tests for the full gRPC flow
// These tests require the server to be running on port 50051

test "Integration: CreateTable, AddRecord, and Scan flow" {
    const allocator = std.testing.allocator;

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    try client.setAuth("secret-key");

    // Generate unique table name for this test
    var buf: [64]u8 = undefined;
    const timestamp = std.time.milliTimestamp();
    const table_name = try std.fmt.bufPrint(&buf, "test_table_{d}", .{timestamp});

    // Step 1: Create Table
    {
        var columns: std.ArrayList(log_proto.ColumnDef) = .{};
        defer columns.deinit(allocator);

        try columns.append(allocator, .{ .name = "id", .type = .INT64 });
        try columns.append(allocator, .{ .name = "name", .type = .STRING });
        try columns.append(allocator, .{ .name = "age", .type = .INT64 });

        var req = log_proto.CreateTableRequest{
            .table_name = table_name,
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

        try std.testing.expect(res.success);
    }

    // Step 2: Add Records
    {
        // Add first record
        var values1: std.ArrayList(log_proto.Value) = .{};
        defer values1.deinit(allocator);

        try values1.append(allocator, .{ .int64_value = 1 });
        try values1.append(allocator, .{ .string_value = "Alice" });
        try values1.append(allocator, .{ .int64_value = 30 });

        var req1 = log_proto.AddRecordRequest{
            .table_name = table_name,
            .values = values1,
        };

        var list1: std.ArrayList(u8) = .{};
        defer list1.deinit(allocator);
        const writer1 = list1.writer(allocator);
        try req1.encode(&writer1, allocator);

        const response_bytes1 = try client.call("log.LogService/AddRecord", list1.items, .none);
        defer allocator.free(response_bytes1);

        var stream1 = std.io.fixedBufferStream(response_bytes1);
        var reader1 = stream1.reader();
        var any_reader1 = reader1.any();
        const res1 = try log_proto.AddRecordResponse.decode(&any_reader1, allocator);
        var mutable_res1 = res1;
        defer mutable_res1.deinit(allocator);

        try std.testing.expect(res1.success);

        // Add second record
        var values2: std.ArrayList(log_proto.Value) = .{};
        defer values2.deinit(allocator);

        try values2.append(allocator, .{ .int64_value = 2 });
        try values2.append(allocator, .{ .string_value = "Bob" });
        try values2.append(allocator, .{ .int64_value = 25 });

        var req2 = log_proto.AddRecordRequest{
            .table_name = table_name,
            .values = values2,
        };

        var list2: std.ArrayList(u8) = .{};
        defer list2.deinit(allocator);
        const writer2 = list2.writer(allocator);
        try req2.encode(&writer2, allocator);

        const response_bytes2 = try client.call("log.LogService/AddRecord", list2.items, .none);
        defer allocator.free(response_bytes2);

        var stream2 = std.io.fixedBufferStream(response_bytes2);
        var reader2 = stream2.reader();
        var any_reader2 = reader2.any();
        const res2 = try log_proto.AddRecordResponse.decode(&any_reader2, allocator);
        var mutable_res2 = res2;
        defer mutable_res2.deinit(allocator);

        try std.testing.expect(res2.success);
    }

    // Step 3: Scan and Verify
    {
        var req = log_proto.ScanRequest{
            .table_name = table_name,
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

        try std.testing.expectEqual(@as(usize, 0), res.error_msg.len);
        try std.testing.expectEqual(@as(usize, 2), res.records.items.len);

        // Verify first record
        const record1 = res.records.items[0];
        try std.testing.expectEqual(@as(i64, 1), record1.values.items[0].int64_value.?);
        try std.testing.expectEqualStrings("Alice", record1.values.items[1].string_value);
        try std.testing.expectEqual(@as(i64, 30), record1.values.items[2].int64_value.?);

        // Verify second record
        const record2 = res.records.items[1];
        try std.testing.expectEqual(@as(i64, 2), record2.values.items[0].int64_value.?);
        try std.testing.expectEqualStrings("Bob", record2.values.items[1].string_value);
        try std.testing.expectEqual(@as(i64, 25), record2.values.items[2].int64_value.?);
    }
}

test "Integration: CreateTable with duplicate name fails" {
    const allocator = std.testing.allocator;

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    try client.setAuth("secret-key");

    var buf: [64]u8 = undefined;
    const timestamp = std.time.milliTimestamp();
    const table_name = try std.fmt.bufPrint(&buf, "dup_test_{d}", .{timestamp});

    // Create table first time
    {
        var columns: std.ArrayList(log_proto.ColumnDef) = .{};
        defer columns.deinit(allocator);
        try columns.append(allocator, .{ .name = "id", .type = .INT64 });

        var req = log_proto.CreateTableRequest{
            .table_name = table_name,
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

        try std.testing.expect(res.success);
    }

    // Try to create same table again
    {
        var columns: std.ArrayList(log_proto.ColumnDef) = .{};
        defer columns.deinit(allocator);
        try columns.append(allocator, .{ .name = "id", .type = .INT64 });

        var req = log_proto.CreateTableRequest{
            .table_name = table_name,
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

        try std.testing.expect(!res.success);
        try std.testing.expect(res.error_msg.len > 0);
    }
}

test "Integration: AddRecord with wrong column count fails" {
    const allocator = std.testing.allocator;

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    try client.setAuth("secret-key");

    var buf: [64]u8 = undefined;
    const timestamp = std.time.milliTimestamp();
    const table_name = try std.fmt.bufPrint(&buf, "mismatch_test_{d}", .{timestamp});

    // Create table with 2 columns
    {
        var columns: std.ArrayList(log_proto.ColumnDef) = .{};
        defer columns.deinit(allocator);
        try columns.append(allocator, .{ .name = "id", .type = .INT64 });
        try columns.append(allocator, .{ .name = "name", .type = .STRING });

        var req = log_proto.CreateTableRequest{
            .table_name = table_name,
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

        try std.testing.expect(res.success);
    }

    // Try to add record with only 1 value (should be 2)
    {
        var values: std.ArrayList(log_proto.Value) = .{};
        defer values.deinit(allocator);
        try values.append(allocator, .{ .int64_value = 1 });
        // Missing second value

        var req = log_proto.AddRecordRequest{
            .table_name = table_name,
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

        try std.testing.expect(!res.success);
        try std.testing.expect(res.error_msg.len > 0);
    }
}

test "Integration: Scan non-existent table fails" {
    const allocator = std.testing.allocator;

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    try client.setAuth("secret-key");

    var req = log_proto.ScanRequest{
        .table_name = "nonexistent_table_12345",
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

    try std.testing.expect(res.error_msg.len > 0);
}
