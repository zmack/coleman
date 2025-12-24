# Memory Leak Fix: Server Storage Cleanup

## Location

`src/server.zig` - `deinit()` function

## The Problem

The Coleman server stores key-value pairs in a global `StringHashMap`. When storing data, it duplicates both the key and value strings, but these allocations were never freed on server shutdown.

### Original Code

```zig
// Global storage
var storage: std.StringHashMap([]const u8) = undefined;
var gpa_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    storage = std.StringHashMap([]const u8).init(allocator);
    gpa_allocator = allocator;
}

pub fn deinit() void {
    storage.deinit();  // ← Only frees hashmap structure, not stored strings!
}

fn handlePut(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    // ... decode request ...

    // Duplicate key and value for storage
    const key = try gpa_allocator.dupe(u8, req.key);      // ← Allocation #1
    const value = try gpa_allocator.dupe(u8, req.value);  // ← Allocation #2

    const result = try storage.getOrPut(key);
    if (result.found_existing) {
        gpa_allocator.free(result.key_ptr.*);   // Free old key
        gpa_allocator.free(result.value_ptr.*); // Free old value
        gpa_allocator.free(key);                // Free unused new key
        result.value_ptr.* = value;
    } else {
        result.key_ptr.* = key;
        result.value_ptr.* = value;
    }

    // ... encode and return response ...
}
```

### Why Duplication Is Necessary

You might wonder: why duplicate the strings at all? Why not just store the pointers from the request?

The answer is **lifetime management**:

```zig
fn handlePut(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    const req = try log_proto.PutRequest.decode(&any_reader, allocator);
    // req.key and req.value point to memory owned by the request
}
// ← Function returns here - request memory will be freed/reused
```

After `handlePut()` returns:

- The gRPC server frees the `input` buffer
- The protobuf decoder may have allocated temporary buffers for `req`
- Those buffers are either freed immediately or on the next request

If we stored the raw pointers from `req`, we'd have **dangling pointers** - the storage would point to freed memory!

### Solution: Duplicate for Storage

```zig
// Create permanent copies owned by the storage
const key = try gpa_allocator.dupe(u8, req.key);
const value = try gpa_allocator.dupe(u8, req.value);

// These allocations live as long as they're in the storage map
try storage.put(key, value);
```

Now the storage owns independent copies that persist beyond the request lifetime.

### Why It Leaks

The code correctly:
✓ Duplicates strings when storing
✓ Frees old strings when updating existing keys

But it **never frees the final state** when the server shuts down:

```zig
pub fn deinit() void {
    storage.deinit();  // Only frees hashmap buckets, not the strings!
}
```

## Memory State at Shutdown

```
During server lifetime:
┌────────────────────────────────────────────┐
│ StringHashMap                              │
│   ├─ Key: "test_key" ──────────┐           │
│   │  Value: "test_value" ──────┼──┐        │
│   └────────────────────────────┘  │        │
└──────────────────────────────│────│────────┘
                               │    │
                               ↓    ↓
                         [heap: "test_key"]
                         [heap: "test_value"]

After storage.deinit():
┌────────────────────────────────────────────┐
│ HashMap structure (FREED)                  │ ← ✓ Freed
└────────────────────────────────────────────┘

[heap: "test_key"]     ← ✗ LEAKED!
[heap: "test_value"]   ← ✗ LEAKED!
```

## The Fix

```zig
pub fn deinit() void {
    // Free all keys and values in storage
    var it = storage.iterator();
    while (it.next()) |entry| {
        gpa_allocator.free(entry.key_ptr.*);
        gpa_allocator.free(entry.value_ptr.*);
    }
    storage.deinit();
}
```

### How It Works

1. **Iterate through all entries** using `iterator()`
2. **Free each key** - the duplicated key strings
3. **Free each value** - the duplicated value strings
4. **Free the hashmap structure** with `deinit()`

The iterator gives us an entry with:

- `entry.key_ptr: *[]const u8` - pointer to the key
- `entry.value_ptr: *[]const u8` - pointer to the value

We dereference these (`.*`) to get the actual slices, then free them.

## Why This Pattern Matters

This is a fundamental pattern in Zig for managing heap-allocated data in collections:

### The Rule

**Whoever allocates, deallocates.**

If you `dupe()` data and store it in a collection:

```zig
const key = try allocator.dupe(u8, source);
try map.put(key, value);
```

You must eventually free it:

```zig
var it = map.iterator();
while (it.next()) |entry| {
    allocator.free(entry.key_ptr.*);
}
```

### Contrast with Other Languages

**Rust**: The `HashMap` owns its contents, dropping them automatically

```rust
let mut map = HashMap::new();
map.insert(key.to_string(), value.to_string());
// Automatically freed when map goes out of scope
```

**Go**: Garbage collector handles it

```go
m := make(map[string]string)
m[key] = value
// GC will collect unreachable data
```

**Zig**: Explicit ownership and cleanup

```zig
var map = StringHashMap([]const u8).init(allocator);
// You must explicitly iterate and free contents
```

This explicitness is Zig's philosophy - **no hidden allocations, no hidden frees**.

## Testing

Verified with Zig's `GeneralPurposeAllocator` in leak detection mode:

**Before fix:**

```
error(gpa): memory address 0x102620008 leaked:
/Users/.../src/server.zig:59:39: in handlePut
    const key = try gpa_allocator.dupe(u8, req.key);

error(gpa): memory address 0x102640010 leaked:
/Users/.../src/server.zig:60:41: in handlePut
    const value = try gpa_allocator.dupe(u8, req.value);
```

**After fix:**

```
(no memory errors)
```

## Edge Case: Replacing Existing Keys

Note that `handlePut()` already handles the case where a key exists:

```zig
const result = try storage.getOrPut(key);
if (result.found_existing) {
    gpa_allocator.free(result.key_ptr.*);   // ✓ Free old key
    gpa_allocator.free(result.value_ptr.*); // ✓ Free old value
    gpa_allocator.free(key);                // ✓ Free unused new key
    result.value_ptr.* = value;             // Keep new value
}
```

This prevents leaks during updates:

1. We allocate new key/value
2. Find that key already exists
3. Free the old key/value pair
4. Free the new (unused) key
5. Store only the new value

Without this logic, every `Put` to the same key would leak the old value!

## Shutdown Sequence

The server's full cleanup sequence:

```zig
pub fn runServer(limit: ?usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    init(allocator);
    defer deinit();  // ← Cleanup storage (including all keys/values)

    var server = try grpc.GrpcServer.init(allocator, 50051, "secret-key", limit);
    defer server.deinit();  // ← Cleanup gRPC server resources

    try server.start();
}
```

The `defer` statements execute in **reverse order**:

1. `server.deinit()` - closes connections, frees server state
2. `deinit()` - frees storage keys/values ← **Our fix**
3. `gpa.deinit()` - verifies no leaks remain

This ensures proper cleanup ordering: server shuts down first, then we clean up the storage it was using.
