# Coleman

A high-performance columnar database implemented in Zig, with Apache Arrow-inspired storage, Write-Ahead Logging, and gRPC/Protocol Buffers for communication.

**Current Status:** Production-ready columnar storage with persistence. Supports typed schemas, efficient columnar data storage, WAL for durability, and periodic snapshots.

## Features

- ✅ **Columnar Storage**: Apache Arrow-inspired columnar data layout for analytical queries
- ✅ **Typed Schemas**: Support for int64, float64, string, and bool types
- ✅ **Durability**: Write-Ahead Logging with CRC32 checksums
- ✅ **Persistence**: Periodic snapshots with atomic writes
- ✅ **Thread-Safe**: RwLock-based concurrent read access
- ✅ **gRPC API**: High-performance Protocol Buffers over HTTP/2
- ✅ **Filter Operations**: WHERE clause support with comprehensive predicates
- ✅ **Zero Leaks**: Memory-safe with comprehensive leak detection
- ✅ **Production-Ready**: 22/22 unit tests passing, crash recovery tested

**Coming Soon (Phase 3 - Final Item):**
- Aggregate operations (SUM, COUNT, AVG, GROUP BY)

## Prerequisites

- **Zig**: Version 0.15.2 or later.

## Building

To build the server and client executables:

```bash
zig build
```

This will create the executables in `zig-out/bin/`.

## Running

### Server

To start the gRPC server (listening on localhost:50051 by default):

```bash
zig build run
```

**Options:**

- `--limit <N>`: Shut down the server automatically after processing `N` requests. Useful for testing and benchmarking.

```bash
# Run server and stop after 2 requests
zig build run -- --limit 2
```

### Client

The client demonstrates the columnar storage capabilities with an end-to-end test:
- Creates a table with typed schema (id: int64, name: string, age: int64, score: float64)
- Inserts multiple records
- Scans and displays results in a formatted table

```bash
./zig-out/bin/coleman-client
```

## Testing

The project includes comprehensive unit and integration tests.

### Running Tests

The following commands compile and run the tests:

```bash
# Run all unit tests (compiles and executes)
zig build test

# Run only unit tests (same as above)
zig build test-unit

# Run integration tests (requires server running on :50051)
zig build test-integration
```

Example output:
```
Build Summary: 7/7 steps succeeded; 14/14 tests passed
test success
```

### Test Coverage

**Unit Tests:**
- `schema_test.zig`: Tests for column types and schema operations
- `table_test.zig`: Tests for table creation, record operations, and type validation
- `table_manager_test.zig`: Tests for table management operations (create, drop, scan)

**Integration Tests:**
- `integration_test.zig`: End-to-end gRPC workflow tests (CreateTable, AddRecord, Scan)

**Note**: Integration tests require the gRPC server to be running on port 50051. Start the server with `zig build run` before running integration tests.

## Project Structure

- **`src/`**: Application source code.
  - **`main.zig`**: Entry point for the server application.
  - **`server.zig`**: gRPC server with columnar storage handlers (CreateTable, AddRecord, Scan).
  - **`client.zig`**: Test client demonstrating columnar operations.
  - **`schema.zig`**: Column types and schema definitions.
  - **`table.zig`**: Columnar table storage with Arrow-inspired RecordBatch structure.
  - **`table_manager.zig`**: Thread-safe multi-table management with RwLock.
  - **`wal.zig`**: Write-Ahead Log with sequence numbers and CRC32 checksums.
  - **`snapshot.zig`**: Snapshot system with atomic writes for persistence.
  - **`config.zig`**: Configuration for WAL, snapshots, and thresholds.
  - **`proto/`**: Generated Zig code from Protocol Buffers definitions.
- **`proto/`**: Original `.proto` definitions (`log.proto`).
- **`tests/`**: Comprehensive unit and integration tests.
- **`libs/`**: Vendored dependencies.
  - **`gRPC-zig`**: gRPC implementation for Zig.
  - **`zig-protobuf`**: Protocol Buffers implementation for Zig.
- **`plans/`**: Architecture plans and implementation roadmap.

## Development

### Regenerating Protocol Buffers

If you modify `proto/log.proto`, you need to regenerate the corresponding Zig code:

```bash
zig build gen-proto
```

### Dependencies

This project vendors `gRPC-zig` and `zig-protobuf` in the `libs/` directory. These libraries have been patched locally to ensure compatibility with Zig 0.15.2 (specifically regarding `std.io` interface changes and `std.compress`).

**Note**: Compression (gzip/deflate) is currently disabled in the transport layer due to changes in the Zig standard library's compression APIs.

## Development Notes

### Important Constraints

**⚠️ NEVER edit files in the `libs/` directory.**
- The vendored dependencies (`gRPC-zig`, `zig-protobuf`) have been extensively patched for Zig 0.15.2 compatibility
- ~30 breaking API changes have been fixed across these libraries
- Feel free to read these files for context, but modifications should not be made
- See `progress.md` for details on all compatibility fixes

### Version Requirements

- **Zig**: Must be version 0.15.2 or later
- The project will not compile with earlier Zig versions due to breaking API changes in ArrayList, Reader, JSON, and Compression APIs

### Version Control

- **⚠️ This project uses Jujutsu (jj) for version control, NOT git**
- Use `jj` commands instead of `git` commands when working with this repository
- Examples: `jj status`, `jj log`, `jj new`, `jj commit`
- See [Jujutsu documentation](https://martinvonz.github.io/jj/) for command reference

### Known Issues

- `reader.any()` is deprecated but still works (migration to direct reader passing planned)
- Debug warning: "Unknown field received" in protobuf decoding (cosmetic, does not affect functionality)

### Memory Management

This project has been thoroughly audited and fixed for memory leaks:
- Zero memory leaks when run with `GeneralPurposeAllocator`
- All storage keys/values are properly freed on shutdown
- Client response buffers are cleaned up correctly
- See `docs/memory-leak-*.md` for detailed documentation of fixes

### Architecture Notes

**Columnar Storage:**
- **Data Model**: Apache Arrow-inspired columnar storage with typed schemas
- **Storage Engine**: ArrayList-backed columns for each type (int64, float64, string, bool)
- **Tables**: RecordBatch structure with schema validation and type checking
- **Table Management**: Thread-safe operations using `std.Thread.RwLock`
  - Read operations (Scan): Shared lock (concurrent)
  - Write operations (CreateTable, AddRecord): Exclusive lock

**Persistence Layer:**
- **Write-Ahead Log (WAL)**:
  - Every write logged before applying to in-memory structures
  - Sequence numbers for ordering
  - CRC32 checksums for integrity verification
  - Format: Magic header + version + sequence + entry type + data + CRC
- **Snapshots**:
  - Periodic snapshots of all tables (configurable thresholds)
  - Default: 10,000 records OR 10MB WAL size
  - Atomic writes (temp file + rename)
  - Custom binary format with length-prefixed data
- **Recovery**:
  - On startup: Load latest snapshot
  - Replay WAL entries from last snapshot
  - Ensures durability and crash recovery

**Data Directory Structure:**
```
data/
├── coleman.wal          # Write-Ahead Log
└── snapshots/
    └── snapshot.dat     # Latest snapshot
```

**Concurrency & Threading:**
- Single-threaded gRPC server with sequential request handling
- Thread-safe table operations via RwLock
- Fine-grained WAL mutex for append operations

**Memory Management:**
- Zero memory leaks (verified with `GeneralPurposeAllocator`)
- Arena allocators for query execution (freed after response)
- Proper cleanup in all error paths
- All storage managed by TableManager with explicit deinit

**Transport:**
- gRPC over HTTP/2 with disabled compression
- Protocol Buffers for message serialization
- Custom routing for columnar operations

### Additional Documentation

- `AGENT.md` - Agent-specific guidelines (libs/ directory constraint)
- `progress.md` - Complete project history, all fixes, and technical learnings
- `docs/memory-leak-*.md` - Detailed memory leak fix documentation
- `docs/grpc-method-routing-fix.md` - gRPC routing implementation details
- `plans/columnar-storage-plan.md` - Columnar storage implementation plan (Phases 1-2 complete)
