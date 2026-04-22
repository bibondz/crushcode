/// Hook Config — file-based hook configuration loading.
///
/// Loads hook definitions from TOML config files:
///   - ~/.config/crushcode/hooks.toml (user-level)
///   - crushcode.hooks.toml (project-level)
///
/// Config schema:
///   [[hooks]]
///   type = "PreToolUse"
///   command = "shell-command-string"
///   enabled = true
///   timeout_ms = 30000
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const env = @import("env");
const hooks = @import("hooks");

const Allocator = std.mem.Allocator;

/// File-level configuration matching the TOML schema.
pub const HookFileConfig = struct {
    allocator: Allocator,
    hook_configs: []HookConfigEntry,

    pub const HookConfigEntry = struct {
        hook_type: hooks.HookType,
        command: []const u8,
        enabled: bool,
        timeout_ms: u64,

        pub fn deinit(self: *const HookConfigEntry, allocator: Allocator) void {
            allocator.free(self.command);
        }
    };

    pub fn init(allocator: Allocator) HookFileConfig {
        return HookFileConfig{
            .allocator = allocator,
            .hook_configs = &.{},
        };
    }

    pub fn deinit(self: *HookFileConfig) void {
        for (self.hook_configs) |*entry| {
            entry.deinit(self.allocator);
        }
        if (self.hook_configs.len > 0) self.allocator.free(self.hook_configs);
    }

    /// Load hook configuration from a file path.
    pub fn loadFromFile(self: *HookFileConfig, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return;

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);
        try self.parseToml(buffer);
    }

    /// Parse TOML content into hook config entries.
    fn parseToml(self: *HookFileConfig, content: []const u8) !void {
        var entries = array_list_compat.ArrayList(HookConfigEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit();
        }

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var in_hooks_section = false;
        var current_type: ?hooks.HookType = null;
        var current_command: ?[]const u8 = null;
        var current_enabled: bool = true;
        var current_timeout_ms: u64 = 30000;

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.eql(u8, trimmed, "[[hooks]]")) {
                // Flush previous entry
                if (in_hooks_section) {
                    if (current_type != null and current_command != null) {
                        try entries.append(HookConfigEntry{
                            .hook_type = current_type.?,
                            .command = current_command.?,
                            .enabled = current_enabled,
                            .timeout_ms = current_timeout_ms,
                        });
                    } else {
                        if (current_command) |cmd| self.allocator.free(cmd);
                    }
                }
                in_hooks_section = true;
                current_type = null;
                current_command = null;
                current_enabled = true;
                current_timeout_ms = 30000;
                continue;
            }

            // Detect a different section — flush current hook
            if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[[")) {
                if (in_hooks_section) {
                    if (current_type != null and current_command != null) {
                        try entries.append(HookConfigEntry{
                            .hook_type = current_type.?,
                            .command = current_command.?,
                            .enabled = current_enabled,
                            .timeout_ms = current_timeout_ms,
                        });
                    } else {
                        if (current_command) |cmd| self.allocator.free(cmd);
                    }
                }
                in_hooks_section = false;
                current_type = null;
                current_command = null;
                continue;
            }

            if (!in_hooks_section) continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                const unquoted = if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
                    val[1 .. val.len - 1]
                else
                    val;

                if (std.mem.eql(u8, key, "type")) {
                    if (std.mem.eql(u8, unquoted, "PreToolUse")) current_type = .PreToolUse
                    else if (std.mem.eql(u8, unquoted, "PostToolUse")) current_type = .PostToolUse
                    else if (std.mem.eql(u8, unquoted, "SessionStart")) current_type = .SessionStart
                    else if (std.mem.eql(u8, unquoted, "SessionEnd")) current_type = .SessionEnd
                    else if (std.mem.eql(u8, unquoted, "Notification")) current_type = .Notification
                    else if (std.mem.eql(u8, unquoted, "PreSessionLoad")) current_type = .PreSessionLoad
                    else if (std.mem.eql(u8, unquoted, "PostSessionSave")) current_type = .PostSessionSave;
                } else if (std.mem.eql(u8, key, "command")) {
                    if (current_command) |cmd| self.allocator.free(cmd);
                    current_command = try self.allocator.dupe(u8, unquoted);
                } else if (std.mem.eql(u8, key, "enabled")) {
                    current_enabled = std.mem.eql(u8, unquoted, "true");
                } else if (std.mem.eql(u8, key, "timeout_ms")) {
                    current_timeout_ms = std.fmt.parseInt(u64, unquoted, 10) catch 30000;
                }
            }
        }

        // Flush last entry
        if (in_hooks_section) {
            if (current_type != null and current_command != null) {
                try entries.append(HookConfigEntry{
                    .hook_type = current_type.?,
                    .command = current_command.?,
                    .enabled = current_enabled,
                    .timeout_ms = current_timeout_ms,
                });
            } else {
                if (current_command) |cmd| self.allocator.free(cmd);
            }
        }

        // Free old configs if any
        for (self.hook_configs) |*entry| {
            entry.deinit(self.allocator);
        }
        if (self.hook_configs.len > 0) self.allocator.free(self.hook_configs);

        self.hook_configs = try entries.toOwnedSlice();
    }

    /// Apply all loaded hook configs to a registry.
    pub fn applyToRegistry(self: *HookFileConfig, registry: *hooks.HookRegistry) !void {
        for (self.hook_configs) |entry| {
            try registry.registerHook(hooks.HookConfig{
                .hook_type = entry.hook_type,
                .command = entry.command,
                .enabled = entry.enabled,
                .timeout_ms = entry.timeout_ms,
            });
        }
    }
};

/// Get the user-level hooks config path: ~/.config/crushcode/hooks.toml
pub fn getUserHooksPath(allocator: Allocator) ![]const u8 {
    const config_dir = try env.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "hooks.toml" });
}

/// Get the project-level hooks config path: ./crushcode.hooks.toml
pub fn getProjectHooksPath(allocator: Allocator) ![]const u8 {
    return allocator.dupe(u8, "crushcode.hooks.toml");
}

/// Load hooks from both user-level and project-level config files.
/// Project-level hooks are loaded after user-level, so they can add or override.
/// Returns the number of hooks loaded.
pub fn loadAllHooks(allocator: Allocator, registry: *hooks.HookRegistry) !usize {
    var count: usize = 0;

    // Load user-level hooks
    const user_path = getUserHooksPath(allocator) catch null;
    if (user_path) |path| {
        defer allocator.free(path);
        const before = registry.hooks.items.len;
        registry.loadFromConfig(path) catch {};
        count += registry.hooks.items.len - before;
    }

    // Load project-level hooks
    const project_path = getProjectHooksPath(allocator) catch null;
    if (project_path) |path| {
        defer allocator.free(path);
        const before = registry.hooks.items.len;
        registry.loadFromConfig(path) catch {};
        count += registry.hooks.items.len - before;
    }

    return count;
}

// ============================================================
// Tests
// ============================================================

test "HookFileConfig init/deinit" {
    const allocator = std.testing.allocator;
    var config = HookFileConfig.init(allocator);
    defer config.deinit();

    try std.testing.expect(config.hook_configs.len == 0);
}

test "HookFileConfig parseToml" {
    const allocator = std.testing.allocator;
    var config = HookFileConfig.init(allocator);
    defer config.deinit();

    const toml =
        \\[[hooks]]
        \\type = "PreToolUse"
        \\command = "lint-check.sh"
        \\enabled = true
        \\timeout_ms = 10000
        \\
        \\[[hooks]]
        \\type = "SessionStart"
        \\command = "notify-start.sh"
        \\enabled = false
    ;

    try config.parseToml(toml);
    try std.testing.expect(config.hook_configs.len == 2);
    try std.testing.expect(config.hook_configs[0].hook_type == .PreToolUse);
    try std.testing.expect(std.mem.eql(u8, config.hook_configs[0].command, "lint-check.sh"));
    try std.testing.expect(config.hook_configs[0].enabled == true);
    try std.testing.expect(config.hook_configs[0].timeout_ms == 10000);
    try std.testing.expect(config.hook_configs[1].hook_type == .SessionStart);
    try std.testing.expect(config.hook_configs[1].enabled == false);
}

test "HookFileConfig loadFromFile missing file" {
    const allocator = std.testing.allocator;
    var config = HookFileConfig.init(allocator);
    defer config.deinit();

    // Should silently succeed (no hooks to load)
    try config.loadFromFile("/tmp/nonexistent_hooks_file_99999.toml");
    try std.testing.expect(config.hook_configs.len == 0);
}
