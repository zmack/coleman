const std = @import("std");

pub fn main() void {
    // 1. @sizeOf - computed at comptime when inputs are known
    const size_of_i32 = @sizeOf(i32);  // Comptime!
    const size_of_u64 = @sizeOf(u64);  // Comptime!
    std.debug.print("Size of i32: {} (computed at compile time)\n", .{size_of_i32});
    std.debug.print("Size of u64: {} (computed at compile time)\n", .{size_of_u64});

    // 2. @intCast - comptime when value is known at comptime
    const comptime_cast: i64 = @intCast(@as(i32, 42));  // Comptime!
    std.debug.print("Comptime cast: {}\n", .{comptime_cast});

    // Runtime cast - value comes from function parameter (not known at comptime)
    const result = doubleValue(21);
    std.debug.print("Runtime result: {}\n", .{result});

    // 3. @typeInfo - ALWAYS comptime (types only exist at comptime)
    const type_info = @typeInfo(i32);
    std.debug.print("Type of i32: {s}\n", .{@tagName(type_info)});
}

// This function shows @intCast at runtime
fn doubleValue(x: i32) i64 {
    // x is runtime value, so @intCast runs at runtime
    return @as(i64, @intCast(x)) * 2;
}
