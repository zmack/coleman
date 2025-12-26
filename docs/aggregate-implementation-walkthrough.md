# Aggregate Operations Implementation Walkthrough

**Purpose**: This document provides a comprehensive walkthrough of the aggregate operations implementation (COUNT and SUM), explaining the architecture, design decisions, and integration points.

**Target Audience**: Code reviewers, maintainers, and developers extending the aggregate functionality.

**Date**: December 25, 2025
**Implementation**: Phase 3.3 - Partial (COUNT and SUM)

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Implementation Details](#implementation-details)
4. [Design Decisions](#design-decisions)
5. [Testing Strategy](#testing-strategy)
6. [Usage Examples](#usage-examples)
7. [Future Extensions](#future-extensions)

---

## Overview

### What Was Implemented

We added **aggregate operations** to Coleman's columnar database, specifically:
- **COUNT**: Count rows (optionally filtered by predicates)
- **SUM**: Sum numeric values in a column (int64/float64, optionally filtered)

### Key Achievement

**Production-ready analytical queries** with:
- ✅ Type-safe aggregation over columnar data
- ✅ Predicate support (WHERE clauses)
- ✅ Thread-safe concurrent reads
- ✅ Comprehensive test coverage (10 new tests, 32/32 total passing)
- ✅ Zero memory leaks

### Deferred Features

- AVG, MIN, MAX aggregate functions
- GROUP BY support
- Multiple aggregates in single query
- DISTINCT modifier

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        gRPC Client                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ AggregateRequest
                              │ (table_name, column_name, function, predicates)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              src/server.zig::handleAggregate()              │
│  • Deserialize AggregateRequest                             │
│  • Call TableManager.aggregate()                            │
│  • Convert result to AggregateResponse                      │
│  • Handle errors gracefully                                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│        src/table_manager.zig::aggregate()                   │
│  • Acquire shared lock (thread-safe reads)                  │
│  • Lookup table by name                                     │
│  • Delegate to aggregate module                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│    src/query/aggregate.zig::aggregateTable()                │
│  • Find column by name                                      │
│  • Reuse filter infrastructure for predicates               │
│  • Dispatch to COUNT or SUM                                 │
│  • Return scalar Value (int64 or float64)                   │
└─────────────────────────────────────────────────────────────┘
                              │
            ┌─────────────────┴─────────────────┐
            │                                   │
            ▼                                   ▼
    ┌──────────────┐                  ┌──────────────┐
    │ COUNT        │                  │ SUM          │
    │ • Count rows │                  │ • Type check │
    │ • Return i64 │                  │ • Dispatch   │
    └──────────────┘                  │ • Sum values │
                                      └──────────────┘
                                             │
                              ┌──────────────┴──────────────┐
                              │                             │
                              ▼                             ▼
                     ┌────────────────┐          ┌────────────────┐
                     │ sumInt64()     │          │ sumFloat64()   │
                     │ • i64 sum      │          │ • f64 sum      │
                     └────────────────┘          └────────────────┘
```

### Data Flow

1. **Client** → Sends `AggregateRequest(table_name, column_name, function, predicates)`
2. **Server Handler** → Deserializes request, validates
3. **TableManager** → Thread-safe table lookup with shared lock
4. **Aggregate Module** →
   - Finds column by name
   - Filters rows using existing filter infrastructure
   - Computes aggregate over filtered rows
   - Returns scalar `table.Value`
5. **Server Handler** → Converts `table.Value` to protobuf, serializes response
6. **Client** → Receives `AggregateResponse(result, error)`

---

## Implementation Details

### 1. Protobuf Definitions

**Files**: `proto/log.proto`, `src/proto/log.pb.zig`

#### New Types

```protobuf
// Enum for aggregate functions
enum AggregateFunction {
  COUNT = 0;
  SUM = 1;
}

// Request message
message AggregateRequest {
  string table_name = 1;      // Table to aggregate
  string column_name = 2;     // Column to aggregate over
  AggregateFunction function = 3;  // COUNT or SUM
  repeated Predicate predicates = 4;  // Optional WHERE clause
}

// Response message
message AggregateResponse {
  Value result = 1;   // Scalar result (int64 or float64)
  string error = 2;   // Error message if failed
}
```

**Design Note**: We reuse the existing `Predicate` type from filter implementation, enabling WHERE clause support without duplicating code.

---

### 2. Core Aggregate Module

**File**: `src/query/aggregate.zig` (80 lines)

#### Main API

```zig
pub fn aggregateTable(
    allocator: std.mem.Allocator,
    tbl: *const table.Table,
    column_name: []const u8,
    function: pb.AggregateFunction,
    predicates: []const pb.Predicate,
) !table.Value
```

**Flow**:
1. Find column index by name → `error.ColumnNotFound` if missing
2. Call `filter_mod.filterTable()` to get matching row indices
3. Dispatch to aggregate function (COUNT or SUM)
4. Return scalar `table.Value`

#### COUNT Implementation

```zig
fn aggregateCount(row_count: usize) !table.Value {
    return table.Value.fromInt64(@intCast(row_count));
}
```

**Simplicity**: COUNT just converts the row count to int64. Works on any column type since we're counting rows, not values.

#### SUM Implementation

```zig
fn aggregateSum(
    tbl: *const table.Table,
    col_idx: usize,
    row_indices: []const usize,
) !table.Value {
    const column = tbl.columns[col_idx];

    // Type dispatch based on column type
    return switch (column) {
        .int64 => |int_col| sumInt64(int_col, row_indices),
        .float64 => |float_col| sumFloat64(float_col, row_indices),
        .string, .bool => error.InvalidColumnType,
    };
}
```

**Type Safety**: SUM uses Zig's union tag matching to dispatch to the correct sum function. Non-numeric types return `error.InvalidColumnType`.

---

### 3. TableManager Integration

**File**: `src/table_manager.zig:208`

```zig
pub fn aggregate(
    self: *TableManager,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    function: pb.AggregateFunction,
    predicates: []const pb.Predicate,
) !table.Value {
    // Shared lock - allows concurrent aggregate queries
    self.lock.lockShared();
    defer self.lock.unlockShared();

    const tbl = self.tables.get(table_name) orelse return error.TableNotFound;

    // Delegate to aggregate module
    return aggregate_mod.aggregateTable(allocator, tbl, column_name, function, predicates);
}
```

**Thread Safety**: Uses `lockShared()` to allow **concurrent aggregate operations** while blocking writes. Same pattern as `scan()` and `filter()`.

---

### 4. Server Handler

**File**: `src/server.zig:258`

```zig
fn handleAggregate(input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
    // 1. Deserialize request
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    var any_reader = reader.any();
    const req = try log_proto.AggregateRequest.decode(&any_reader, allocator);
    var mutable_req = req;
    defer mutable_req.deinit(allocator);

    // 2. Call TableManager.aggregate with error handling
    const result = g_table_manager.aggregate(
        allocator,
        req.table_name,
        req.column_name,
        req.function,
        req.predicates.items,
    ) catch |err| {
        // Return error response
        var res = log_proto.AggregateResponse{
            .error_msg = @errorName(err),
        };
        var out_list: std.ArrayList(u8) = .{};
        const writer = out_list.writer(allocator);
        try res.encode(&writer, allocator);
        return out_list.toOwnedSlice(allocator);
    };

    // 3. Convert result and serialize response
    const proto_result = tableValueToProto(result);
    var res = log_proto.AggregateResponse{ .result = proto_result };
    var out_list: std.ArrayList(u8) = .{};
    const writer = out_list.writer(allocator);
    try res.encode(&writer, allocator);
    return out_list.toOwnedSlice(allocator);
}
```

**Error Handling**: All errors are caught and returned as `AggregateResponse.error_msg` rather than crashing the server.

**Handler Registration**: `src/server.zig:341`
```zig
try server.handlers.append(allocator, .{
    .name = "log.LogService/Aggregate",
    .handler_fn = handleAggregate,
});
```

---

## Design Decisions

### 1. Reuse Filter Infrastructure

**Decision**: Call `filter_mod.filterTable()` to get matching row indices.

**Why**:
- ✅ **DRY Principle**: Don't duplicate predicate evaluation logic
- ✅ **Consistency**: Predicates behave identically in filter and aggregate
- ✅ **Maintainability**: Bug fixes to filter logic automatically apply to aggregates
- ✅ **Performance**: Filter is already optimized with arena allocators

**Implementation**:
```zig
// Get matching row indices (reuse filter logic)
var matching_indices = try filter_mod.filterTable(allocator, tbl, predicates);
defer matching_indices.deinit(allocator);

// Apply aggregate to filtered rows
return switch (function) {
    .COUNT => aggregateCount(matching_indices.items.len),
    .SUM => try aggregateSum(tbl, col_idx, matching_indices.items),
};
```

---

### 2. Return Scalar Value, Not Rows

**Decision**: Aggregates return a single `table.Value`, not `[][]table.Value` like filter/scan.

**Why**:
- ✅ **Semantically Correct**: Aggregates reduce data to a scalar
- ✅ **Memory Efficient**: No need to allocate/free row arrays
- ✅ **Simple API**: Single value easier to work with than arrays
- ✅ **Type Safe**: `table.Value` union ensures type correctness

**Contrast with Filter**:
```zig
// Filter returns rows
fn filter(...) -> [][]table.Value

// Aggregate returns scalar
fn aggregate(...) -> table.Value
```

---

### 3. Type Dispatch for SUM

**Decision**: Use Zig union tag matching to dispatch int64 vs float64.

**Why**:
- ✅ **Compile-Time Safety**: Catches type errors at compile time
- ✅ **Zero Runtime Overhead**: Tag matching compiles to simple jumps
- ✅ **Clear Error Messages**: Non-numeric types explicitly return `error.InvalidColumnType`
- ✅ **Extensible**: Easy to add new numeric types later

**Implementation**:
```zig
return switch (column) {
    .int64 => |int_col| sumInt64(int_col, row_indices),
    .float64 => |float_col| sumFloat64(float_col, row_indices),
    .string, .bool => error.InvalidColumnType,  // Explicit error
};
```

---

### 4. COUNT Any Column Type

**Decision**: COUNT accepts any column type (int64, float64, string, bool).

**Why**:
- ✅ **SQL Semantics**: `COUNT(column)` counts rows, not values
- ✅ **Simplicity**: No type checking needed for COUNT
- ✅ **Flexibility**: Users can count on any column (usually use primary key)

**Note**: We don't implement `COUNT(*)` yet, but `COUNT(id)` achieves the same result.

---

### 5. Defer Advanced Aggregates

**Decision**: Defer AVG, MIN, MAX, GROUP BY to future development.

**Why**:
- ✅ **Incremental Delivery**: SUM and COUNT provide immediate value
- ✅ **Reduce Complexity**: GROUP BY requires significant architectural changes
- ✅ **Test Coverage**: 10 tests for 2 functions is better than 3 tests for 5 functions
- ✅ **AVG = SUM/COUNT**: Can be computed client-side with existing functions

**Roadmap**: See "Future Extensions" section below.

---

## Testing Strategy

### Test Coverage

**File**: `tests/aggregate_test.zig` (361 lines, 10 tests)

#### Test Categories

**Positive Cases** (6 tests):
1. ✅ COUNT all rows (no predicates) → Returns 3
2. ✅ COUNT with filter (score > 60) → Returns 2
3. ✅ SUM int64 values → 100 + 250 + 150 = 500
4. ✅ SUM float64 values → 9.99 + 19.99 + 5.50 = 35.48
5. ✅ SUM with filter (category = 1) → Returns 250

**Edge Cases** (2 tests):
6. ✅ COUNT empty table → Returns 0
7. ✅ SUM no matching rows → Returns 0

**Error Cases** (3 tests):
8. ✅ SUM on string column → `error.InvalidColumnType`
9. ✅ Non-existent column → `error.ColumnNotFound`
10. ✅ Non-existent table → `error.TableNotFound`

#### Test Pattern

All tests follow the same structure from `filter_test.zig`:

```zig
test "aggregate: COUNT all rows" {
    const allocator = testing.allocator;

    // 1. Setup config with unique WAL/snapshot paths
    const test_config = config.Config{ ... };

    // 2. Initialize TableManager
    var tm = try table_manager.TableManager.init(allocator, test_config);
    defer tm.deinit();
    defer {
        std.fs.cwd().deleteFile(test_config.wal_path) catch {};
        std.fs.cwd().deleteTree(test_config.snapshot_dir) catch {};
    }

    // 3. Create table with schema
    const cols = [_]schema.ColumnDef{ ... };
    const table_schema = try schema.Schema.init(allocator, &cols);
    try tm.createTable("test", table_schema);

    // 4. Insert test data
    try tm.addRecord("test", &[_]table.Value{ ... });

    // 5. Execute aggregate
    const result = try tm.aggregate(allocator, "test", "id", .COUNT, empty_predicates);

    // 6. Assert result
    try testing.expectEqual(@as(i64, 3), result.int64);
}
```

**Why This Pattern**:
- ✅ **Isolation**: Each test uses unique file paths, can run in parallel
- ✅ **Cleanup**: `defer` ensures files deleted even on failure
- ✅ **Realistic**: Uses full TableManager, not mocks
- ✅ **Memory Safe**: GPA leak detection catches any leaks

---

### Test Results

```bash
$ zig build test-unit
Build Summary: 7/7 steps succeeded; 32/32 tests passed
test success
```

**Coverage**:
- ✅ All aggregate code paths tested
- ✅ All error conditions tested
- ✅ Both numeric types (int64, float64) tested
- ✅ Filtered and unfiltered aggregation tested
- ✅ Zero memory leaks (verified with GPA)

---

## Usage Examples

### Example 1: COUNT All Rows

**gRPC Request**:
```protobuf
AggregateRequest {
  table_name: "users"
  column_name: "id"
  function: COUNT
  predicates: []  // Empty = no filter
}
```

**Response**:
```protobuf
AggregateResponse {
  result: { int64_value: 1000 }
}
```

**SQL Equivalent**: `SELECT COUNT(id) FROM users`

---

### Example 2: COUNT with Filter

**gRPC Request**:
```protobuf
AggregateRequest {
  table_name: "products"
  column_name: "id"
  function: COUNT
  predicates: [
    { column_name: "price", operator: GREATER_THAN, value: { float64_value: 100.0 } }
  ]
}
```

**Response**:
```protobuf
AggregateResponse {
  result: { int64_value: 42 }
}
```

**SQL Equivalent**: `SELECT COUNT(id) FROM products WHERE price > 100.0`

---

### Example 3: SUM with Filter

**gRPC Request**:
```protobuf
AggregateRequest {
  table_name: "sales"
  column_name: "amount"
  function: SUM
  predicates: [
    { column_name: "category", operator: EQUAL, value: { int64_value: 1 } }
  ]
}
```

**Response**:
```protobuf
AggregateResponse {
  result: { int64_value: 25000 }
}
```

**SQL Equivalent**: `SELECT SUM(amount) FROM sales WHERE category = 1`

---

### Example 4: Error Case - Invalid Column Type

**gRPC Request**:
```protobuf
AggregateRequest {
  table_name: "users"
  column_name: "name"  // string column
  function: SUM
  predicates: []
}
```

**Response**:
```protobuf
AggregateResponse {
  error: "InvalidColumnType"
}
```

**Why**: SUM only works on numeric columns (int64, float64).

---

## Future Extensions

### 1. AVG Aggregate

**Implementation Strategy**:
```zig
fn aggregateAvg(tbl, col_idx, row_indices) !table.Value {
    if (row_indices.len == 0) return table.Value.fromFloat64(0.0);

    const sum = try aggregateSum(tbl, col_idx, row_indices);
    const count = @as(f64, @floatFromInt(row_indices.len));

    return switch (sum) {
        .int64 => |v| table.Value.fromFloat64(@as(f64, @floatFromInt(v)) / count),
        .float64 => |v| table.Value.fromFloat64(v / count),
        else => unreachable,
    };
}
```

**Complexity**: Low - reuses SUM logic
**Benefit**: Common analytical operation

---

### 2. MIN/MAX Aggregates

**Implementation Strategy**:
```zig
fn aggregateMin(tbl, col_idx, row_indices) !table.Value {
    var min_value: ?table.Value = null;

    for (row_indices) |idx| {
        const val = try tbl.getValue(idx, col_idx);
        if (min_value == null or compareValues(val, min_value.?, .LESS_THAN)) {
            min_value = val;
        }
    }

    return min_value orelse error.EmptyResult;
}
```

**Complexity**: Medium - requires value comparison logic
**Benefit**: Range queries, data validation
**Note**: Can reuse `compareValues()` from filter.zig

---

### 3. GROUP BY Support

**Implementation Strategy**:
```zig
pub const GroupResult = struct {
    group_key: table.Value,
    aggregates: []AggregateResult,
};

pub fn groupBy(
    allocator: std.mem.Allocator,
    tbl: *const table.Table,
    group_column: []const u8,
    aggregate_specs: []const AggregateSpec,
    predicates: []const pb.Predicate,
) ![]GroupResult {
    // 1. Filter rows (apply WHERE)
    var matching_indices = try filterTable(allocator, tbl, predicates);
    defer matching_indices.deinit(allocator);

    // 2. Group by group_column value using HashMap
    var groups: std.AutoHashMap(table.Value, std.ArrayList(usize)) = ...;

    // 3. Compute aggregates for each group
    for (groups) |group_key, row_indices| {
        for (aggregate_specs) |spec| {
            // Compute aggregate over this group's rows
        }
    }

    return group_results;
}
```

**Complexity**: High - requires:
- HashMap with Value keys (needs custom hash function)
- Multiple aggregates per group
- New protobuf messages for GROUP BY requests
- More complex response structure

**Benefit**: Full analytical query capabilities (e.g., `SELECT category, SUM(amount) FROM sales GROUP BY category`)

---

### 4. Multiple Aggregates in Single Query

**Example**: `SELECT COUNT(*), SUM(amount), AVG(price) FROM products WHERE category = 1`

**Implementation**:
```protobuf
message AggregateRequest {
  string table_name = 1;
  repeated AggregateSpec aggregates = 2;  // Multiple aggregates
  repeated Predicate predicates = 3;
}

message AggregateSpec {
  string column_name = 1;
  AggregateFunction function = 2;
}

message AggregateResponse {
  repeated Value results = 1;  // One result per aggregate
  string error = 2;
}
```

**Complexity**: Medium - mostly API changes
**Benefit**: Reduces round trips, more efficient queries

---

## Performance Considerations

### Current Performance Characteristics

**Time Complexity**:
- Column lookup: O(n) where n = number of columns (typically small)
- Filtering: O(m × p) where m = rows, p = predicates
- SUM/COUNT: O(k) where k = matching rows
- **Overall**: O(m × p + k) ≈ O(m) for typical queries

**Space Complexity**:
- Filtered indices: O(k) temporary allocation
- Arena allocator: O(p) for predicate evaluation (freed after query)
- Result: O(1) - single scalar value
- **Overall**: O(k) temporary, O(1) persistent

**Thread Safety**:
- Read lock: Allows concurrent aggregate queries
- No lock contention between aggregates and scans/filters
- Writes block all reads (expected behavior)

### Optimization Opportunities

1. **Column Index Cache**: HashMap for O(1) column name lookup
2. **Vectorization**: SIMD for sum operations on large datasets
3. **Parallel Aggregation**: Split large column ranges across threads
4. **Index Support**: Pre-computed indices for common predicates

**Note**: Current implementation prioritizes correctness and maintainability over micro-optimizations. Optimize when benchmarks show bottlenecks.

---

## Conclusion

This implementation provides **production-ready aggregate operations** for Coleman's columnar database:

✅ **Core Functionality**: COUNT and SUM with predicate support
✅ **Type Safety**: Compile-time checked, runtime validated
✅ **Thread Safety**: Concurrent reads via shared locks
✅ **Test Coverage**: 10 comprehensive tests, zero memory leaks
✅ **Maintainability**: Reuses existing infrastructure, clear error handling
✅ **Extensibility**: Foundation for AVG, MIN, MAX, GROUP BY

**Next Steps**:
1. Add AVG, MIN, MAX (straightforward extensions)
2. Implement GROUP BY (significant feature)
3. Performance benchmarking with large datasets
4. Add integration tests for end-to-end gRPC workflows

**Questions?** See:
- `tests/aggregate_test.zig` for usage examples
- `src/query/aggregate.zig` for implementation details
- `plans/columnar-storage-plan.md` for roadmap
