# Memory Leak Fix: Client Response Buffer

## Location
`libs/gRPC-zig/src/client.zig` - `GrpcClient.call()` method

## The Problem

The `call()` method was leaking the buffer returned by `readMessage()` on every RPC call.

### Original Code
```zig
pub fn call(self: *GrpcClient, method: []const u8, request: []const u8,
            compression_alg: compression.Compression.Algorithm) ![]u8 {
    // ... auth and compression setup ...

    try self.transport.writeMessage(compressed);
    const response_bytes = try self.transport.readMessage();  // ← Allocation #1

    // Decompress response
    return self.compression.decompress(response_bytes, compression_alg);  // ← Allocation #2
}
```

### Why It Leaks

Let's trace the memory allocations:

#### Step 1: `readMessage()` allocates memory
```zig
// In transport.zig
pub fn readMessage(self: *Transport) ![]const u8 {
    // ... frame reading logic ...
    return try self.allocator.dupe(u8, frame.payload);  // ← NEW allocation
}
```

The function returns a **newly allocated buffer** containing the response data.

#### Step 2: `decompress()` makes a COPY
```zig
// In compression.zig
pub fn decompress(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
    _ = algorithm;
    return self.allocator.dupe(u8, data);  // ← Makes ANOTHER copy
}
```

Even with compression disabled (`.none` algorithm), the decompress function **duplicates the entire buffer**.

#### Step 3: The Leak
```
Memory state after call() returns:
┌──────────────────────────────────────────────┐
│ response_bytes → [memory block #1]   LEAKED! │  ← Nobody has a reference to this
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│ return value   → [memory block #2]           │  ← Caller receives this
└──────────────────────────────────────────────┘
```

The caller only receives and frees the **decompressed copy** (allocation #2). The original `response_bytes` buffer (allocation #1) has no owner and leaks.

## The Fix

```zig
pub fn call(self: *GrpcClient, method: []const u8, request: []const u8,
            compression_alg: compression.Compression.Algorithm) ![]u8 {
    // ... auth and compression setup ...

    try self.transport.writeMessage(compressed);
    const response_bytes = try self.transport.readMessage();
    defer self.allocator.free(response_bytes);  // ← Free allocation #1 on function exit

    // Decompress response
    return self.compression.decompress(response_bytes, compression_alg);
}
```

### How `defer` Works Here

The key insight: **`defer` executes when the function exits, AFTER the return value is copied out**.

Execution order:
1. `readMessage()` allocates `response_bytes`
2. `defer` schedules cleanup for function exit
3. `decompress()` makes a copy and returns it
4. Return value is set to the decompressed copy
5. **Function starts exiting**
6. `defer` fires → frees `response_bytes` ✓
7. Return value is passed to caller (still valid - it's a different allocation!)

## Why This Bug Existed

This was a **pre-existing bug** in gRPC-zig, not introduced by our Zig 0.15.2 compatibility fixes.

Looking at the original code (commit `bd81fea`):
```zig
// Original compression.zig
pub fn decompress(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
    switch (algorithm) {
        .none => return self.allocator.dupe(u8, data),  // ← Always duplicated!
        // ...
    }
}
```

Even in the original implementation, `.none` compression **always duplicated the data**.

### Why It Wasn't Caught

1. **Most users likely enable compression** - With `.gzip`/`.deflate`, the code path is different
2. **No leak detection in tests** - The library tests don't use GPA leak checking
3. **Small leaks in short-lived programs** - A few leaked buffers won't crash your app
4. **Arena allocators mask it** - If wrapped in an arena, the leak disappears on arena cleanup

## Testing

Verified with Zig's `GeneralPurposeAllocator` in leak detection mode:

**Before fix:**
```
error(gpa): memory address 0x1043c0002 leaked:
???:?:?: in _transport.Transport.readMessage
???:?:?: in _client.GrpcClient.call
```

**After fix:**
```
(no memory errors)
```

## Performance Note

The double allocation (readMessage → decompress) is inefficient. Ideally:
- `decompress()` could work in-place for `.none` algorithm
- Or `readMessage()` could transfer ownership directly without the intermediate step

However, fixing the leak was the priority. The performance optimization can be addressed separately.
