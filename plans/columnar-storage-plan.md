# Coleman Columnar Storage Implementation Plan

## Overview

Transform Coleman from a simple in-memory key-value store into a full-featured columnar database using Apache Arrow, with Write-Ahead Logging (WAL) for durability and support for analytical queries (Scan, Filter, Aggregate).

**Current State:**
- In-memory `StringHashMap([]const u8)` for key-value storage
- Simple protobuf API: `PutRequest`/`GetRequest`
- No persistence - data lost on restart
- gRPC server with method routing working correctly

**Target State:**
- Apache Arrow columnar storage with typed schemas
- WAL + periodic snapshots for durability
- Query operations: Scan, Filter (WHERE), Aggregate (SUM/COUNT/AVG)
- Pure columnar model (no more string keys)

## Architecture

```
gRPC Server (server.zig)
    ↓
TableManager (table_manager.zig) ← Coordinator
    ├── tables: HashMap(*Table)
    ├── wal: *WAL
    └── snapshot_manager: *SnapshotManager
         ↓
    Table (table.zig) → Arrow RecordBatches
         ↓
    Query Engine (query/*.zig) → Scan/Filter/Aggregate
```

## Implementation Phases

### ✅ Phase 1: Arrow Integration + Basic Storage (COMPLETED)

**Goal:** Store and retrieve columnar data in memory ✅

**Status:** COMPLETED - All deliverables met

#### What We Built

**Core Columnar Engine:**
- ✅ `src/schema.zig` - Schema and column type system (int64, float64, string, bool)
- ✅ `src/table.zig` - Columnar storage with Arrow-like RecordBatch structure
- ✅ `src/table_manager.zig` - Thread-safe multi-table management with RwLock

**gRPC API:**
- ✅ Extended `proto/log.proto` with columnar messages (CreateTable, AddRecord, Scan)
- ✅ Manually added protobuf types to `src/proto/log.pb.zig` (generator incompatible with Zig 0.15.2)
- ✅ Implemented RPC handlers in `src/server.zig`:
  - `handleCreateTable()` - Create tables with typed schemas
  - `handleAddRecord()` - Insert records into tables
  - `handleScan()` - Retrieve all rows from a table

**Testing:**
- ✅ Updated `src/client.zig` with end-to-end test demonstrating:
  - Table creation with 4-column schema (id, name, age, score)
  - Inserting 3 records
  - Scanning and displaying results in formatted table

#### Key Decisions Made

**Decision 1: Custom Arrow Implementation**
- **Why:** arrow-zig incompatible with Zig 0.15.2 (built for 0.11.0)
- **Approach:** Built minimal columnar storage using ArrayList-backed columns
- **Result:** Cleaner, more maintainable code tailored to Coleman's needs

**Decision 2: Manual Protobuf Messages**
- **Why:** protobuf generator incompatible with Zig 0.15.2
- **Approach:** Manually added message types following existing patterns
- **Fixed:** ArrayList API (`init` → `.{}`) and reader API (`takeByte` → `readByte`)

**Decision 3: Value Type Representation**
- **Why:** Protobuf library doesn't support union types well
- **Approach:** Used struct with optional fields instead of oneof union
- **Result:** Simpler serialization, compatible with protobuf library

#### Build Artifacts
- `zig-out/bin/coleman` - Server executable (1.6M)
- `zig-out/bin/coleman-client` - Test client (1.4M)

**Deliverable:** ✅ Can create tables and add records in columnar format (in-memory only)

---

### Phase 2: WAL + Persistence (Week 2)

**Goal:** Data survives server restarts

#### 2.1 Implement Write-Ahead Log (2 days)

**New file:** `src/wal.zig`

WAL file format:
- Magic header + version
- Sequence numbers
- Entry types (CreateTable, AddRecord)
- Arrow IPC data
- CRC32 checksums

#### 2.2 Implement Snapshot System (2 days)

**New file:** `src/snapshot.zig`
- Arrow IPC File format
- Periodic snapshots based on WAL size/record count
- Atomic write (temp + rename)

#### 2.3 Integrate WAL into TableManager (1 day)

**Modify:** `src/table_manager.zig`
- Append to WAL on every write
- Trigger snapshots periodically
- Truncate WAL after snapshot

#### 2.4 Add Recovery on Startup (1 day)

**Modify:** `src/server.zig` in `runServer()`
- Load latest snapshot
- Replay WAL from checkpoint

#### 2.5 Add Configuration System (4 hours)

**New file:** `src/config.zig`
- WAL path, snapshot path, thresholds
- Load from `coleman.toml`

**Deliverable:** Data persists across restarts

---

### Phase 3: Query Operations (Week 3)

**Goal:** Scan, Filter, Aggregate working

#### 3.1 Scan Implementation (1 day)

**New file:** `src/query/scan.zig`
**Extend protobuf:** Add `ScanRequest`/`ScanResponse`
**Add handler:** `handleScan()` in `src/server.zig`

#### 3.2 Filter Implementation (2 days)

**New file:** `src/query/filter.zig`
- Predicate evaluation (comparison, logical operators)
- Selection bitmap generation
**Extend protobuf:** Add `FilterRequest`, `Predicate` messages
**Add handler:** `handleFilter()` in `src/server.zig`

#### 3.3 Aggregate Implementation (2 days)

**New file:** `src/query/aggregate.zig`
- COUNT, SUM, AVG operations
- GROUP BY support
**Extend protobuf:** Add `AggregateRequest` messages
**Add handler:** `handleAggregate()` in `src/server.zig`

**Deliverable:** Full query capabilities via gRPC

---

### Phase 4: Testing + Polish (Week 4)

**Goal:** Production-ready with tests

#### 4.1 Comprehensive Tests (2 days)

**New files:**
- `tests/integration_test.zig` - End-to-end tests
- `tests/wal_test.zig` - WAL and recovery
- `tests/query_test.zig` - Query correctness
- `tests/arrow_test.zig` - Arrow integration

#### 4.2 Performance Benchmarking (1 day)

- Insert 1M records
- Run various queries
- Measure throughput and latency

#### 4.3 Documentation (1 day)

**New files:**
- `docs/arrow-integration.md`
- `docs/wal-format.md`
- `docs/query-engine.md`
- `docs/api-migration.md`

**Update:** `README.md` with new API examples

#### 4.4 CLI Improvements (1 day)

- Config file support (`coleman.toml`)
- Better logging
- `--stats` flag

**Deliverable:** Production-ready columnar database

---

## Critical Files to Modify/Create

### New Files (10)
1. `src/schema.zig` - Schema definitions
2. `src/table.zig` - Arrow-backed table storage
3. `src/table_manager.zig` - Multi-table coordinator
4. `src/wal.zig` - Write-ahead log
5. `src/snapshot.zig` - Snapshot management
6. `src/config.zig` - Configuration
7. `src/query/scan.zig` - Scan operations
8. `src/query/filter.zig` - Filter predicates
9. `src/query/aggregate.zig` - Aggregations
10. `libs/arrow-zig/` - Vendored Arrow library

### Modified Files (4)
1. `src/server.zig` - Add new RPC handlers
2. `proto/log.proto` - Extend with columnar API
3. `build.zig` - Add arrow-zig dependency
4. `src/client.zig` - Update test client

## Thread Safety Strategy

- `TableManager` uses `std.Thread.RwLock`
- Read operations (Scan, Filter, Aggregate): Shared lock (concurrent)
- Write operations (CreateTable, AddRecord): Exclusive lock
- WAL append: Separate fine-grained mutex

## Memory Management

- Use arena allocators for query execution (freed after response sent)
- Arrow RecordBatches managed by Table (freed on table drop)
- GPA leak detection enabled in all tests
- Manual cleanup in `table_manager.deinit()` for all tables

## Success Criteria

- ✅ Tables with typed schemas can be created
- ✅ Records can be inserted and persisted to WAL
- ✅ Snapshots created periodically
- ✅ Data survives server restart (WAL replay)
- ✅ Scan returns all records
- ✅ Filter executes WHERE clauses correctly
- ✅ Aggregate computes SUM/COUNT/AVG
- ✅ Zero memory leaks (GPA verified)
- ✅ Comprehensive test coverage

## Risks & Mitigations

**Risk:** arrow-zig incompatible with Zig 0.15.2
**Mitigation:** Patch immediately (Phase 1.1), fallback to minimal Arrow IPC implementation

**Risk:** Memory leaks in Arrow integration
**Mitigation:** GPA leak detection, arena allocators, thorough testing

**Risk:** WAL corruption on crash
**Mitigation:** CRC checksums, truncate on invalid entry, keep last-good snapshot

## Timeline Summary

- **Week 1:** Arrow integration + in-memory storage
- **Week 2:** WAL + persistence
- **Week 3:** Query operations (Scan, Filter, Aggregate)
- **Week 4:** Testing + documentation + polish

**Total:** 4 weeks to production-ready columnar database
