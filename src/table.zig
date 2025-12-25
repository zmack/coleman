const std = @import("std");
const schema = @import("schema");

/// A value that can be stored in a column
pub const Value = union(schema.ColumnType) {
    int64: i64,
    float64: f64,
    string: []const u8,
    bool: bool,

    pub fn fromInt64(val: i64) Value {
        return .{ .int64 = val };
    }

    pub fn fromFloat64(val: f64) Value {
        return .{ .float64 = val };
    }

    pub fn fromString(val: []const u8) Value {
        return .{ .string = val };
    }

    pub fn fromBool(val: bool) Value {
        return .{ .bool = val };
    }
};

/// Column data storage - stores values of a single type
pub const Column = union(schema.ColumnType) {
    int64: std.ArrayList(i64),
    float64: std.ArrayList(f64),
    string: std.ArrayList([]const u8),
    bool: std.ArrayList(bool),

    pub fn init(allocator: std.mem.Allocator, column_type: schema.ColumnType) Column {
        _ = allocator;
        return switch (column_type) {
            .int64 => .{ .int64 = .{} },
            .float64 => .{ .float64 = .{} },
            .string => .{ .string = .{} },
            .bool => .{ .bool = .{} },
        };
    }

    pub fn deinit(self: *Column, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .int64 => |*list| list.deinit(allocator),
            .float64 => |*list| list.deinit(allocator),
            .string => |*list| {
                for (list.items) |str| {
                    allocator.free(str);
                }
                list.deinit(allocator);
            },
            .bool => |*list| list.deinit(allocator),
        }
    }

    pub fn append(self: *Column, allocator: std.mem.Allocator, value: Value) !void {
        switch (self.*) {
            .int64 => |*list| try list.append(allocator, value.int64),
            .float64 => |*list| try list.append(allocator, value.float64),
            .string => |*list| try list.append(allocator, value.string),
            .bool => |*list| try list.append(allocator, value.bool),
        }
    }

    pub fn len(self: Column) usize {
        return switch (self) {
            .int64 => |list| list.items.len,
            .float64 => |list| list.items.len,
            .string => |list| list.items.len,
            .bool => |list| list.items.len,
        };
    }

    pub fn get(self: Column, idx: usize) !Value {
        return switch (self) {
            .int64 => |list| Value.fromInt64(list.items[idx]),
            .float64 => |list| Value.fromFloat64(list.items[idx]),
            .string => |list| Value.fromString(list.items[idx]),
            .bool => |list| Value.fromBool(list.items[idx]),
        };
    }
};

/// A table stores columnar data with a schema
pub const Table = struct {
    name: []const u8,
    table_schema: schema.Schema,
    columns: []Column,
    row_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table_schema: schema.Schema) !Table {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const columns = try allocator.alloc(Column, table_schema.columnCount());
        for (table_schema.columns, 0..) |col, i| {
            columns[i] = Column.init(allocator, col.column_type);
        }

        return .{
            .name = owned_name,
            .table_schema = table_schema,
            .columns = columns,
            .row_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.table_schema.deinit();
        for (self.columns) |*col| {
            col.deinit(self.allocator);
        }
        self.allocator.free(self.columns);
        self.allocator.free(self.name);
    }

    /// Add a record (row) to the table
    pub fn addRecord(self: *Table, values: []const Value) !void {
        if (values.len != self.columns.len) {
            return error.ColumnCountMismatch;
        }

        // Validate types match
        for (values, 0..) |value, i| {
            const expected_type = self.table_schema.columns[i].column_type;
            const actual_type = @as(schema.ColumnType, value);
            if (expected_type != actual_type) {
                return error.TypeMismatch;
            }
        }

        // Append to each column
        for (values, 0..) |value, i| {
            try self.columns[i].append(self.allocator, value);
        }

        self.row_count += 1;
    }

    /// Get a value at (row, column)
    pub fn getValue(self: Table, row: usize, col: usize) !Value {
        if (row >= self.row_count) return error.RowIndexOutOfBounds;
        if (col >= self.columns.len) return error.ColumnIndexOutOfBounds;
        return self.columns[col].get(row);
    }

    /// Get all values in a row
    pub fn getRow(self: Table, allocator: std.mem.Allocator, row: usize) ![]Value {
        if (row >= self.row_count) return error.RowIndexOutOfBounds;

        const values = try allocator.alloc(Value, self.columns.len);
        for (self.columns, 0..) |col, i| {
            values[i] = try col.get(row);
        }
        return values;
    }
};

test "table basic operations" {
    const allocator = std.testing.allocator;

    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("name", .string),
    };

    var table_schema = try schema.Schema.init(allocator, &cols);
    defer table_schema.deinit();

    var table = try Table.init(allocator, "users", table_schema);
    defer table.deinit();

    // Add a record
    const name = try allocator.dupe(u8, "Alice");
    const record1 = [_]Value{
        Value.fromInt64(1),
        Value.fromString(name),
    };
    try table.addRecord(&record1);

    try std.testing.expectEqual(@as(usize, 1), table.row_count);

    const val = try table.getValue(0, 0);
    try std.testing.expectEqual(@as(i64, 1), val.int64);
}
