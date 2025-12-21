const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var limit: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            if (i + 1 < args.len) {
                limit = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        }
    }

    std.debug.print("Starting Log Service...\n", .{});
    if (limit) |l| {
        std.debug.print("Request limit set to: {}\n", .{l});
    }
    try server.runServer(limit);
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
