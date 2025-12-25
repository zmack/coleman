const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const table = @import("table");
const table_manager = @import("table_manager");
const config = @import("config");
const pb = @import("proto");

test "filter: basic equality on int64" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_eq_int64.wal",
        .snapshot_dir = ".zig-cache/filter_eq_int64_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("age", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("users", table_schema);

    try tm.addRecord("users", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(25) });
    try tm.addRecord("users", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(30) });
    try tm.addRecord("users", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(25) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "age", .operator = .EQUAL, .value = pb.Value{ .int64_value = 25 } });

    const rows = try tm.filter(allocator, "users", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(i64, 1), rows[0][0].int64);
    try testing.expectEqual(@as(i64, 25), rows[0][1].int64);
}

test "filter: greater than on int64" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_gt_int64.wal",
        .snapshot_dir = ".zig-cache/filter_gt_int64_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("score", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("scores", table_schema);

    try tm.addRecord("scores", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(50) });
    try tm.addRecord("scores", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(75) });
    try tm.addRecord("scores", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(90) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "score", .operator = .GREATER_THAN, .value = pb.Value{ .int64_value = 60 } });

    const rows = try tm.filter(allocator, "scores", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(i64, 75), rows[0][1].int64);
    try testing.expectEqual(@as(i64, 90), rows[1][1].int64);
}

test "filter: multiple predicates (AND logic)" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_multi_pred.wal",
        .snapshot_dir = ".zig-cache/filter_multi_pred_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("age", .int64),
        schema.ColumnDef.init("score", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("students", table_schema);

    try tm.addRecord("students", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(25), table.Value.fromInt64(85) });
    try tm.addRecord("students", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(30), table.Value.fromInt64(95) });
    try tm.addRecord("students", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(28), table.Value.fromInt64(70) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "age", .operator = .GREATER_THAN_OR_EQUAL, .value = pb.Value{ .int64_value = 28 } });
    try predicates.append(allocator, .{ .column_name = "score", .operator = .GREATER_THAN_OR_EQUAL, .value = pb.Value{ .int64_value = 85 } });

    const rows = try tm.filter(allocator, "students", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(i64, 2), rows[0][0].int64);
}

test "filter: string equality" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_eq_string.wal",
        .snapshot_dir = ".zig-cache/filter_eq_string_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("people", table_schema);

    const name1 = try allocator.dupe(u8, "Alice");
    const name2 = try allocator.dupe(u8, "Bob");
    const name3 = try allocator.dupe(u8, "Alice");

    try tm.addRecord("people", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromString(name1) });
    try tm.addRecord("people", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromString(name2) });
    try tm.addRecord("people", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromString(name3) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "name", .operator = .EQUAL, .value = pb.Value{ .string_value = "Alice" } });

    const rows = try tm.filter(allocator, "people", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(std.mem.eql(u8, "Alice", rows[0][1].string));
    try testing.expect(std.mem.eql(u8, "Alice", rows[1][1].string));
}

test "filter: float64 comparison" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_cmp_float64.wal",
        .snapshot_dir = ".zig-cache/filter_cmp_float64_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("price", .float64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("products", table_schema);

    try tm.addRecord("products", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromFloat64(9.99) });
    try tm.addRecord("products", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromFloat64(19.99) });
    try tm.addRecord("products", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromFloat64(5.50) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "price", .operator = .LESS_THAN_OR_EQUAL, .value = pb.Value{ .float64_value = 10.0 } });

    const rows = try tm.filter(allocator, "products", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectApproxEqAbs(@as(f64, 9.99), rows[0][1].float64, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 5.50), rows[1][1].float64, 0.01);
}

test "filter: bool equality" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_eq_bool.wal",
        .snapshot_dir = ".zig-cache/filter_eq_bool_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("active", .bool),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("accounts", table_schema);

    try tm.addRecord("accounts", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromBool(true) });
    try tm.addRecord("accounts", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromBool(false) });
    try tm.addRecord("accounts", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromBool(true) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "active", .operator = .EQUAL, .value = pb.Value{ .bool_value = true } });

    const rows = try tm.filter(allocator, "accounts", predicates.items);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(true, rows[0][1].bool);
    try testing.expectEqual(true, rows[1][1].bool);
}

test "filter: no predicates returns all rows" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_no_pred.wal",
        .snapshot_dir = ".zig-cache/filter_no_pred_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{schema.ColumnDef.init("id", .int64)};
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("test", table_schema);

    try tm.addRecord("test", &[_]table.Value{table.Value.fromInt64(1)});
    try tm.addRecord("test", &[_]table.Value{table.Value.fromInt64(2)});
    try tm.addRecord("test", &[_]table.Value{table.Value.fromInt64(3)});

    const empty_predicates: []const pb.Predicate = &.{};
    const rows = try tm.filter(allocator, "test", empty_predicates);
    defer { for (rows) |row| allocator.free(row); allocator.free(rows); }

    try testing.expectEqual(@as(usize, 3), rows.len);
}

test "filter: no matching rows" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_no_match.wal",
        .snapshot_dir = ".zig-cache/filter_no_match_snap",
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("value", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("test", table_schema);

    try tm.addRecord("test", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(10) });
    try tm.addRecord("test", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(20) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{ .column_name = "value", .operator = .GREATER_THAN, .value = pb.Value{ .int64_value = 100 } });

    const rows = try tm.filter(allocator, "test", predicates.items);
    defer allocator.free(rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}
