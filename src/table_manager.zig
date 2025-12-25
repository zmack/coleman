const std = @import("std");
const schema = @import("schema");
const table = @import("table");

/// Manages multiple tables with thread-safe access
pub const TableManager = struct {
    tables: std.StringHashMap(*table.Table),
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TableManager {
        return .{
            .tables = std.StringHashMap(*table.Table).init(allocator),
            .lock = .{},
            .allocator = allocator,
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
    }

    /// Create a new table with the given name and schema
    pub fn createTable(self: *TableManager, name: []const u8, table_schema: schema.Schema) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if table already exists
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }

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
        try tbl.addRecord(values);
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
};

test "table manager basic operations" {
    const allocator = std.testing.allocator;

    var manager = TableManager.init(allocator);
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
