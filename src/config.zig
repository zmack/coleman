const std = @import("std");

pub const Config = struct {
    /// Path to the Write-Ahead Log file
    wal_path: []const u8 = "data/coleman.wal",

    /// Directory for snapshots
    snapshot_dir: []const u8 = "data/snapshots",

    /// Trigger snapshot after this many records written
    snapshot_record_threshold: usize = 10000,

    /// Trigger snapshot when WAL exceeds this size (bytes)
    snapshot_wal_size_threshold: usize = 10 * 1024 * 1024, // 10MB

    /// Server host
    host: []const u8 = "0.0.0.0",

    /// Server port
    port: u16 = 50051,

    pub fn default() Config {
        return .{};
    }

    /// Initialize data directory structure
    pub fn initDataDir(self: Config) !void {
        // Create data directory
        std.fs.cwd().makeDir("data") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create snapshot directory
        std.fs.cwd().makeDir(self.snapshot_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
};
