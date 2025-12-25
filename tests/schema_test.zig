const std = @import("std");
const schema = @import("schema");

test "ColumnType toString and fromString" {
    try std.testing.expectEqualStrings("int64", schema.ColumnType.int64.toString());
    try std.testing.expectEqualStrings("float64", schema.ColumnType.float64.toString());
    try std.testing.expectEqualStrings("string", schema.ColumnType.string.toString());
    try std.testing.expectEqualStrings("bool", schema.ColumnType.bool.toString());

    try std.testing.expectEqual(schema.ColumnType.int64, try schema.ColumnType.fromString("int64"));
    try std.testing.expectEqual(schema.ColumnType.float64, try schema.ColumnType.fromString("float64"));
    try std.testing.expectEqual(schema.ColumnType.string, try schema.ColumnType.fromString("string"));
    try std.testing.expectEqual(schema.ColumnType.bool, try schema.ColumnType.fromString("bool"));
}

test "Schema creation and column operations" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
        schema.ColumnDef.init("score", .float64),
        schema.ColumnDef.init("active", .bool),
    };

    var test_schema = try schema.Schema.init(allocator, &cols);
    defer test_schema.deinit();

    try std.testing.expectEqual(@as(usize, 4), test_schema.columnCount());

    // Test findColumn
    try std.testing.expectEqual(@as(?usize, 0), test_schema.findColumn("id"));
    try std.testing.expectEqual(@as(?usize, 1), test_schema.findColumn("name"));
    try std.testing.expectEqual(@as(?usize, 2), test_schema.findColumn("score"));
    try std.testing.expectEqual(@as(?usize, 3), test_schema.findColumn("active"));
    try std.testing.expectEqual(@as(?usize, null), test_schema.findColumn("nonexistent"));

    // Test getColumnType
    try std.testing.expectEqual(schema.ColumnType.int64, try test_schema.getColumnType(0));
    try std.testing.expectEqual(schema.ColumnType.string, try test_schema.getColumnType(1));
    try std.testing.expectEqual(schema.ColumnType.float64, try test_schema.getColumnType(2));
    try std.testing.expectEqual(schema.ColumnType.bool, try test_schema.getColumnType(3));
}

test "Schema column type validation" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
    };

    var test_schema = try schema.Schema.init(allocator, &cols);
    defer test_schema.deinit();

    // Test out of bounds
    const result = test_schema.getColumnType(999);
    try std.testing.expectError(error.ColumnIndexOutOfBounds, result);
}
