const std = @import("std");

fn needsReadMethod(reader: anytype) !void {
    var buffer: [100]u8 = undefined;
    _ = try reader.read(&buffer);
}

pub fn main() !void {
    // This type has a read method - works fine
    var stream = std.io.fixedBufferStream("hello");
    const reader = stream.reader();
    try needsReadMethod(reader);

    // This type does NOT have a read method - what happens?
    const wrong_type = "I'm just a string";
    try needsReadMethod(wrong_type);
}
