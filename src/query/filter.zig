const std = @import("std");
const table = @import("table");
const schema = @import("schema");
const pb = @import("proto");

/// Compares two values based on the given operator
fn compareValues(value: table.Value, predicate_value: table.Value, operator: pb.ComparisonOperator) bool {
    return switch (value) {
        .int64 => |v| compareInt64(v, predicate_value, operator),
        .float64 => |v| compareFloat64(v, predicate_value, operator),
        .string => |v| compareString(v, predicate_value, operator),
        .bool => |v| compareBool(v, predicate_value, operator),
    };
}

fn compareInt64(value: i64, predicate_value: table.Value, operator: pb.ComparisonOperator) bool {
    if (predicate_value != .int64) return false;
    const pv = predicate_value.int64;

    return switch (operator) {
        .EQUAL => value == pv,
        .NOT_EQUAL => value != pv,
        .LESS_THAN => value < pv,
        .LESS_THAN_OR_EQUAL => value <= pv,
        .GREATER_THAN => value > pv,
        .GREATER_THAN_OR_EQUAL => value >= pv,
    };
}

fn compareFloat64(value: f64, predicate_value: table.Value, operator: pb.ComparisonOperator) bool {
    if (predicate_value != .float64) return false;
    const pv = predicate_value.float64;

    return switch (operator) {
        .EQUAL => value == pv,
        .NOT_EQUAL => value != pv,
        .LESS_THAN => value < pv,
        .LESS_THAN_OR_EQUAL => value <= pv,
        .GREATER_THAN => value > pv,
        .GREATER_THAN_OR_EQUAL => value >= pv,
    };
}

fn compareString(value: []const u8, predicate_value: table.Value, operator: pb.ComparisonOperator) bool {
    if (predicate_value != .string) return false;
    const pv = predicate_value.string;

    return switch (operator) {
        .EQUAL => std.mem.eql(u8, value, pv),
        .NOT_EQUAL => !std.mem.eql(u8, value, pv),
        .LESS_THAN => std.mem.order(u8, value, pv) == .lt,
        .LESS_THAN_OR_EQUAL => {
            const ord = std.mem.order(u8, value, pv);
            return ord == .lt or ord == .eq;
        },
        .GREATER_THAN => std.mem.order(u8, value, pv) == .gt,
        .GREATER_THAN_OR_EQUAL => {
            const ord = std.mem.order(u8, value, pv);
            return ord == .gt or ord == .eq;
        },
    };
}

fn compareBool(value: bool, predicate_value: table.Value, operator: pb.ComparisonOperator) bool {
    if (predicate_value != .bool) return false;
    const pv = predicate_value.bool;

    return switch (operator) {
        .EQUAL => value == pv,
        .NOT_EQUAL => value != pv,
        // For bools, treat false < true
        .LESS_THAN => !value and pv,
        .LESS_THAN_OR_EQUAL => !value or value == pv,
        .GREATER_THAN => value and !pv,
        .GREATER_THAN_OR_EQUAL => value or value == pv,
    };
}

/// Convert protobuf Value to table Value
fn pbValueToTableValue(allocator: std.mem.Allocator, pb_value: pb.Value) !table.Value {
    if (pb_value.int64_value) |v| {
        return table.Value.fromInt64(v);
    }
    if (pb_value.float64_value) |v| {
        return table.Value.fromFloat64(v);
    }
    if (pb_value.string_value.len > 0) {
        // Duplicate the string to ensure it stays valid
        const owned_str = try allocator.dupe(u8, pb_value.string_value);
        return table.Value.fromString(owned_str);
    }
    if (pb_value.bool_value) |v| {
        return table.Value.fromBool(v);
    }
    return error.InvalidValue;
}

/// Evaluate a single predicate against a row
fn evaluatePredicate(
    tbl: *const table.Table,
    row_idx: usize,
    predicate: pb.Predicate,
    allocator: std.mem.Allocator,
) !bool {
    // Find column index by name
    var col_idx: ?usize = null;
    for (tbl.table_schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, predicate.column_name)) {
            col_idx = i;
            break;
        }
    }

    if (col_idx == null) {
        return error.ColumnNotFound;
    }

    // Get the value from the table
    const row_value = try tbl.getValue(row_idx, col_idx.?);

    // Convert predicate value
    const pred_value = if (predicate.value) |pv|
        try pbValueToTableValue(allocator, pv)
    else
        return error.InvalidPredicate;

    // Compare
    return compareValues(row_value, pred_value, predicate.operator);
}

/// Filter a table based on predicates
/// Returns an ArrayList of row indices that match all predicates (AND logic)
pub fn filterTable(
    allocator: std.mem.Allocator,
    tbl: *const table.Table,
    predicates: []const pb.Predicate,
) !std.ArrayList(usize) {
    var matching_rows: std.ArrayList(usize) = .{};
    errdefer matching_rows.deinit(allocator);

    // If no predicates, return all rows
    if (predicates.len == 0) {
        for (0..tbl.row_count) |i| {
            try matching_rows.append(allocator, i);
        }
        return matching_rows;
    }

    // Create an arena for temporary allocations during predicate evaluation
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Check each row
    row_loop: for (0..tbl.row_count) |row_idx| {
        // All predicates must match (AND logic)
        for (predicates) |predicate| {
            const matches = try evaluatePredicate(tbl, row_idx, predicate, arena_allocator);
            if (!matches) {
                continue :row_loop;
            }
        }
        // All predicates matched
        try matching_rows.append(allocator, row_idx);
    }

    return matching_rows;
}
