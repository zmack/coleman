const std = @import("std");
const schema = @import("schema");
const table = @import("table");

test "Table creation and basic operations" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
        schema.ColumnDef.init("score", .float64),
    };

    const table_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table

    var test_table = try table.Table.init(allocator, "test_table", table_schema);
    defer test_table.deinit();

    try std.testing.expectEqual(@as(usize, 0), test_table.row_count);
    try std.testing.expectEqual(@as(usize, 3), test_table.columns.len);
}

test "Table add and retrieve records" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
    };

    const table_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table

    var test_table = try table.Table.init(allocator, "users", table_schema);
    defer test_table.deinit();

    // Add first record
    const name1 = try allocator.dupe(u8, "Alice");
    const record1 = [_]table.Value{
        table.Value.fromInt64(1),
        table.Value.fromString(name1),
    };
    try test_table.addRecord(&record1);

    // Add second record
    const name2 = try allocator.dupe(u8, "Bob");
    const record2 = [_]table.Value{
        table.Value.fromInt64(2),
        table.Value.fromString(name2),
    };
    try test_table.addRecord(&record2);

    try std.testing.expectEqual(@as(usize, 2), test_table.row_count);

    // Retrieve values
    const val1 = try test_table.getValue(0, 0);
    try std.testing.expectEqual(@as(i64, 1), val1.int64);

    const val2 = try test_table.getValue(1, 0);
    try std.testing.expectEqual(@as(i64, 2), val2.int64);
}

test "Table type validation" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
    };

    const table_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table

    var test_table = try table.Table.init(allocator, "users", table_schema);
    defer test_table.deinit();

    // Try to add record with wrong type
    const wrong_record = [_]table.Value{
        table.Value.fromString("not_an_int"), // Wrong: should be int64
        table.Value.fromInt64(123), // Wrong: should be string
    };

    const result = test_table.addRecord(&wrong_record);
    try std.testing.expectError(error.TypeMismatch, result);
}

test "Table column count validation" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
    };

    const table_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table

    var test_table = try table.Table.init(allocator, "users", table_schema);
    defer test_table.deinit();

    // Try to add record with wrong number of columns
    const wrong_record = [_]table.Value{
        table.Value.fromInt64(1),
        // Missing second column
    };

    const result = test_table.addRecord(&wrong_record);
    try std.testing.expectError(error.ColumnCountMismatch, result);
}

test "Table getRow returns all values" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("age", .int64),
        schema.ColumnDef.init("score", .float64),
    };

    const table_schema = try schema.Schema.init(allocator, &cols);
    // Schema ownership transferred to table

    var test_table = try table.Table.init(allocator, "data", table_schema);
    defer test_table.deinit();

    const record = [_]table.Value{
        table.Value.fromInt64(42),
        table.Value.fromInt64(30),
        table.Value.fromFloat64(95.5),
    };
    try test_table.addRecord(&record);

    const row = try test_table.getRow(allocator, 0);
    defer allocator.free(row);

    try std.testing.expectEqual(@as(usize, 3), row.len);
    try std.testing.expectEqual(@as(i64, 42), row[0].int64);
    try std.testing.expectEqual(@as(i64, 30), row[1].int64);
    try std.testing.expectEqual(@as(f64, 95.5), row[2].float64);
}
