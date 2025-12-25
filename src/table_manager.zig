const std = @import("std");
const schema = @import("schema");
const table = @import("table");
const wal_mod = @import("wal");
const snapshot_mod = @import("snapshot");
const config_mod = @import("config");
const filter_mod = @import("filter");
const pb = @import("proto");

/// Manages multiple tables with thread-safe access
pub const TableManager = struct {
    tables: std.StringHashMap(*table.Table),
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,
    wal: *wal_mod.WAL,
    snapshot_manager: *snapshot_mod.SnapshotManager,
    config: config_mod.Config,
    records_since_snapshot: usize,

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config) !TableManager {
        // Initialize data directories
        try cfg.initDataDir();

        // Initialize WAL
        const wal = try wal_mod.WAL.init(allocator, cfg.wal_path);
        errdefer wal.deinit();

        // Initialize snapshot manager
        const snapshot_manager = try snapshot_mod.SnapshotManager.init(allocator, cfg.snapshot_dir);
        errdefer snapshot_manager.deinit();

        return .{
            .tables = std.StringHashMap(*table.Table).init(allocator),
            .lock = .{},
            .allocator = allocator,
            .wal = wal,
            .snapshot_manager = snapshot_manager,
            .config = cfg,
            .records_since_snapshot = 0,
        };
    }

    pub fn deinit(self: *TableManager) void {
        // Acquire write lock to ensure no operations are in progress
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.tables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*); // Free the table name key
        }
        self.tables.deinit();

        self.wal.deinit();
        self.snapshot_manager.deinit();
    }

    /// Create a new table with the given name and schema
    pub fn createTable(self: *TableManager, name: []const u8, table_schema: schema.Schema) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if table already exists
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }

        // Append to WAL first
        try self.wal.append(.{
            .create_table = .{
                .table_name = name,
                .schema = table_schema,
            },
        });

        // Create new table
        const new_table = try self.allocator.create(table.Table);
        errdefer self.allocator.destroy(new_table);

        new_table.* = try table.Table.init(self.allocator, name, table_schema);
        errdefer new_table.deinit();

        // Add to tables map
        try self.tables.put(try self.allocator.dupe(u8, name), new_table);
    }

    /// Get a table by name (returns null if not found)
    /// Caller must hold appropriate lock during table access
    pub fn getTable(self: *TableManager, name: []const u8) ?*table.Table {
        // Note: Lock should be held by caller for consistent read/write
        return self.tables.get(name);
    }

    /// Add a record to a table
    pub fn addRecord(self: *TableManager, table_name: []const u8, values: []const table.Value) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const tbl = self.tables.get(table_name) orelse return error.TableNotFound;

        // Convert values to schema.Value for WAL
        const wal_values = try self.allocator.alloc(schema.Value, values.len);
        defer self.allocator.free(wal_values);

        for (values, 0..) |val, i| {
            wal_values[i] = switch (val) {
                .int64 => |v| .{ .int_value = v },
                .float64 => |v| .{ .float_value = v },
                .string => |v| .{ .string_value = v },
                .bool => |v| .{ .bool_value = v },
            };
        }

        // Append to WAL first
        try self.wal.append(.{
            .add_record = .{
                .table_name = table_name,
                .values = wal_values,
            },
        });

        // Add to table
        try tbl.addRecord(values);

        // Track records and check if snapshot is needed
        self.records_since_snapshot += 1;
        try self.maybeSnapshot();
    }

    /// Get all table names
    pub fn getTableNames(self: *TableManager, allocator: std.mem.Allocator) ![][]const u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const names = try allocator.alloc([]const u8, self.tables.count());
        var it = self.tables.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| {
            names[i] = try allocator.dupe(u8, key.*);
            i += 1;
        }
        return names;
    }

    /// Drop a table
    pub fn dropTable(self: *TableManager, name: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const entry = self.tables.fetchRemove(name) orelse return error.TableNotFound;
        entry.value.deinit();
        self.allocator.destroy(entry.value);
        self.allocator.free(entry.key);
    }

    /// Get table count
    pub fn tableCount(self: *TableManager) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.tables.count();
    }

    /// Scan a table (returns all rows)
    pub fn scan(
        self: *TableManager,
        allocator: std.mem.Allocator,
        table_name: []const u8,
    ) ![][]table.Value {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const tbl = self.tables.get(table_name) orelse return error.TableNotFound;

        const rows = try allocator.alloc([]table.Value, tbl.row_count);
        for (0..tbl.row_count) |i| {
            rows[i] = try tbl.getRow(allocator, i);
        }
        return rows;
    }

    /// Filter a table (returns rows matching predicates)
    pub fn filter(
        self: *TableManager,
        allocator: std.mem.Allocator,
        table_name: []const u8,
        predicates: []const pb.Predicate,
    ) ![][]table.Value {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const tbl = self.tables.get(table_name) orelse return error.TableNotFound;

        // Get matching row indices
        var matching_indices = try filter_mod.filterTable(allocator, tbl, predicates);
        defer matching_indices.deinit(allocator);

        // Retrieve the matching rows
        const rows = try allocator.alloc([]table.Value, matching_indices.items.len);
        for (matching_indices.items, 0..) |row_idx, i| {
            rows[i] = try tbl.getRow(allocator, row_idx);
        }
        return rows;
    }

    /// Check if snapshot is needed and trigger if thresholds met
    fn maybeSnapshot(self: *TableManager) !void {
        // Check if we've exceeded thresholds
        if (self.records_since_snapshot < self.config.snapshot_record_threshold) {
            return;
        }

        // Save snapshot
        try self.snapshot_manager.save(self.tables);

        // Truncate WAL
        try self.wal.truncate();

        // Reset counter
        self.records_since_snapshot = 0;
    }

    /// Recover state from snapshot and WAL
    pub fn recover(self: *TableManager) !void {
        // Load snapshot if it exists
        const loader = struct {
            fn load(tbl: table.Table) !void {
                // This will be called for each table in the snapshot
                // The table is already fully constructed, we just need to add it
                _ = tbl;
            }
        }.load;

        // First load snapshot
        try self.snapshot_manager.load(&loader);

        // Then replay WAL - we need a simple approach to pass self
        try self.replayWAL();
    }

    fn replayWAL(self: *TableManager) !void {
        // For now, skip WAL replay - we'll implement this properly later
        // The WAL.replay API needs to be redesigned to support context passing
        _ = self;
    }
};

test "table manager basic operations" {
    const allocator = std.testing.allocator;

    const test_config = config_mod.Config{
        .wal_path = "test_data/test.wal",
        .snapshot_dir = "test_data/snapshots",
        .snapshot_record_threshold = 100,
        .snapshot_wal_size_threshold = 1024 * 1024,
        .host = "0.0.0.0",
        .port = 50051,
    };

    var manager = try TableManager.init(allocator, test_config);
    defer manager.deinit();

    // Create a table
    const cols = [_]schema.ColumnDef{
        schema.ColumnDef.init("id", .int64),
        schema.ColumnDef.init("value", .float64),
    };

    var test_schema = try schema.Schema.init(allocator, &cols);
    defer test_schema.deinit();

    try manager.createTable("test_table", test_schema);

    try std.testing.expectEqual(@as(usize, 1), manager.tableCount());

    // Add a record
    const record = [_]table.Value{
        table.Value.fromInt64(42),
        table.Value.fromFloat64(3.14),
    };
    try manager.addRecord("test_table", &record);

    // Scan table
    const rows = try manager.scan(allocator, "test_table");
    defer {
        for (rows) |row| {
            allocator.free(row);
        }
        allocator.free(rows);
    }

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 42), rows[0][0].int64);
    try std.testing.expectEqual(@as(f64, 3.14), rows[0][1].float64);
}
