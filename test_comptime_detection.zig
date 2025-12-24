const std = @import("std");

fn smartFunction(x: i32) i32 {
    if (@inComptime()) {
        // This branch runs at compile time
        // Do expensive compile-time optimization
        return x * x * x;  // Cube it
    } else {
        // This branch runs at runtime
        // Use simpler runtime calculation
        return x * 2;  // Just double it
    }
}

pub fn main() void {
    // Comptime call - will use x * x * x
    const comptime_result = comptime smartFunction(10);
    std.debug.print("Comptime result: {} (should be 1000 = 10^3)\n", .{comptime_result});

    // Runtime call - will use x * 2
    const runtime_value: i32 = 10;
    const runtime_result = smartFunction(runtime_value);
    std.debug.print("Runtime result: {} (should be 20 = 10*2)\n", .{runtime_result});

    // Verify they're different!
    std.debug.print("Same input, different results based on comptime vs runtime!\n", .{});
}
