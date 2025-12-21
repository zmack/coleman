const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    std.debug.print("Starting Log Service...\n", .{});
    try server.runServer();
}

test "ArrayList init" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();
    try list.append(1);
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
