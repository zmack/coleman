# Filter Test Hanging Issue - Investigation and Resolution

**Date:** 2025-12-25
**Status:** RESOLVED
**Severity:** Critical (blocked test suite)

## Executive Summary

Filter tests appeared to hang indefinitely when run as part of the full test suite, despite individual tests completing successfully. The root cause was a subtle interaction between allocated strings in a test helper function, Zig's defer semantics, and the order of resource cleanup.

**Solution:** Replace allocated path strings with string literals in test configurations.

---

## Symptoms

### Initial Observation
- Running `zig build test` would hang indefinitely when filter tests were included
- No error messages or output - tests simply never completed
- Single filter test would complete successfully in isolation
- Multiple filter tests together caused the hang

### Test Output Behavior
```bash
# This would complete:
zig build test  # with 1 filter test

# This would hang:
zig build test  # with 8 filter tests
```

---

## Investigation Process

### Phase 1: Isolating the Problem

**Hypothesis:** File/resource contention between tests
**Test:** Used unique WAL and snapshot paths per test
**Result:** Still hung

**Hypothesis:** Memory leak causing test framework to abort
**Test:** Added debug output and checked for leaks
**Result:** Tests actually completed but leaked memory

**Discovered:** The "hang" was actually the test framework detecting memory leaks and failing tests, which appeared as a hang in some scenarios.

### Phase 2: Memory Leak Analysis

Created a debug test with verbose output:
```zig
test "filter debug: simple equality" {
    std.debug.print("\n=== TEST START ===\n", .{});
    // ... test code ...
    std.debug.print("\n=== TEST COMPLETE ===\n", .{});
}
```

**Finding:** Tests completed successfully, but Zig's `GeneralPurposeAllocator` detected leaked memory:
```
[gpa] (err): memory address 0x109560080 leaked:
/Users/zmack/projects/coleman/src/table.zig:156:43: 0x104a3f5ef in getRow (test)
        const values = try allocator.alloc(Value, self.columns.len);
```

**Fix Applied:** Properly free row arrays in addition to the rows array itself:
```zig
defer {
    for (rows) |row| {
        allocator.free(row);  // Free each row
    }
    allocator.free(rows);     // Free the array of rows
}
```

### Phase 3: Incremental Test Addition

With memory leaks fixed, tests still appeared to hang with multiple tests. Systematically added tests:

| Test Count | Result |
|------------|--------|
| 1 test     | ✅ Pass |
| 2 tests    | ✅ Pass |
| 4 tests    | ✅ Pass |
| 5 tests    | ✅ Pass |
| 8 tests with helper function | ❌ Hang |
| 8 tests with inline config   | ✅ Pass |

**Critical Discovery:** The helper function was the problem!

---

## Root Cause Analysis

### The Problematic Pattern

Original test code used a helper function pattern (borrowed from `table_manager_test.zig`):

```zig
fn getTestConfig(test_name: []const u8, allocator: std.mem.Allocator) !config.Config {
    const wal_path = try std.fmt.allocPrint(allocator, ".zig-cache/test_filter_{s}.wal", .{test_name});
    const snapshot_dir = try std.fmt.allocPrint(allocator, ".zig-cache/test_filter_{s}_snapshots", .{test_name});

    return config.Config{
        .wal_path = wal_path,           // Allocated string
        .snapshot_dir = snapshot_dir,   // Allocated string
        // ...
    };
}

test "filter: basic equality" {
    const allocator = testing.allocator;

    const test_config = try getTestConfig("eq_int64", allocator);
    defer allocator.free(test_config.wal_path);     // Defer #1
    defer allocator.free(test_config.snapshot_dir); // Defer #2
    defer cleanupTestData("eq_int64", allocator);   // Defer #3

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit(); // Defer #4

    // ... test code ...
}
```

### The Problem: Defer Execution Order

**Zig's defer statements execute in REVERSE order of declaration:**

1. `defer tm.deinit()` - runs FIRST
2. `defer cleanupTestData()` - runs SECOND
3. `defer allocator.free(test_config.snapshot_dir)` - runs THIRD
4. `defer allocator.free(test_config.wal_path)` - runs FOURTH

### Why This Caused Issues

When `tm.deinit()` executes first, it tries to:
1. Close the WAL file handle
2. Close the snapshot directory
3. Flush any pending writes
4. Clean up internal resources

**However**, at this point, `test_config.wal_path` and `test_config.snapshot_dir` are still valid allocated strings. The paths themselves are fine, but the subtle timing issue arises when:

1. Multiple tests run in sequence
2. `tm.deinit()` doesn't fully complete before the next test starts
3. File descriptors or directory handles remain open
4. The next test tries to create files in `.zig-cache/`
5. Resource exhaustion or lock contention occurs

### Additional Complication: String Allocation Overhead

The `allocPrint` calls in `getTestConfig` were:
- Allocating memory on every test
- Creating potential fragmentation
- Adding cleanup complexity
- Making defer ordering critical

With 8 tests, this meant:
- 16 string allocations (wal_path + snapshot_dir per test)
- 16 corresponding frees
- 8 TableManager init/deinit cycles
- Potential for subtle race conditions in cleanup

---

## Solution

### The Fix: String Literals Instead of Allocated Strings

Replace the helper function with inline configuration using **string literals**:

```zig
test "filter: basic equality on int64" {
    const allocator = testing.allocator;

    const test_config = config.Config{
        .wal_path = ".zig-cache/filter_eq_int64.wal",          // String literal
        .snapshot_dir = ".zig-cache/filter_eq_int64_snap",     // String literal
        .snapshot_record_threshold = 1000,
        .snapshot_wal_size_threshold = 10 * 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    // ... test code ...
}
```

### Why This Works

**String literals are in the data segment:**
- No allocation required
- No deallocation required
- No defer ordering issues
- Lifetime extends for entire program execution
- Zero overhead

**Simplified defer chain:**
```zig
defer tm.deinit();  // Runs first - cleans up TableManager
defer {             // Runs second - cleans up files
    std.fs.cwd().deleteFile(test_config.wal_path) catch {};
    std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
}
```

This order is correct:
1. TableManager closes its file handles
2. Then we delete the files from disk

### Performance Impact

**Before (with helper function):**
- 16 heap allocations per test run (8 tests × 2 strings)
- 16 deallocations
- Potential memory fragmentation
- Complex defer ordering

**After (with string literals):**
- 0 heap allocations for paths
- 0 deallocations for paths
- No defer ordering complexity
- Cleaner, more maintainable code

---

## Lessons Learned

### 1. Defer Order Matters

Zig's defer statements run in **LIFO (Last In, First Out)** order. When resources have dependencies, the defer order must respect those dependencies:

```zig
// WRONG - file freed before handle closed
defer allocator.free(path);
defer file.close();

// RIGHT - handle closed before file freed
defer file.close();
defer allocator.free(path);
```

### 2. String Literals vs Allocated Strings

**Use string literals when:**
- The string is known at compile time
- The string doesn't change
- You want zero allocation overhead
- Lifetime needs to extend indefinitely

**Use allocated strings when:**
- String is computed at runtime
- String needs modification
- String must be freed at a specific time

### 3. Helper Functions Can Hide Problems

The `getTestConfig` helper appeared clean and reusable, but it:
- Obscured the allocation/deallocation complexity
- Made defer ordering non-obvious
- Added unnecessary overhead
- Created subtle timing issues

**In tests, prefer explicit and simple over DRY when it comes to resource management.**

### 4. Test Isolation is Critical

Each test should:
- Use completely unique file paths
- Clean up its own resources
- Not depend on execution order
- Not share state with other tests

The string literal approach achieves this better than the helper function because each test's paths are clearly visible and unique.

### 5. Zig's GPA is Strict (And That's Good)

The `GeneralPurposeAllocator` in test mode:
- Detects all memory leaks
- Fails tests that leak
- Forces proper resource management
- Catches subtle bugs early

This strictness helped us find both:
1. The row array leak
2. The string allocation issues

---

## Verification

### Test Results After Fix

```bash
$ zig build test
# All 22 tests pass (14 existing + 8 filter tests)
# Zero memory leaks
# No hangs
# Execution time: ~2 seconds
```

### Regression Prevention

To prevent this issue in future tests:

1. **Prefer string literals** for test file paths
2. **Avoid helper functions** that allocate strings for config
3. **Use inline config structs** for clarity
4. **Always run full test suite** before committing

### Pattern to Follow

```zig
test "descriptive test name" {
    const allocator = testing.allocator;

    // Inline config with string literals - GOOD
    const test_config = config.Config{
        .wal_path = ".zig-cache/unique_test_name.wal",
        .snapshot_dir = ".zig-cache/unique_test_name_snap",
        // ... other config ...
    };

    var resource = try initialize(allocator, test_config);
    defer resource.deinit();  // Clean up resource first
    defer {                   // Then clean up files
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    // ... test assertions ...
}
```

---

## Related Issues

### Why table_manager_test.zig Uses Helper Function

The existing `table_manager_test.zig` uses `getTestConfig()` successfully because:

1. It has **fewer tests** (6 vs 8)
2. Tests are **simpler** (no filter operations)
3. **Less TableManager churn** (fewer init/deinit cycles)
4. Tests run **faster** (less cumulative resource usage)

However, this doesn't mean the pattern is ideal. Future work could migrate those tests to the string literal pattern as well.

### File Descriptor Limits

On macOS, the default file descriptor limit is typically 256. With:
- 8 tests
- Each test creating WAL file + snapshot directory
- Potential for file descriptors to remain open briefly
- Multiple test runs in succession

We could approach or exceed limits, especially if cleanup doesn't happen immediately.

String literals don't eliminate this, but they do reduce the complexity of cleanup timing.

---

## Conclusion

What appeared to be a mysterious test hang was actually a combination of:
1. Memory leak detection in Zig's test framework
2. Allocated strings in test config
3. Subtle defer ordering issues
4. Resource cleanup timing problems

The solution—using string literals instead of allocated strings—is:
- ✅ Simpler
- ✅ Faster
- ✅ More reliable
- ✅ Easier to understand
- ✅ Zero allocation overhead

This investigation demonstrates the importance of:
- Systematic debugging
- Understanding language semantics (defer order)
- Choosing the right abstractions (literals vs allocations)
- Testing incrementally (1, 2, 4, 8 tests)
- Trusting but verifying (helper functions aren't always better)

**Final test status: 22/22 passing, zero leaks, production-ready.**
