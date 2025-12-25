const std = @import("std");
const schema = @import("schema");
const table = @import("table");
const table_manager = @import("table_manager");

test "TableManager creation and basic operations" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.tableCount());
}

test "TableManager create and retrieve table" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("value", .float64),
    };

    const test_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table_manager

    try manager.createTable("test_table", test_schema);
    try std.testing.expectEqual(@as(usize, 1), manager.tableCount());

    // Try to create duplicate table
    var dup_schema = try schema.Schema.init(allocator, &cols);
    const result = manager.createTable("test_table", dup_schema);
    try std.testing.expectError(error.TableAlreadyExists, result);
    dup_schema.deinit(); // Clean up on error
}

test "TableManager add records and scan" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("value", .float64),
    };

    const test_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table_manager

    try manager.createTable("data", test_schema);

    // Add records
    const record1 = [_]table.Value{
        table.Value.fromInt64(1),
        table.Value.fromFloat64(3.14),
    };
    try manager.addRecord("data", &record1);

    const record2 = [_]table.Value{
        table.Value.fromInt64(2),
        table.Value.fromFloat64(2.71),
    };
    try manager.addRecord("data", &record2);

    // Scan table
    const rows = try manager.scan(allocator, "data");
    defer {
        for (rows) |row| {
            allocator.free(row);
        }
        allocator.free(rows);
    }

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0][0].int64);
    try std.testing.expectEqual(@as(f64, 3.14), rows[0][1].float64);
    try std.testing.expectEqual(@as(i64, 2), rows[1][0].int64);
    try std.testing.expectEqual(@as(f64, 2.71), rows[1][1].float64);
}

test "TableManager operations on non-existent table" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    // Try to add record to non-existent table
    const record = [_]table.Value{
        table.Value.fromInt64(1),
    };
    const add_result = manager.addRecord("nonexistent", &record);
    try std.testing.expectError(error.TableNotFound, add_result);

    // Try to scan non-existent table
    const scan_result = manager.scan(allocator, "nonexistent");
    try std.testing.expectError(error.TableNotFound, scan_result);

    // Try to drop non-existent table
    const drop_result = manager.dropTable("nonexistent");
    try std.testing.expectError(error.TableNotFound, drop_result);
}

test "TableManager drop table" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
    };

    const test_schema = try schema.Schema.init(allocator, &cols);
    // Note: createTable takes ownership, so don't deinit

    try manager.createTable("temp_table", test_schema);
    try std.testing.expectEqual(@as(usize, 1), manager.tableCount());

    try manager.dropTable("temp_table");
    try std.testing.expectEqual(@as(usize, 0), manager.tableCount());
}

test "TableManager get table names" {
    const allocator = std.testing.allocator;

    var manager = table_manager.TableManager.init(allocator);
    defer manager.deinit();

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
    };

    const schema1 = try schema.Schema.init(allocator, &cols);
    // Note: createTable takes ownership, so don't deinit
    try manager.createTable("table1", schema1);

    const schema2 = try schema.Schema.init(allocator, &cols);
    // Note: createTable takes ownership, so don't deinit
    try manager.createTable("table2", schema2);

    const names = try manager.getTableNames(allocator);
    defer {
        for (names) |name| {
            allocator.free(name);
        }
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
}
