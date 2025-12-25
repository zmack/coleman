const std = @import("std");

/// A value that can be stored in a column (used for WAL serialization)
pub const Value = struct {
    int_value: ?i64 = null,
    float_value: ?f64 = null,
    string_value: ?[]const u8 = null,
    bool_value: ?bool = null,
};

/// Column definition (used for schema serialization)
pub const Column = struct {
    name: []const u8,
    column_type: ColumnType,
};

/// Column data types supported by Coleman
pub const ColumnType = enum {
    int64,
    float64,
    string,
    bool,

    pub fn fromString(s: []const u8) !ColumnType {
        if (std.mem.eql(u8, s, "int64")) return .int64;
        if (std.mem.eql(u8, s, "float64")) return .float64;
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "bool")) return .bool;
        return error.UnknownColumnType;
    }

    pub fn toString(self: ColumnType) []const u8 {
        return switch (self) {
            .int64 => "int64",
            .float64 => "float64",
            .string => "string",
            .bool => "bool",
        };
    }
};

/// Definition of a single column in a table
pub const ColumnDef = struct {
    name: []const u8,
    column_type: ColumnType,

    pub fn init(name: []const u8, column_type: ColumnType) ColumnDef {
        return .{
            .name = name,
            .column_type = column_type,
        };
    }

    pub fn deinit(self: *ColumnDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Schema defines the structure of a table
pub const Schema = struct {
    columns: []ColumnDef,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, columns: []const ColumnDef) !Schema {
        const owned_columns = try allocator.alloc(ColumnDef, columns.len);
        for (columns, 0..) |col, i| {
            owned_columns[i] = .{
                .name = try allocator.dupe(u8, col.name),
                .column_type = col.column_type,
            };
        }

        return .{
            .columns = owned_columns,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        for (self.columns) |*col| {
            self.allocator.free(col.name);
        }
        self.allocator.free(self.columns);
    }

    pub fn columnCount(self: Schema) usize {
        return self.columns.len;
    }

    pub fn findColumn(self: Schema, name: []const u8) ?usize {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) {
                return i;
            }
        }
        return null;
    }

    pub fn getColumnType(self: Schema, idx: usize) !ColumnType {
        if (idx >= self.columns.len) return error.ColumnIndexOutOfBounds;
        return self.columns[idx].column_type;
    }
};

test "schema basic operations" {
    const allocator = std.testing.allocator;

    const cols = [_]ColumnDef{
        ColumnDef.init("id", .int64),
        ColumnDef.init("name", .string),
        ColumnDef.init("score", .float64),
    };

    var schema = try Schema.init(allocator, &cols);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 3), schema.columnCount());
    try std.testing.expectEqual(@as(?usize, 0), schema.findColumn("id"));
    try std.testing.expectEqual(@as(?usize, 1), schema.findColumn("name"));
    try std.testing.expectEqual(@as(?usize, null), schema.findColumn("nonexistent"));
}
