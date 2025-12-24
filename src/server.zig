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
    var any_reader = reader.any();

    const req = try log_proto.PutRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);

    storage_mutex.lock();
    defer storage_mutex.unlock();

    // Duplicate key/value for persistent storage
    const key = try gpa_allocator.dupe(u8, req.key);
    const value = try gpa_allocator.dupe(u8, req.value);

    const result = try storage.getOrPut(key);
    if (result.found_existing) {
        // Key exists - keep the old key, update value
        gpa_allocator.free(result.value_ptr.*); // Free old value
        gpa_allocator.free(key);                 // Free unused new key
        result.value_ptr.* = value;              // Store new value
    } else {
        // New key - store both
        result.key_ptr.* = key;
        result.value_ptr.* = value;
    }

    // Encode response
    var res = log_proto.PutResponse{ .success = true };
    var out_list: std.ArrayList(u8) = .{};
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
        res.value = val;

        var out_list: std.ArrayList(u8) = .{};
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
        .name = "log.LogService/Put",
        .handler_fn = handlePut,
    });

    try server.handlers.append(allocator, .{
        .name = "log.LogService/Get",
        .handler_fn = handleGet,
    });

    try server.start();
}
