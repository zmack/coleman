const std = @import("std");

// Generic function that optimizes based on type information
fn sum(items: anytype) i32 {
    const T = @TypeOf(items);

    // Check if it's a compile-time known array
    if (@typeInfo(T) == .array) {
        // Comptime: we know the length at compile time!
        // Could use this for optimization decisions
        var total: i32 = 0;

        // Unroll loop at compile time with 'inline'
        inline for (items) |item| {
            total += item;
        }
        return total;
    } else {
        // Runtime: unknown length slice
        var total: i32 = 0;
        for (items) |item| {
            total += item;
        }
        return total;
    }
}

pub fn main() void {
    // Comptime: array with known size
    const array = [_]i32{1, 2, 3, 4, 5};
    const array_sum = sum(array);
    std.debug.print("Array sum: {} (unrolled at comptime)\n", .{array_sum});

    // Runtime: slice with unknown size
    const slice: []const i32 = &array;
    const slice_sum = sum(slice);
    std.debug.print("Slice sum: {} (loop at runtime)\n", .{slice_sum});
}
