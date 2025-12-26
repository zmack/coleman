const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const table = @import("table");
const table_manager = @import("table_manager");
const config = @import("config");
const pb = @import("proto");

test "aggregate: COUNT all rows" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_count_all.wal",
        .snapshot_dir = ".zig-cache/agg_count_all_snap",
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
    try tm.addRecord("test", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(30) });

    const empty_predicates: []const pb.Predicate = &.{};
    const result = try tm.aggregate(allocator, "test", "id", .COUNT, empty_predicates);

    try testing.expectEqual(@as(i64, 3), result.int64);
}

test "aggregate: COUNT with filter" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_count_filter.wal",
        .snapshot_dir = ".zig-cache/agg_count_filter_snap",
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
    try predicates.append(allocator, .{
        .column_name = "score",
        .operator = .GREATER_THAN,
        .value = pb.Value{ .int64_value = 60 },
    });

    const result = try tm.aggregate(allocator, "scores", "score", .COUNT, predicates.items);

    try testing.expectEqual(@as(i64, 2), result.int64);
}

test "aggregate: SUM int64 values" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_sum_int64.wal",
        .snapshot_dir = ".zig-cache/agg_sum_int64_snap",
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
        schema.ColumnDef.init("amount", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("transactions", table_schema);

    try tm.addRecord("transactions", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(100) });
    try tm.addRecord("transactions", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(250) });
    try tm.addRecord("transactions", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(150) });

    const empty_predicates: []const pb.Predicate = &.{};
    const result = try tm.aggregate(allocator, "transactions", "amount", .SUM, empty_predicates);

    try testing.expectEqual(@as(i64, 500), result.int64);
}

test "aggregate: SUM float64 values" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_sum_float64.wal",
        .snapshot_dir = ".zig-cache/agg_sum_float64_snap",
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

    const empty_predicates: []const pb.Predicate = &.{};
    const result = try tm.aggregate(allocator, "products", "price", .SUM, empty_predicates);

    try testing.expectApproxEqAbs(@as(f64, 35.48), result.float64, 0.01);
}

test "aggregate: SUM with filter" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_sum_filter.wal",
        .snapshot_dir = ".zig-cache/agg_sum_filter_snap",
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
        schema.ColumnDef.init("category", .int64),
        schema.ColumnDef.init("amount", .int64),
    };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("sales", table_schema);

    try tm.addRecord("sales", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromInt64(1), table.Value.fromInt64(100) });
    try tm.addRecord("sales", &[_]table.Value{ table.Value.fromInt64(2), table.Value.fromInt64(2), table.Value.fromInt64(200) });
    try tm.addRecord("sales", &[_]table.Value{ table.Value.fromInt64(3), table.Value.fromInt64(1), table.Value.fromInt64(150) });

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{
        .column_name = "category",
        .operator = .EQUAL,
        .value = pb.Value{ .int64_value = 1 },
    });

    const result = try tm.aggregate(allocator, "sales", "amount", .SUM, predicates.items);

    try testing.expectEqual(@as(i64, 250), result.int64);
}

test "aggregate: COUNT empty table" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_count_empty.wal",
        .snapshot_dir = ".zig-cache/agg_count_empty_snap",
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
    try tm.createTable("empty", table_schema);

    const empty_predicates: []const pb.Predicate = &.{};
    const result = try tm.aggregate(allocator, "empty", "id", .COUNT, empty_predicates);

    try testing.expectEqual(@as(i64, 0), result.int64);
}

test "aggregate: SUM no matching rows" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_sum_nomatch.wal",
        .snapshot_dir = ".zig-cache/agg_sum_nomatch_snap",
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

    var predicates: std.ArrayList(pb.Predicate) = .{};
    defer predicates.deinit(allocator);
    try predicates.append(allocator, .{
        .column_name = "value",
        .operator = .GREATER_THAN,
        .value = pb.Value{ .int64_value = 100 },
    });

    const result = try tm.aggregate(allocator, "test", "value", .SUM, predicates.items);

    try testing.expectEqual(@as(i64, 0), result.int64);
}

test "aggregate: SUM on string column returns error" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_sum_string.wal",
        .snapshot_dir = ".zig-cache/agg_sum_string_snap",
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

    const name = try allocator.dupe(u8, "Alice");
    try tm.addRecord("people", &[_]table.Value{ table.Value.fromInt64(1), table.Value.fromString(name) });

    const empty_predicates: []const pb.Predicate = &.{};
    const result = tm.aggregate(allocator, "people", "name", .SUM, empty_predicates);

    try testing.expectError(error.InvalidColumnType, result);
}

test "aggregate: non-existent column returns error" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_noexist_col.wal",
        .snapshot_dir = ".zig-cache/agg_noexist_col_snap",
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

    const empty_predicates: []const pb.Predicate = &.{};
    const result = tm.aggregate(allocator, "test", "nonexistent", .COUNT, empty_predicates);

    try testing.expectError(error.ColumnNotFound, result);
}

test "aggregate: non-existent table returns error" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/agg_noexist_table.wal",
        .snapshot_dir = ".zig-cache/agg_noexist_table_snap",
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

    const empty_predicates: []const pb.Predicate = &.{};
    const result = tm.aggregate(allocator, "nonexistent", "id", .COUNT, empty_predicates);

    try testing.expectError(error.TableNotFound, result);
}
