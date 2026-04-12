const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Config backup manager - creates versioned backups before changes
pub const ConfigBackup = struct {
    allocator: Allocator,
    backup_dir: []const u8,
    max_backups: usize,

    pub fn init(allocator: Allocator, backup_dir: []const u8, max_backups: usize) ConfigBackup {
        return ConfigBackup{
            .allocator = allocator,
            .backup_dir = backup_dir,
            .max_backups = max_backups,
        };
    }

    /// Create a backup of a config file
    pub fn createBackup(self: *ConfigBackup, config_path: []const u8) ![]const u8 {
        try std.fs.cwd().makePath(self.backup_dir);

        const timestamp = std.time.timestamp();
        const basename = std.fs.path.basename(config_path);

        const backup_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.{}",
            .{ self.backup_dir, basename, timestamp },
        );
        errdefer self.allocator.free(backup_name);

        // Copy file
        const src = try std.fs.cwd().openFile(config_path, .{});
        defer src.close();

        const file_size = try src.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try src.readAll(buffer);

        const dst = try std.fs.cwd().createFile(backup_name, .{ .truncate = true });
        defer dst.close();

        try dst.writeAll(buffer);

        // Trim old backups
        try self.trimOldBackups(basename);

        return backup_name;
    }

    /// Restore from a backup
    pub fn restore(self: *ConfigBackup, config_path: []const u8, backup_name: []const u8) !void {
        const src = try std.fs.cwd().openFile(backup_name, .{});
        defer src.close();

        const file_size = try src.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try src.readAll(buffer);

        const dst = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
        defer dst.close();

        try dst.writeAll(buffer);
    }

    /// List available backups for a config file
    pub fn listBackups(self: *ConfigBackup, allocator: Allocator, config_basename: []const u8) ![][]const u8 {
        var backups = array_list_compat.ArrayList([]const u8).init(allocator);
        errdefer {
            for (backups.items) |b| allocator.free(b);
            backups.deinit();
        }

        var dir = std.fs.cwd().openDir(self.backup_dir, .{ .iterate = true }) catch return try backups.toOwnedSlice();
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, config_basename)) {
                try backups.append(try allocator.dupe(u8, entry.name));
            }
        }

        return backups.toOwnedSlice();
    }

    /// Trim old backups beyond max_backups
    fn trimOldBackups(self: *ConfigBackup, basename: []const u8) !void {
        var dir = std.fs.cwd().openDir(self.backup_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect backup files
        var backup_names = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer backup_names.deinit();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, basename)) {
                try backup_names.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        // Delete oldest if over max
        while (backup_names.items.len > self.max_backups) {
            const old = backup_names.orderedRemove(0);
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.backup_dir, old });
            defer self.allocator.free(full_path);
            std.fs.cwd().deleteFile(full_path) catch {};
            self.allocator.free(old);
        }

        for (backup_names.items) |name| {
            self.allocator.free(name);
        }
    }
};

/// Config migration system for version upgrades
pub const ConfigMigrator = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ConfigMigrator {
        return ConfigMigrator{ .allocator = allocator };
    }

    /// Get config version from content
    pub fn getConfigVersion(_: *ConfigMigrator, content: []const u8) ?u32 {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
                if (std.mem.eql(u8, key, "config_version")) {
                    return std.fmt.parseInt(u32, value, 10) catch return null;
                }
            }
        }
        return null;
    }

    /// Migrate config from old version to current
    pub fn migrate(self: *ConfigMigrator, content: []const u8, from_version: u32) ![]u8 {
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const writer = output.writer();

        var current_version = from_version;

        // Apply migrations sequentially
        var content_to_migrate = content;

        while (current_version < CURRENT_CONFIG_VERSION) {
            const migrated = try self.applyMigration(content_to_migrate, current_version);
            defer if (current_version != from_version) self.allocator.free(@constCast(content_to_migrate));

            current_version += 1;
            content_to_migrate = migrated;
        }

        try writer.writeAll(content_to_migrate);

        // Ensure config_version field is updated
        if (self.getConfigVersion(output.items)) |v| {
            if (v < CURRENT_CONFIG_VERSION) {
                // Replace version line
                var final_output = array_list_compat.ArrayList(u8).init(self.allocator);
                defer output.deinit();
                const final_writer = final_output.writer();

                var line_iter = std.mem.splitScalar(u8, output.items, '\n');
                while (line_iter.next()) |line| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "config_version=")) {
                        try final_writer.print("config_version = {}\n", .{CURRENT_CONFIG_VERSION});
                    } else {
                        try final_writer.print("{s}\n", .{line});
                    }
                }
                return final_output.toOwnedSlice();
            }
        } else {
            // Add version line if missing
            try writer.print("\nconfig_version = {}\n", .{CURRENT_CONFIG_VERSION});
        }

        return output.toOwnedSlice();
    }

    /// Apply a single migration step
    fn applyMigration(self: *ConfigMigrator, content: []const u8, version: u32) ![]const u8 {
        switch (version) {
            0 => return self.migrateV0toV1(content),
            1 => return self.migrateV1toV2(content),
            else => {
                // No migration needed, return copy
                return try self.allocator.dupe(u8, content);
            },
        }
    }

    /// V0 -> V1: Add config_version field
    fn migrateV0toV1(self: *ConfigMigrator, content: []const u8) ![]const u8 {
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll(content);
        try writer.writeAll("\n# Config version (auto-managed)\nconfig_version = 1\n");

        return output.toOwnedSlice();
    }

    /// V1 -> V2: Add [quantization] section
    fn migrateV1toV2(self: *ConfigMigrator, content: []const u8) ![]const u8 {
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll(content);
        try writer.writeAll(
            \\
            \\# KV cache compression (TurboQuant)
            \\[quantization]
            \\enabled = false
            \\key_bits = 3
            \\value_bits = 2
            \\head_dim = 128
            \\
        );

        return output.toOwnedSlice();
    }
};

/// Current config version
pub const CURRENT_CONFIG_VERSION: u32 = 2;

// -- Tests --

test "ConfigBackup - create and restore" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/crushcode_test_backups";
    const config_path = "/tmp/crushcode_test_config.toml";

    std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create test config
    {
        const f = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("default_provider = \"test\"\n");
    }

    var backup = ConfigBackup.init(allocator, tmp_dir, 5);

    // Create backup
    const backup_path = try backup.createBackup(config_path);
    defer allocator.free(backup_path);

    // Modify original
    {
        const f = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("default_provider = \"modified\"\n");
    }

    // Restore
    try backup.restore(config_path, backup_path);

    // Verify restored content
    const f = try std.fs.cwd().openFile(config_path, .{});
    defer f.close();
    const buf = try allocator.alloc(u8, 100);
    defer allocator.free(buf);
    const n = try f.readAll(buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "default_provider = \"test\""));

    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().deleteFile(config_path) catch {};
}

test "ConfigMigrator - version detection" {
    const allocator = std.testing.allocator;
    var migrator = ConfigMigrator.init(allocator);

    const content_v1 = "config_version = 1\ndefault_provider = \"test\"\n";
    const v = migrator.getConfigVersion(content_v1);
    try std.testing.expect(v != null);
    try std.testing.expect(v.? == 1);

    const content_none = "default_provider = \"test\"\n";
    try std.testing.expect(migrator.getConfigVersion(content_none) == null);
}

test "ConfigMigrator - migrate V0 to current" {
    const allocator = std.testing.allocator;
    var migrator = ConfigMigrator.init(allocator);

    const content_v0 = "default_provider = \"test\"\ndefault_model = \"gpt-4\"\n";
    const migrated = try migrator.migrate(content_v0, 0);
    defer allocator.free(migrated);

    // Should have config_version and [quantization]
    try std.testing.expect(std.mem.indexOf(u8, migrated, "config_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, migrated, "[quantization]") != null);
}
