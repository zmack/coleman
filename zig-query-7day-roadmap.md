# 7-Day Zig Columnar Query Engine - Project Roadmap

**Goal:** Build a mini-DuckDB for JSON logs while learning Zig and jujutsu (jj)

**Philosophy:** AI-optimized structure, manual learning checkpoints, explicit over implicit

---

## Day 0: Setup (30 minutes)

### Install Tools
```bash
# Zig
brew install zig  # or download from ziglang.org

# jujutsu
cargo install jj-cli  # or brew install jj

# Verify
zig version  # Should be 0.11.0 or later
jj --version
```

### Initialize Project
```bash
mkdir zig-query && cd zig-query
jj init --git
zig init-exe

# Initial structure
jj new -m "Initial project structure"
```

### Manual Learning Exercise (DO NOT SKIP)
**Write a basic allocator example by hand** - 30 mins max
```zig
// scratch.zig - your learning playground
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();
    
    try list.append(42);
    std.debug.print("Value: {}\n", .{list.items[0]});
}
```

Forces you to grok: `Allocator`, `ArrayList`, `defer`, `try`, `deinit()`

---

## Day 1: Foundation & Single Column

### Goal
Parse JSON lines, extract one field into a typed column array

### Deliverable
Can read `{"timestamp": "2024-01-01T12:00:00Z", "level": "INFO"}` and extract all timestamps into a `[]i64` array

### Files to Create
- `src/column.zig` - Core Column interface
- `src/timestamp_column.zig` - First implementation
- `src/main.zig` - Basic CLI
- `tests/column_test.zig`

### Column Interface (Define First)
```zig
// src/column.zig
pub const Column = struct {
    data: []u8, // Type-erased storage
    len: usize,
    vtable: *const VTable,
    
    pub const VTable = struct {
        append: *const fn(*Column, []const u8) !void,
        get: *const fn(*Column, usize) []const u8,
        deinit: *const fn(*Column) void,
    };
};
```

### AI Coding Strategy
1. Define the interface manually (above)
2. Write a failing test
3. Prompt AI: "Implement TimestampColumn that parses ISO8601 strings to Unix timestamps, stores as []i64, implements the Column interface"
4. **READ THE OUTPUT** - Don't just run it
5. If you see something unfamiliar (e.g., `@intCast`), stop and understand it

### Manual Checkpoint: Implement StringColumn Yourself
Pick ONE column type and implement completely manually:
- No AI allowed
- Just you, docs, and compiler errors
- This is your baseline understanding

### jj Workflow
```bash
jj new -m "Day 1: Column interface"
# Define interface
jj new -m "Day 1: TimestampColumn implementation"
# Let AI help
jj new -m "Day 1: StringColumn (manual)"
# You implement

# Review your day
jj log --limit 5
```

### Learning Focus
- **Allocators** - Where does memory come from?
- **Error unions** - What is `!T`?
- **defer** - Cleanup patterns

### End of Day Review
Write in comments:
```zig
// Day 1 learnings:
// - Zig slices are [ptr, len] pairs
// - Every allocation needs an allocator
// - try unwraps error unions
// - Still fuzzy on: [list what you don't get]
```

---

## Day 2: Multi-Column Schema

### Goal
Extract 3-4 fields simultaneously (timestamp, level, message, user_id)

### Deliverable
Schema definition + parallel column building from real logs

### Files to Create
- `src/schema.zig` - Schema definition
- `src/string_column.zig` - If not done Day 1
- `src/int_column.zig`
- `src/loader.zig` - JSON line reader

### Schema Structure
```zig
pub const Schema = struct {
    columns: []ColumnDef,
    allocator: Allocator,
    
    pub const ColumnDef = struct {
        name: []const u8,
        column_type: ColumnType,
    };
    
    pub const ColumnType = enum {
        timestamp,
        string,
        integer,
    };
};
```

### AI Coding Pattern
Each column type is isolated. Prompt:
> "Implement Int64Column following the same pattern as TimestampColumn.
> Should parse JSON numbers, store as []i64, handle overflow errors."

### Test With Real Data
Use your actual Rails logs or generate sample:
```json
{"timestamp":"2024-12-20T10:00:00Z","level":"INFO","message":"Request started","user_id":123}
{"timestamp":"2024-12-20T10:00:01Z","level":"ERROR","message":"Database timeout","user_id":456}
```

### Manual Checkpoint: Error Handling
Write error handling three different ways:
1. Using `try`
2. Using `catch`
3. Using `errdefer`

Understand when each is appropriate.

### jj Workflow
```bash
jj new -m "Day 2: Schema definition"
# Work
jj new -m "Day 2: Int column"
# Work
jj new -m "Day 2: Loader with real data"

# Need to fix Day 1's interface?
jj edit <day-1-change-id>
# Fix it
jj new  # Back to current work
```

### Learning Focus
- **Comptime** - Can you make column creation use comptime?
- **Optionals vs Errors** - When `?T` vs `!T`?
- **Slices vs Arrays** - What's the difference?

---

## Day 3: Basic Query Engine

### Goal
Simple WHERE clauses: `level = "ERROR"`, `timestamp > X`

### Deliverable
Filter bitmap generation per column

### Files to Create
- `src/expr.zig` - Expression AST
- `src/filter.zig` - Bitmap operations
- `src/query.zig` - Query executor

### Expression AST
```zig
// src/expr.zig
pub const Expr = union(enum) {
    eq: struct { column: []const u8, value: []const u8 },
    gt: struct { column: []const u8, value: i64 },
    lt: struct { column: []const u8, value: i64 },
    and_: struct { left: *Expr, right: *Expr },
    or_: struct { left: *Expr, right: *Expr },
};
```

### AI Coding Strategy
1. Define AST nodes (above) manually
2. AI implements evaluators: "Implement evaluate() that returns a bitmap of matching rows"
3. **You write bitmap operations manually** (and, or, not)

### Manual Checkpoint: Bitmap Logic
DO NOT let AI write this. Implement yourself:
```zig
// src/filter.zig
pub fn and(a: []const u8, b: []const u8) ![]u8 {
    // Your implementation
}

pub fn or(a: []const u8, b: []const u8) ![]u8 {
    // Your implementation
}
```

This teaches Zig's bitwise ops and slice patterns.

### jj Workflow
```bash
jj new -m "Day 3: Expression AST"
jj new -m "Day 3: Bitmap ops (manual)"
# You implement
jj new -m "Day 3: Query evaluator"
# AI helps

# Intentionally create a conflict to practice
jj new -m "Day 3: Alternative bitmap approach" -r <base>
# Merge them later
jj rebase -d <other-change>
# Resolve conflict in editor
```

### Learning Focus
- **Tagged unions** - How does `union(enum)` work?
- **Pointers** - When `*T` vs `[]T`?
- **Comptime dispatch** - Can you dispatch on Expr type at comptime?

---

## Day 4: Aggregations

### Goal
COUNT, basic GROUP BY

### Deliverable
`SELECT level, COUNT(*) GROUP BY level`

### Files to Create
- `src/groupby.zig` - Hash table for grouping
- `src/agg.zig` - Aggregation functions

### Hash Table Structure
```zig
pub fn GroupTable(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        map: std.HashMap(K, V, ...),
        allocator: Allocator,
        
        pub fn init(allocator: Allocator) Self {
            // Implementation
        }
    };
}
```

### AI Coding Strategy
AI implements hash table: "Create a generic hash table using std.HashMap for group keys"

### Manual Checkpoint: Generic Types with Comptime
Take the hash table and make it truly generic:
- Works for any key type
- Works for any value type
- Comptime validates types

This is Zig's superpower - understand it deeply.

### Learning Focus
- **Comptime generics** - How to write generic data structures
- **HashMap usage** - Zig's standard library patterns
- **Type functions** - Functions that return types

---

## Day 5: Memory Pool & Performance

### Goal
Arena allocator per query, benchmark 100MB of logs in <1s

### Deliverable
Proper memory management + performance baseline

### Files to Add
- `src/arena.zig` - Arena allocator wrapper
- `bench/benchmark.zig` - Performance tests

### Manual Checkpoint: Add Arena Allocator Yourself
DO NOT let AI do this. Critical Zig knowledge:
```zig
pub const QueryArena = struct {
    arena: std.heap.ArenaAllocator,
    
    pub fn init(backing_allocator: Allocator) QueryArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }
    
    pub fn allocator(self: *QueryArena) Allocator {
        return self.arena.allocator();
    }
    
    pub fn deinit(self: *QueryArena) void {
        self.arena.deinit();
    }
};
```

Thread this through your query execution.

### Benchmarking
Generate 100MB test file:
```bash
# Generate sample logs
python3 -c "
import json
import random
for i in range(1_000_000):
    print(json.dumps({
        'timestamp': f'2024-12-20T{i%24:02d}:00:00Z',
        'level': random.choice(['INFO', 'WARN', 'ERROR']),
        'message': f'Log message {i}',
        'user_id': random.randint(1, 1000)
    }))
" > test_logs.jsonl
```

Measure:
```zig
const start = std.time.nanoTimestamp();
// Run query
const end = std.time.nanoTimestamp();
std.debug.print("Query took: {}ms\n", .{(end - start) / 1_000_000});
```

### jj Workflow
```bash
jj new -m "Day 5: Arena allocator"
# Your manual implementation
jj new -m "Day 5: Benchmarking framework"
jj new -m "Day 5: Performance optimization"

# Use jj op log to track performance changes
jj op log
```

### Learning Focus
- **Allocator strategies** - Arena vs GPA vs FixedBuffer
- **defer vs errdefer** - Cleanup in success vs error paths
- **Performance profiling** - Where does time go?

---

## Day 6: Compression (Optional but Fun)

### Goal
RLE compression for low-cardinality columns

### Deliverable
3-5x compression on level/status columns

### Files to Add
- `src/compression/rle.zig`
- `src/compressed_column.zig`

### RLE Pattern
```zig
pub const RLEColumn = struct {
    runs: []Run,
    
    const Run = struct {
        value: []const u8,
        count: usize,
    };
};
```

### AI Coding Strategy
"Implement RLE compression for StringColumn when cardinality < 100"

But YOU decide:
- When to compress
- How to detect low cardinality
- Space/time tradeoffs

### Alternative: SIMD
If compression doesn't interest you, try manual SIMD for bitmap operations:
```zig
const vector_size = 32;
const Vector = @Vector(vector_size, u8);
```

### Learning Focus
- **Packed structs** - Memory layout control
- **@Vector** - SIMD in Zig
- **Alignment** - @alignOf, @alignCast

---

## Day 7: CLI & Polish

### Goal
Usable command-line tool

### Deliverable
```bash
zig-query --file app.log "SELECT timestamp, message WHERE level = 'ERROR'"
```

### Files to Add
- `src/cli.zig` - Argument parsing
- `src/parser.zig` - Simple SQL parser (or JSON query format)
- `README.md` - Documentation

### CLI Structure
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const allocator = gpa.allocator();
    
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    
    // Parse args, run query, output results
}
```

### Polish Checklist
- [ ] Error messages are helpful
- [ ] --help works
- [ ] Results are formatted nicely
- [ ] README has examples
- [ ] Tests pass

### Manual Checkpoint: Add New Column Type
Without AI, add IP address column type. If you can do this solo, you learned Zig.

### Learning Focus
- **CLI patterns** - Zig standard library usage
- **Output formatting** - std.fmt
- **Documentation** - Doc comments (`///`)

---

## AI Coding Strategy (Apply Daily)

### Prompt Structure That Works
```
I have [interface/type definition]
[paste code]

Implement [specific thing] that:
- [requirement 1]
- [requirement 2]
- Uses the provided allocator
- Returns error.[ErrorType] on failure

Include tests for: [test cases]
```

### What Makes This AI-Friendly
1. **Clear module boundaries** - One file ≈ one AI context
2. **Explicit contracts** - Zig's type system helps
3. **Incremental complexity** - Each day builds on previous
4. **Testable chunks** - AI can verify its work
5. **Your domain knowledge** - You know what queries matter

### HARD RULES: Read Every Line
- **Don't skim** - Actually read AI output
- **Stop at unknowns** - Look up anything unfamiliar
- **Rewrite sections** - Make it yours
- **Delete and re-prompt** - "Explain how [X] works first"

### Instead of: "Implement X"
**Do:** "Show me how Zig's [feature] works, then I'll implement X"

### After AI Generates Code
Ask yourself:
- "How would I make this generic with comptime?"
- "What happens if this allocation fails?"
- "Can I remove an allocation here?"

---

## Learning Strategy (DON'T Become a Compiler Operator)

### Daily Manual Checkpoints

| Day | What to Do Yourself (No AI) | Why |
|-----|----------------------------|-----|
| 1 | Basic allocator example | Grok Allocator, defer, try |
| 2 | One complete column type | Baseline understanding |
| 3 | Bitmap intersection logic | Bitwise ops, slice patterns |
| 4 | Generic hash table | Comptime generics |
| 5 | Arena allocator integration | Critical Zig knowledge |
| 6 | Decide compression strategy | Design thinking |
| 7 | Add new column type solo | Validation of learning |

### Deliberate Friction Points
Every day, pick ONE thing to struggle with manually:
- **Day 1:** Allocators
- **Day 2:** Comptime
- **Day 3:** Error unions
- **Day 4:** Optionals vs errors
- **Day 5:** Testing patterns
- **Day 6:** SIMD or packed structs
- **Day 7:** C interop

### The "Explain It Back" Test
After each module, close the file and explain to yourself:
- "How does allocation work in this module?"
- "What can fail and how do we handle it?"
- "Where's the performance critical path?"

**If you can't answer → you didn't learn it → go back**

### scratch.zig - Your Learning Lab
When AI uses a Zig feature you don't understand:
1. Copy pattern to scratch.zig
2. Modify it in weird ways
3. See what breaks
4. Read compiler errors carefully

### End of Day Review
Write a comment block:
```zig
// Day X learnings:
// - [concept 1]
// - [concept 2]
// - Still fuzzy on: [concepts to revisit]
```

### The Nuclear Option
If you feel like you're just running AI code:
1. **Delete everything**
2. **Rebuild one module from memory**
3. **Check against AI version**

Painful but effective.

---

## jujutsu (jj) Integration

### Mental Model Shift from Git
- **No staging area** - Working copy IS a commit
- **Changes are first-class** - Edit changes, not commits
- **Auto-commit everything** - jj tracks all changes automatically
- **Conflicts are normal** - They live in working copy until resolved

### Daily jj Workflow

**Morning:**
```bash
jj log --limit 5  # See where you are
```

**Starting feature:**
```bash
jj new -m "Add: <feature name>"
```

**Need to fix something 2 changes back:**
```bash
jj edit <change-id>  # Move working copy to that change
# Fix it
jj new  # Return to tip
```

**End of day:**
```bash
jj log --template 'builtin_log_detailed'  # Review work
jj bookmark set progress  # Optional: mark progress
```

### jj Learning Goals by Day

| Day | New jj Operation | Command |
|-----|------------------|---------|
| 1 | Basic flow | `jj new`, `jj diff`, `jj log` |
| 2 | Edit history | `jj edit`, `jj rebase` |
| 3 | Squash changes | `jj squash` |
| 4 | Split changes | `jj split` |
| 5 | Time travel | `jj op log`, `jj op undo` |
| 6 | Parallelize | `jj new -r <base>` |
| 7 | Cleanup | `jj abandon` |

### Essential jj Commands

```bash
# Core workflow (90% of usage)
jj log                    # See change history
jj new -m "message"       # Create new change
jj diff                   # See changes in current
jj edit <change-id>       # Move to different change

# History manipulation
jj squash -r <change>     # Combine changes
jj rebase -r <change> -d <dest>  # Move changes
jj split                  # Split current change

# Safety net
jj op log                 # See all operations
jj op undo                # Undo last operation
jj op restore <op-id>     # Go back to any state

# Cleanup
jj abandon                # Delete current change
```

### Handling Conflicts
Conflicts appear in your working copy as:
```
<<<<<<< Conflict 1 of 1
%%%%%%% Changes from base to side #1
-old code
+your code
+++++++ Contents of side #2
+their code
>>>>>>>
```

Resolve in editor, then just `jj diff` - no special commands needed.

### Git Interop
```bash
# Push to GitHub
jj git push --branch main

# Pull updates
jj git fetch
jj rebase -d <remote-bookmark>
```

### jj Practice Exercise (Do This First)
```bash
mkdir jj-practice && cd jj-practice
jj init --git

echo "hello" > file.txt
jj new -m "First change"

echo "world" >> file.txt  
jj new -m "Second change"

echo "!" >> file.txt
jj new -m "Third change"

jj log  # See your stack

# Now experiment:
# 1. Edit the first change
# 2. Squash second into first
# 3. Undo everything with jj op undo
# 4. Create a conflict (parallel changes)
# 5. Resolve it
```

---

## Daily Integration Pattern

### Each Morning
```bash
# jj: Check status
jj log --limit 5

# Zig: Run tests
zig build test

# Review yesterday's learnings
cat notes.md
```

### During Work
```bash
# Define interface manually
# Write failing test
# Let AI implement
# READ the output
# Run and verify
# jj new for next piece
```

### Each Evening
```bash
# Add learnings to notes
echo "Day X: [learnings]" >> notes.md

# Review jj history
jj log --template 'builtin_log_detailed'

# Run full test suite
zig build test

# Bookmark progress
jj bookmark set day-X
```

---

## Success Metrics

### By Day 7, Can You:
- [ ] Add a new column type without AI?
- [ ] Explain how allocators work in your code?
- [ ] Use jj to reorganize last 3 days of work?
- [ ] Debug a segfault using zig's error messages?
- [ ] Write a comptime function?
- [ ] Query 100MB of logs in <1 second?

If yes → **You learned Zig**  
If no → **You built a project but outsourced learning**

---

## Resources (Read AFTER Struggling)

### Zig
- https://ziglang.org/documentation/master/ - Official docs
- https://ziglearn.org/ - Tutorial
- https://zig.guide/ - Practical guide
- `zig std` - Standard library source (best teacher)

### jj
- `jj help <command>` - Built-in docs
- https://martinvonz.github.io/jj/latest/tutorial/
- Chris Krycho's blog - Philosophy and workflows

### When Stuck
1. Read compiler errors carefully (Zig's are pedagogical)
2. Check `zig std` source code
3. Ask AI to explain concepts, not fix code
4. Use scratch.zig to isolate the problem

---

## The Real Goal

**Not to build a columnar query engine.**

**To internalize:**
- Zig's explicit allocation patterns
- Comptime's power and limitations
- Error handling as values, not exceptions
- jj's change-based workflow
- How to use AI without outsourcing thinking

By Day 7, you should feel comfortable:
- Reading Zig code in the wild
- Contributing to Zig projects
- Using jj for real work
- Knowing when to let AI help vs. when to struggle

**The project is the excuse. Learning is the goal.**

---

## Quick Reference

### Zig Cheat Sheet
```zig
// Allocator patterns
const allocator = std.heap.page_allocator;
const slice = try allocator.alloc(T, n);
defer allocator.free(slice);

// Error handling
try foo();              // Propagate error
foo() catch |err| {};   // Handle error
defer cleanup();        // Always runs
errdefer cleanup();     // Only on error

// Comptime
fn Generic(comptime T: type) type {
    return struct {
        value: T,
    };
}

// Testing
test "description" {
    try std.testing.expect(true);
}
```

### jj Cheat Sheet
```bash
# Daily workflow
jj new -m "message"     # Start new work
jj diff                 # See changes
jj log                  # View history

# Editing history
jj edit <id>            # Move to change
jj squash               # Combine with parent
jj rebase -d <dest>     # Move change

# Safety
jj op undo              # Undo anything
jj op log               # See all operations
```

---

**Now go forth and build. And actually learn while you're at it.**
