const std = @import("std");
const grpc = @import("grpc");
const log_proto = @import("proto/log.pb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try grpc.GrpcClient.init(allocator, "127.0.0.1", 50051);
    defer client.deinit();

    // Set authentication
    try client.setAuth("secret-key");

    // Put Operation
    std.debug.print("Sending Put request...\n", .{});
    {
        var req = log_proto.PutRequest{
            .key = "test_key",
            .value = "test_value",
        };
        // defer req.deinit(allocator); // Don't deinit literals

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);
        
        const response_bytes = try client.call("log.LogService/Put", list.items, .none);
        defer allocator.free(response_bytes);
        
        // Decode response
        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.PutResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);
        
        std.debug.print("Put response: success={}\n", .{res.success});
    }

    // Get Operation
    std.debug.print("Sending Get request...\n", .{});
    {
        var req = log_proto.GetRequest{
            .key = "test_key",
        };
        // defer req.deinit(allocator); // Don't deinit literals

        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        try req.encode(&writer, allocator);
        
        const response_bytes = try client.call("log.LogService/Get", list.items, .none);
        defer allocator.free(response_bytes);
        
        var stream = std.io.fixedBufferStream(response_bytes);
        var reader = stream.reader();
        var any_reader = reader.any();
        const res = try log_proto.GetResponse.decode(&any_reader, allocator);
        var mutable_res = res;
        defer mutable_res.deinit(allocator);
        
        std.debug.print("Get response: found={}, value={s}\n", .{res.found, res.value});
    }
}
