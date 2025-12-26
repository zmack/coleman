const std = @import("std");
const table = @import("table");
const schema = @import("schema");
const pb = @import("proto");
const filter_mod = @import("filter");

/// Aggregate a table by applying a function to a column
/// Returns a single Value (scalar result)
/// Supports optional predicates for filtered aggregation
pub fn aggregateTable(
    allocator: std.mem.Allocator,
    tbl: *const table.Table,
    column_name: []const u8,
    function: pb.AggregateFunction,
    predicates: []const pb.Predicate,
) !table.Value {
    // Find column index by name
    const col_idx = findColumnIndex(tbl, column_name) orelse return error.ColumnNotFound;

    // Get matching row indices (reuse filter logic)
    var matching_indices = try filter_mod.filterTable(allocator, tbl, predicates);
    defer matching_indices.deinit(allocator);

    // Dispatch to appropriate aggregate function
    return switch (function) {
        .COUNT => aggregateCount(matching_indices.items.len),
        .SUM => try aggregateSum(tbl, col_idx, matching_indices.items),
    };
}

/// Helper to find column index by name
fn findColumnIndex(tbl: *const table.Table, column_name: []const u8) ?usize {
    for (tbl.table_schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, column_name)) {
            return i;
        }
    }
    return null;
}

/// COUNT aggregate - simply returns the number of rows
fn aggregateCount(row_count: usize) !table.Value {
    return table.Value.fromInt64(@intCast(row_count));
}

/// SUM aggregate - sums numeric values
/// Type-dispatched based on column type
fn aggregateSum(
    tbl: *const table.Table,
    col_idx: usize,
    row_indices: []const usize,
) !table.Value {
    // Get column type
    const column = tbl.columns[col_idx];

    // Type dispatch based on column type
    return switch (column) {
        .int64 => |int_col| sumInt64(int_col, row_indices),
        .float64 => |float_col| sumFloat64(float_col, row_indices),
        .string, .bool => error.InvalidColumnType, // SUM not supported
    };
}

/// Sum int64 values
fn sumInt64(column: std.ArrayList(i64), row_indices: []const usize) !table.Value {
    var sum: i64 = 0;
    for (row_indices) |idx| {
        sum += column.items[idx];
    }
    return table.Value.fromInt64(sum);
}

/// Sum float64 values
fn sumFloat64(column: std.ArrayList(f64), row_indices: []const usize) !table.Value {
    var sum: f64 = 0.0;
    for (row_indices) |idx| {
        sum += column.items[idx];
    }
    return table.Value.fromFloat64(sum);
}
