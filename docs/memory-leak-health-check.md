# Memory Leak Fix: Health Check Service Names

## Location

`libs/gRPC-zig/src/features/health.zig` - `HealthCheck.deinit()` method

## The Problem

The `HealthCheck` struct stores health status for different gRPC services using a hashmap. Service names are duplicated and stored as keys, but these strings were never freed on cleanup.

### Original Code

```zig
pub const HealthCheck = struct {
    status: std.StringHashMap(HealthStatus),
    allocator: std.mem.Allocator,

    pub fn setStatus(self: *HealthCheck, service: []const u8, status: HealthStatus) !void {
        const service_key = try self.allocator.dupe(u8, service);  // ← Allocates string
        errdefer self.allocator.free(service_key);
        try self.status.put(service_key, status);  // ← Stores allocated string as key
    }

    pub fn deinit(self: *HealthCheck) void {
        self.status.deinit();  // ← Only frees hashmap structure, not the keys!
    }
};
```

### Why It Leaks

#### Step 1: Service names are duplicated

When `setStatus()` is called, it duplicates the service name string:

```zig
const service_key = try self.allocator.dupe(u8, service);
```

This creates a **new heap-allocated string** owned by the HealthCheck instance.

#### Step 2: Duplicated strings are stored as keys

```zig
try self.status.put(service_key, status);
```

The hashmap stores a **pointer** to the duplicated string as the key. The hashmap doesn't own the string memory - it just holds a reference.

#### Step 3: Cleanup doesn't free the strings

```zig
pub fn deinit(self: *HealthCheck) void {
    self.status.deinit();  // Only frees internal hashmap structure
}
```

`StringHashMap.deinit()` frees the hashmap's internal bucket arrays and metadata, but **does not free the keys or values** themselves. Those are the caller's responsibility.

### Memory State on Deinit

```
Before deinit():
┌─────────────────────────────────────────┐
│ HashMap structure (buckets, metadata)   │
│   ├─ Key: "grpc.health.v1.Health" ────┐ │
│   │  Value: SERVING                   │ │
│   └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
         │
         └──> [heap: "grpc.health.v1.Health"]  ← Allocated string

After self.status.deinit():
┌─────────────────────────────────────────┐
│ HashMap structure (FREED)               │ ← ✓ Freed
└─────────────────────────────────────────┘

[heap: "grpc.health.v1.Health"]  ← ✗ LEAKED! No more references to this memory
```

## The Fix

```zig
pub fn deinit(self: *HealthCheck) void {
    // Free all service name keys
    var it = self.status.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.status.deinit();
}
```

### How It Works

1. **Iterate through all keys** using `keyIterator()`
2. **Free each key string** - these are the duplicated service names
3. **Free the hashmap structure** with `deinit()`

The iterator gives us pointers to the keys (`*[]const u8`), so we dereference with `key.*` to get the actual string slice, then free it.

### Why This Pattern Is Needed

This is a common pattern in Zig when using hashmaps with heap-allocated keys:

```zig
// Allocation: You dupe when inserting
const key = try allocator.dupe(u8, "some_key");
try map.put(key, value);

// Cleanup: You must free when removing/deinit
var it = map.keyIterator();
while (it.next()) |k| allocator.free(k.*);
map.deinit();
```

Zig's hashmaps are **non-owning** - they don't automatically manage the memory of their contents. This gives you flexibility but requires explicit cleanup.

## Why This Bug Existed

Like the client leak, this was a **pre-existing bug** in gRPC-zig.

Looking at the original code (commit `bd81fea`):

```zig
// Original health.zig
pub fn deinit(self: *HealthCheck) void {
    self.status.deinit();  // ← Missing key cleanup
}
```

The cleanup logic was incomplete from the start.

### Why It Wasn't Caught

1. **Small string, small leak** - Service names are typically short strings (e.g., "grpc.health.v1.Health")
2. **Usually only one service** - Most servers register 1-2 health check services
3. **Server lifetime** - Servers often run indefinitely, so leak detection only fires on shutdown
4. **No leak detection in tests** - The library doesn't test with GPA leak checking enabled

## Testing

Verified with Zig's `GeneralPurposeAllocator` in leak detection mode:

**Before fix:**

```
error(gpa): memory address 0x1025e0000 leaked:
/Users/.../std/mem/Allocator.zig:436:40: in dupe__anon_5679
/Users/.../gRPC-zig/src/features/health.zig:26:52: in setStatus
```

**After fix:**

```
(no memory errors)
```

## Related Pattern: Updating Keys

Note that if you want to **update** a key (replace an existing service name), you need to:

1. Free the old key if it exists
2. Store the new key

Example:

```zig
pub fn setStatus(self: *HealthCheck, service: []const u8, status: HealthStatus) !void {
    const service_key = try self.allocator.dupe(u8, service);
    errdefer self.allocator.free(service_key);

    const result = try self.status.getOrPut(service_key);
    if (result.found_existing) {
        self.allocator.free(result.key_ptr.*);  // Free old key
        result.key_ptr.* = service_key;         // Replace with new key
    }
    result.value_ptr.* = status;
}
```

However, in this codebase, service names are static strings that don't change, so the simple `put()` is sufficient.
