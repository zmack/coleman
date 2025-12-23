const std = @import("std");
const grpc = @import("grpc");
const log_proto = @import("proto/log.pb.zig");

// Global storage for the log
var storage_mutex: std.Thread.Mutex = .{};
var storage: std.StringHashMap([]const u8) = undefined;
var gpa_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    storage = std.StringHashMap([]const u8).init(allocator);
    gpa_allocator = allocator;
}

pub fn deinit() void {
    // Free all keys and values in storage
    var it = storage.iterator();
    while (it.next()) |entry| {
        gpa_allocator.free(entry.key_ptr.*);
        gpa_allocator.free(entry.value_ptr.*);
    }
    storage.deinit();
}

fn handlePut(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    
    // Decode request
    var any_reader = reader.any();
    const req = try log_proto.PutRequest.decode(&any_reader, allocator);
    // No need to defer req.deinit because we are using an arena or the provided allocator? 
    // The allocator passed to handler is likely an arena or similar that is reset per request.
    // If not, we should check gRPC-zig implementation.
    // gRPC-zig server.zig: 
    // const response = try handler.handler_fn(decompressed, self.allocator);
    // defer self.allocator.free(response);
    // It passes `self.allocator` which is the server's allocator (likely GPA). 
    // Wait, if it passes GPA, we MUST free memory. 
    // But `PutRequest.decode` allocates memory for strings/bytes.
    defer {
        // We can't easily deinit req if we store parts of it in the map without duping.
        // But for Put, we want to store the data.
        // If we store it, we must duplicate it because the input buffer `input` might be freed.
    }
    
    // Actually, gRPC-zig `handleConnection` loop:
    // const decompressed = ...
    // defer self.allocator.free(decompressed);
    // const response = try handler.handler_fn(decompressed, self.allocator);
    // defer self.allocator.free(response);
    
    // So `input` is valid only during the call.
    // We must duplicate any data we want to keep.

    storage_mutex.lock();
    defer storage_mutex.unlock();

    // We need to dupe the key and value because they point to `input` or allocated by `decode` (which uses passed allocator).
    // If we use the passed allocator (server allocator), the memory persists.
    // But `req.deinit` would free it. 
    // If we don't call `req.deinit`, we leak if we don't store it.
    
    // Let's dupe key and value for storage.
    const key = try gpa_allocator.dupe(u8, req.key);
    const value = try gpa_allocator.dupe(u8, req.value);
    
    const result = try storage.getOrPut(key);
    if (result.found_existing) {
        gpa_allocator.free(result.key_ptr.*);
        gpa_allocator.free(result.value_ptr.*);
        gpa_allocator.free(key); // We found existing, so free the new key
        result.value_ptr.* = value;
    } else {
        result.key_ptr.* = key; // Use the new key
        result.value_ptr.* = value;
    }

    // Clean up request
    // We need to act on `req` which was allocated using `allocator` (server allocator).
    // The `decode` function allocates strings. We must free them.
    // But `log_proto` `deinit` is weird: `pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void`.
    var mutable_req = req;
    mutable_req.deinit(allocator);

    // Create response
    var res = log_proto.PutResponse{ .success = true };
    
    var out_list: std.ArrayList(u8) = .{};
    // defer out_list.deinit(allocator); // We return the slice, so we shouldn't deinit? 
    // specificially, we return `[]u8`. `toOwnedSlice` gives us a slice that the caller must free.
    // gRPC-zig expects the handler to return an allocated slice that it will free.
    
    const writer = out_list.writer(allocator);
    try res.encode(&writer, allocator);
    
    return out_list.toOwnedSlice(allocator);
}

fn handleGet(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    
    var any_reader = reader.any();
    const req = try log_proto.GetRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);
    
    storage_mutex.lock();
    defer storage_mutex.unlock();
    
    var res = log_proto.GetResponse{};
    
    if (storage.get(req.key)) |val| {
        res.found = true;
        res.value = val; // This points to storage memory. safe while lock held? 
        // No, we are encoding to a buffer before returning.
        // Encoding copies the data to the writer.
        
        var out_list: std.ArrayList(u8) = .{};
        // defer out_list.deinit(); // toOwnedSlice handles it
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    } else {
        res.found = false;
        var out_list: std.ArrayList(u8) = .{};
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    }
}


pub fn runServer(limit: ?usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    init(allocator);
    defer deinit();

    var server = try grpc.GrpcServer.init(allocator, 50051, "secret-key", limit);
    defer server.deinit();

    try server.handlers.append(allocator, .{
        .name = "log.LogService/Put", // Full method name usually required by gRPC
        .handler_fn = handlePut,
    });
    
    try server.handlers.append(allocator, .{
        .name = "log.LogService/Get",
        .handler_fn = handleGet,
    });
    // Note: Protocol Buffers service names are package.Service/Method usually.
    // But gRPC HTTP/2 path is /package.Service/Method.
    // gRPC-zig implementation checks `name` against parts of the path?
    // Let's check how gRPC-zig handles paths.
    
    try server.start();
}
