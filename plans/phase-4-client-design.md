# Phase 4: Robust Interactive Client - Design Document

**Status**: Planning
**Goal**: Build a feature-rich, user-friendly client that showcases all Coleman capabilities
**Target Users**: Data analysts, developers, database administrators

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Component Design](#component-design)
4. [Implementation Phases](#implementation-phases)
5. [Technical Decisions](#technical-decisions)
6. [Examples](#examples)
7. [Testing Strategy](#testing-strategy)

---

## Overview

### Motivation

Currently, Coleman has a basic test client (`src/client.zig`) that demonstrates gRPC connectivity but lacks:
- **User interaction**: No REPL or query interface
- **Ergonomics**: Requires recompiling to change queries
- **Features**: No bulk loading, export, query history
- **Discoverability**: Hard to explore schema and data

A robust client will:
- ✅ Make Coleman **accessible** to non-developers
- ✅ Provide **instant feedback** for query development
- ✅ Enable **realistic testing** with large datasets
- ✅ Showcase Coleman's **full capabilities**
- ✅ Serve as **reference implementation** for other clients

### Scope

**In Scope:**
- Interactive command-line interface (CLI)
- Query language (SQL-like or custom DSL)
- Bulk data import/export (CSV, JSON)
- Pretty-printed table output
- Query performance metrics
- Error handling and help system

**Out of Scope (for Phase 4):**
- Graphical user interface (GUI)
- Web-based client
- Multi-user authentication
- Transaction support (not in server yet)
- Client-side query optimization

---

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│                      Coleman Client                         │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │               REPL / Interactive Shell                │ │
│  │  • Command parser                                     │ │
│  │  • Readline integration (history, editing)            │ │
│  │  │  • Tab completion                                  │ │
│  └──────────────────┬────────────────────────────────────┘ │
│                     │                                       │
│                     ▼                                       │
│  ┌───────────────────────────────────────────────────────┐ │
│  │              Query Builder / Executor                 │ │
│  │  • Parse query syntax                                 │ │
│  │  • Build execution plan                               │ │
│  │  • Translate to gRPC calls                            │ │
│  │  • Execute and collect results                        │ │
│  └──────────────────┬────────────────────────────────────┘ │
│                     │                                       │
│                     ▼                                       │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                  gRPC Client                          │ │
│  │  • Connection management                              │ │
│  │  • CreateTable, AddRecord, Scan, Filter, Aggregate   │ │
│  │  • Error handling and retries                         │ │
│  └──────────────────┬────────────────────────────────────┘ │
│                     │                                       │
└─────────────────────┼───────────────────────────────────────┘
                      │
                      │ gRPC over HTTP/2
                      ▼
              ┌───────────────┐
              │ Coleman Server│
              │   (port 50051)│
              └───────────────┘
```

### Component Layers

1. **Presentation Layer**: REPL, output formatting, user interaction
2. **Application Layer**: Query parsing, execution planning
3. **Transport Layer**: gRPC client, connection pooling
4. **Data Layer**: Import/export, caching, result storage

---

## Component Design

### 1. REPL / Interactive Shell

**Responsibility**: Provide interactive command-line interface

**Features:**
- Command prompt with server connection indicator
- Multi-line input support (for long queries)
- Command history (save/load from file)
- Tab completion for commands, tables, columns
- Help system (`\h` or `help <command>`)
- Special commands (meta-commands)

**Implementation Approach:**

**Option A: Simple Loop (MVP)**
```zig
// Simple read-eval-print loop
pub fn runREPL(allocator: std.mem.Allocator, client: *GrpcClient) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    while (true) {
        try stdout.print("coleman> ", .{});

        var buf: [4096]u8 = undefined;
        const line = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse break;

        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;

        executeCommand(allocator, client, line) catch |err| {
            try stdout.print("Error: {}\n", .{err});
        };
    }
}
```

**Option B: Readline Integration (Better UX)**
- Use Zig linenoise binding or readline wrapper
- Provides history, editing, tab completion
- More complex but much better user experience

**Recommendation**: Start with Option A (MVP), upgrade to Option B in iterations.

**Meta-Commands:**
```
\h, \help          - Show help
\l, \list          - List all tables
\d <table>         - Describe table schema
\i <file>          - Execute commands from file
\o <file>          - Output results to file
\t                 - Toggle timing display
\q, \quit, exit    - Exit client
```

---

### 2. Query Language / Parser

**Decision**: SQL-like vs Custom DSL

#### Option A: SQL-Like Syntax (Familiar)

**Advantages:**
- ✅ Familiar to users with SQL experience
- ✅ Industry standard syntax
- ✅ Self-documenting queries

**Disadvantages:**
- ❌ Complex to parse (need full SQL parser)
- ❌ Might imply features we don't support
- ❌ High implementation effort

**Example:**
```sql
CREATE TABLE users (id INT64, name STRING, age INT64);
INSERT INTO users VALUES (1, 'Alice', 30);
SELECT * FROM users WHERE age > 25;
SELECT COUNT(*), AVG(age) FROM users WHERE age > 20;
```

#### Option B: Custom Command Syntax (Simple)

**Advantages:**
- ✅ Easy to parse (simple command structure)
- ✅ Clear about supported features
- ✅ Fast to implement
- ✅ Can evolve to SQL-like later

**Disadvantages:**
- ❌ Learning curve for users
- ❌ Less familiar syntax

**Example:**
```
create table users (id:int64, name:string, age:int64)
insert users (1, 'Alice', 30)
scan users
filter users where age > 25
aggregate users count(id) where age > 20
```

**Recommendation**: **Option B for MVP**, evolve to SQL-like in Phase 5.

#### Command Grammar (EBNF-style)

```
command := create_table | insert | scan | filter | aggregate | meta_command

create_table := "create" "table" table_name "(" column_defs ")"
column_defs  := column_def ("," column_def)*
column_def   := column_name ":" column_type

insert       := "insert" table_name "(" values ")"
values       := value ("," value)*

scan         := "scan" table_name

filter       := "filter" table_name where_clause
where_clause := "where" predicate ("and" predicate)*
predicate    := column_name operator value

aggregate    := "aggregate" table_name agg_func "(" column_name ")" [where_clause]
agg_func     := "count" | "sum" | "avg" | "min" | "max"

meta_command := "\\" meta_cmd
```

#### Parser Implementation

```zig
pub const Command = union(enum) {
    create_table: CreateTableCmd,
    insert: InsertCmd,
    scan: ScanCmd,
    filter: FilterCmd,
    aggregate: AggregateCmd,
    meta: MetaCmd,
};

pub fn parseCommand(input: []const u8) !Command {
    var tokens = std.mem.tokenize(u8, input, " \t\n");
    const first_token = tokens.next() orelse return error.EmptyCommand;

    if (std.mem.eql(u8, first_token, "create")) {
        return Command{ .create_table = try parseCreateTable(&tokens) };
    } else if (std.mem.eql(u8, first_token, "insert")) {
        return Command{ .insert = try parseInsert(&tokens) };
    }
    // ... etc

    return error.UnknownCommand;
}
```

---

### 3. Output Formatting

**Requirement**: Pretty-print query results in readable tables

**ASCII Table Format:**
```
┌────┬───────┬─────┬───────┐
│ id │ name  │ age │ score │
├────┼───────┼─────┼───────┤
│  1 │ Alice │  30 │  95.5 │
│  2 │ Bob   │  25 │  87.3 │
│  3 │ Carol │  35 │  92.1 │
└────┴───────┴─────┴───────┘
3 rows returned (0.023s)
```

**Implementation:**

```zig
pub const TableFormatter = struct {
    pub fn formatResults(
        allocator: std.mem.Allocator,
        schema: []const ColumnDef,
        rows: []const []const Value,
    ) ![]const u8 {
        // 1. Calculate column widths
        var widths = try calculateWidths(allocator, schema, rows);
        defer allocator.free(widths);

        // 2. Print top border
        var output = std.ArrayList(u8).init(allocator);
        try printBorder(&output, widths, .top);

        // 3. Print header row
        try printHeader(&output, schema, widths);
        try printBorder(&output, widths, .middle);

        // 4. Print data rows
        for (rows) |row| {
            try printRow(&output, row, widths);
        }

        // 5. Print bottom border
        try printBorder(&output, widths, .bottom);

        return output.toOwnedSlice();
    }
};
```

**Alternative Formats:**
- CSV: For piping to other tools
- JSON: For programmatic consumption
- Raw: For scripting (tab-separated)

**Format Selection:**
```
\format table    -- ASCII table (default)
\format csv      -- CSV output
\format json     -- JSON output
\format raw      -- Tab-separated
```

---

### 4. Bulk Data Import

**Requirement**: Load large datasets from CSV/JSON files

**CSV Import Design:**

```zig
pub fn importCSV(
    allocator: std.mem.Allocator,
    client: *GrpcClient,
    file_path: []const u8,
    table_name: []const u8,
    options: ImportOptions,
) !ImportResult {
    // 1. Open file
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // 2. Read header (column names) or use provided schema
    const schema = if (options.has_header)
        try parseHeaderRow(allocator, file.reader())
    else
        options.schema;

    // 3. Create table (if doesn't exist)
    if (options.create_table) {
        try client.createTable(table_name, schema);
    }

    // 4. Read and insert rows in batches
    var row_count: usize = 0;
    var batch = std.ArrayList([]Value).init(allocator);
    defer batch.deinit();

    while (try readCSVRow(allocator, file.reader(), schema)) |row| {
        try batch.append(row);

        // Insert in batches of 1000
        if (batch.items.len >= 1000) {
            try insertBatch(client, table_name, batch.items);
            batch.clearRetainingCapacity();
            row_count += batch.items.len;

            // Progress indicator
            if (row_count % 10000 == 0) {
                try std.io.getStdOut().writer().print("\rLoaded {d} rows...", .{row_count});
            }
        }
    }

    // Insert remaining rows
    if (batch.items.len > 0) {
        try insertBatch(client, table_name, batch.items);
        row_count += batch.items.len;
    }

    return ImportResult{
        .rows_imported = row_count,
        .elapsed_ms = timer.read() / 1_000_000,
    };
}
```

**Command Syntax:**
```
load csv users.csv into users
load csv products.csv into products with_header
load json orders.json into orders
```

**CSV Parsing:**
- Use simple comma-split (handle quoted values)
- Type inference based on table schema
- Error recovery: skip bad rows, report errors

**Progress Indicators:**
```
Loading users.csv...
████████████████████ 50000/50000 rows (100%)
Loaded 50000 records in 11.2s (4464 records/sec)
```

---

### 5. Data Export

**Requirement**: Export query results to files

**Export Formats:**
- CSV: `export csv results.csv`
- JSON: `export json results.json`

**Implementation:**

```zig
pub fn exportToCSV(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    schema: []const ColumnDef,
    rows: []const []const Value,
) !void {
    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const writer = file.writer();

    // Write header
    for (schema, 0..) |col, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(col.name);
    }
    try writer.writeByte('\n');

    // Write rows
    for (rows) |row| {
        for (row, 0..) |val, i| {
            if (i > 0) try writer.writeByte(',');
            try writeValue(writer, val);
        }
        try writer.writeByte('\n');
    }
}
```

---

### 6. Client-Side Features

#### Connection Management

```zig
pub const GrpcClient = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    port: u16,
    connected: bool,

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8, port: u16) !*GrpcClient {
        var client = try allocator.create(GrpcClient);
        client.* = .{
            .allocator = allocator,
            .server_addr = try allocator.dupe(u8, addr),
            .port = port,
            .connected = false,
        };

        // Test connection
        try client.ping();
        client.connected = true;

        return client;
    }
};
```

**Commands:**
```
\connect localhost:50051
\disconnect
\status                    -- Show connection status
```

#### Query Timing

Track and display query execution time:

```zig
pub fn executeQuery(client: *GrpcClient, cmd: Command) !QueryResult {
    var timer = try std.time.Timer.start();
    const result = try executeCommand(client, cmd);
    const elapsed_ns = timer.read();

    return QueryResult{
        .data = result,
        .elapsed_ms = elapsed_ns / 1_000_000,
        .rows_affected = result.len,
    };
}
```

**Display:**
```
3 rows returned (0.023s)
```

#### Tab Completion

Complete table names, column names, commands:

```zig
pub fn getCompletions(client: *GrpcClient, partial: []const u8) ![]const []const u8 {
    // Complete table names
    if (isTableContext(partial)) {
        const tables = try client.listTables();
        return filterMatches(tables, partial);
    }

    // Complete commands
    const commands = &[_][]const u8{"create", "insert", "scan", "filter", "aggregate"};
    return filterMatches(commands, partial);
}
```

---

## Implementation Phases

### Phase 4.1: MVP Interactive Client (Week 1-2)

**Goal**: Basic REPL with simple commands

**Deliverables:**
- ✅ Simple REPL loop (no readline yet)
- ✅ Parse basic commands: create, insert, scan
- ✅ Execute gRPC calls
- ✅ Basic table output (no fancy formatting)
- ✅ Error handling

**Testing:**
- Manual testing with basic queries
- Create table, insert rows, scan results

---

### Phase 4.2: Query Features (Week 3)

**Goal**: Add filter and aggregate support

**Deliverables:**
- ✅ Parse filter commands with WHERE clauses
- ✅ Parse aggregate commands
- ✅ Pretty table formatting (ASCII borders)
- ✅ Meta-commands (\l, \d, \h)

**Testing:**
- Filter queries with multiple predicates
- Aggregate queries (COUNT, SUM)
- Schema introspection

---

### Phase 4.3: Data Import/Export (Week 4)

**Goal**: Bulk data loading

**Deliverables:**
- ✅ CSV import with progress indicators
- ✅ CSV export
- ✅ JSON import/export
- ✅ Batch insert optimization

**Testing:**
- Load 100K row CSV file
- Measure import throughput
- Export and re-import data

---

### Phase 4.4: Polish & Advanced Features (Week 5)

**Goal**: Production-ready client

**Deliverables:**
- ✅ Readline integration (history, editing)
- ✅ Tab completion
- ✅ Query timing display
- ✅ Multiple output formats
- ✅ Script file execution (`\i script.sql`)

**Testing:**
- User experience testing
- Integration tests with real workflows
- Performance testing

---

## Technical Decisions

### Language: Zig (Same as Server)

**Advantages:**
- ✅ Consistent with server implementation
- ✅ Access to existing protobuf definitions
- ✅ Type safety and memory safety
- ✅ Single-binary distribution

**Alternative**: Could build client in Python/Go/JavaScript for broader appeal, but Zig keeps it simple for Phase 4.

---

### Query Syntax: Custom DSL → SQL-like Evolution

**Phase 4**: Simple command syntax
**Phase 5**: Evolve to SQL-like syntax

**Rationale**: Ship faster, iterate based on user feedback

---

### Output: ASCII Tables (Default)

**Rationale**: Human-readable, works in any terminal

**Future**: Add JSON/CSV for programmatic use

---

## Examples

### Example Session

```
$ ./coleman-client
Connected to Coleman server at localhost:50051

coleman> \h
Available commands:
  create table <name> (<cols>)  - Create a new table
  insert <table> (<values>)     - Insert a row
  scan <table>                  - Scan all rows
  filter <table> where <pred>   - Filter rows
  aggregate <table> <func>(col) - Aggregate values

Meta-commands:
  \l            - List tables
  \d <table>    - Describe table
  \q            - Quit

coleman> create table products (id:int64, name:string, price:float64, category:int64)
Table 'products' created successfully.

coleman> \l
Tables:
  products

coleman> \d products
Table: products
┌──────────┬─────────┐
│ Column   │ Type    │
├──────────┼─────────┤
│ id       │ INT64   │
│ name     │ STRING  │
│ price    │ FLOAT64 │
│ category │ INT64   │
└──────────┴─────────┘

coleman> insert products (1, 'Widget', 9.99, 1)
1 record inserted.

coleman> insert products (2, 'Gadget', 19.99, 1)
1 record inserted.

coleman> insert products (3, 'Doohickey', 5.99, 2)
1 record inserted.

coleman> scan products
┌────┬───────────┬───────┬──────────┐
│ id │ name      │ price │ category │
├────┼───────────┼───────┼──────────┤
│  1 │ Widget    │  9.99 │        1 │
│  2 │ Gadget    │ 19.99 │        1 │
│  3 │ Doohickey │  5.99 │        2 │
└────┴───────────┴───────┴──────────┘
3 rows returned (0.012s)

coleman> filter products where price > 10.0
┌────┬────────┬───────┬──────────┐
│ id │ name   │ price │ category │
├────┼────────┼───────┼──────────┤
│  2 │ Gadget │ 19.99 │        1 │
└────┴────────┴───────┴──────────┘
1 row returned (0.008s)

coleman> aggregate products count(id)
┌───────┐
│ count │
├───────┤
│     3 │
└───────┘
(0.005s)

coleman> aggregate products sum(price) where category = 1
┌───────┐
│ sum   │
├───────┤
│ 29.98 │
└───────┘
(0.007s)

coleman> load csv products.csv into products with_header
Loading products.csv...
████████████████████ 10000/10000 rows (100%)
Loaded 10000 records in 2.3s (4347 records/sec)

coleman> aggregate products count(id)
┌───────┐
│ count │
├───────┤
│ 10003 │
└───────┘
(0.011s)

coleman> \q
Goodbye!
```

---

## Testing Strategy

### Unit Tests

- ✅ Command parser tests
- ✅ CSV/JSON parser tests
- ✅ Table formatter tests
- ✅ Value conversion tests

### Integration Tests

- ✅ End-to-end query workflows
- ✅ Import → Query → Export round-trip
- ✅ Error handling (bad queries, connection failures)

### Performance Tests

- ✅ Import 1M rows from CSV
- ✅ Query latency under load
- ✅ Memory usage with large result sets

### User Acceptance Tests

- ✅ Real user workflows (create, populate, query)
- ✅ Usability testing (can users accomplish tasks?)

---

## Success Criteria

Phase 4 is complete when:

- ✅ Interactive REPL with command history
- ✅ All query types supported (create, insert, scan, filter, aggregate)
- ✅ CSV/JSON import with >1000 records/sec
- ✅ Pretty table output
- ✅ Meta-commands for introspection
- ✅ Zero crashes on valid input
- ✅ Helpful error messages on invalid input
- ✅ 100+ integration tests passing
- ✅ Documentation with examples

---

## Future Enhancements (Phase 5+)

- **SQL Parser**: Full SQL syntax support
- **Query Editor**: Multi-line editing, syntax highlighting
- **Auto-completion**: Smart completion based on schema
- **Query History**: Persistent history file
- **Batch Mode**: Non-interactive script execution
- **TUI**: Terminal UI with panes for schema, query, results
- **Web Client**: Browser-based interface
