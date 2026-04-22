/// Hook Registry — lifecycle hook registry for pre/post tool execution,
/// session lifecycle, and notification hooks.
///
/// Hooks are shell commands that execute at specific lifecycle points.
/// Pre-tool hooks can block execution by returning non-zero exit codes.
/// Context is passed to hook commands via environment variables.
const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;

/// Types of hooks that can be registered.
pub const HookType = enum {
    PreToolUse,
    PostToolUse,
    SessionStart,
    SessionEnd,
    Notification,
    PreSessionLoad,
    PostSessionSave,
};

/// Configuration for a single hook.
pub const HookConfig = struct {
    hook_type: HookType,
    command: []const u8,
    enabled: bool = true,
    timeout_ms: u64 = 30000,

    pub fn deinit(self: *const HookConfig, allocator: Allocator) void {
        allocator.free(self.command);
    }
};

/// Context passed to hooks describing the event.
pub const HookContext = struct {
    hook_type: HookType,
    tool_name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    result: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    timestamp: i64,
};

/// Result from executing a hook command.
pub const HookResult = struct {
    /// For pre-hooks, false means the tool execution should be aborted.
    allowed: bool,
    output: []const u8,
    exit_code: i32,

    pub fn deinit(self: *const HookResult, allocator: Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
    }
};

/// Registry that manages and executes hooks at lifecycle points.
pub const HookRegistry = struct {
    allocator: Allocator,
    hooks: ArrayList(HookConfig),
    initialized: bool,

    /// Create a new empty hook registry.
    pub fn init(allocator: Allocator) HookRegistry {
        return HookRegistry{
            .allocator = allocator,
            .hooks = ArrayList(HookConfig).init(allocator),
            .initialized = true,
        };
    }

    /// Free all registered hooks and their resources.
    pub fn deinit(self: *HookRegistry) void {
        for (self.hooks.items) |*hook| {
            hook.deinit(self.allocator);
        }
        self.hooks.deinit();
        self.initialized = false;
    }

    /// Register a new hook.
    pub fn registerHook(self: *HookRegistry, config: HookConfig) !void {
        const owned_command = try self.allocator.dupe(u8, config.command);
        errdefer self.allocator.free(owned_command);

        try self.hooks.append(HookConfig{
            .hook_type = config.hook_type,
            .command = owned_command,
            .enabled = config.enabled,
            .timeout_ms = config.timeout_ms,
        });
    }

    /// Remove a hook by index.
    pub fn removeHook(self: *HookRegistry, index: usize) void {
        if (index >= self.hooks.items.len) return;
        var removed = self.hooks.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    /// Execute all hooks matching the given context's hook type.
    /// Returns a slice of results owned by the caller.
    pub fn executeHooks(self: *HookRegistry, context: *const HookContext) ![]HookResult {
        var results = ArrayList(HookResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        for (self.hooks.items) |hook| {
            if (!hook.enabled) continue;
            if (hook.hook_type != context.hook_type) continue;

            const result = self.runCommand(hook, context) catch |err| {
                const err_output = std.fmt.allocPrint(self.allocator, "Hook execution error: {}", .{err}) catch "Hook execution error";
                try results.append(HookResult{
                    .allowed = true,
                    .output = err_output,
                    .exit_code = -1,
                });
                continue;
            };
            try results.append(result);
        }

        return try results.toOwnedSlice();
    }

    /// For pre-tool hooks: returns false if any hook returns a non-zero exit code.
    /// Returns true if no hooks are registered or all hooks pass.
    pub fn shouldProceed(self: *HookRegistry, context: *const HookContext) !bool {
        const results = try self.executeHooks(context);
        defer {
            for (results) |*r| r.deinit(self.allocator);
            self.allocator.free(results);
        }

        for (results) |result| {
            if (!result.allowed) return false;
        }
        return true;
    }

    /// Load hooks from a TOML config file.
    /// The file format uses [[hooks]] arrays with fields: type, command, enabled, timeout_ms.
    pub fn loadFromConfig(self: *HookRegistry, config_path: []const u8) !void {
        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return;

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);
        try self.parseHooksToml(buffer);
    }

    /// Parse TOML content for hook definitions.
    fn parseHooksToml(self: *HookRegistry, content: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var in_hooks_section = false;
        var current_type: ?HookType = null;
        var current_command: ?[]const u8 = null;
        var current_enabled: bool = true;
        var current_timeout_ms: u64 = 30000;

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Detect [[hooks]] section header
            if (std.mem.eql(u8, trimmed, "[[hooks]]")) {
                // Flush any previous hook entry
                if (in_hooks_section) {
                    if (current_type != null and current_command != null) {
                        try self.registerHook(HookConfig{
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

            // Detect a different section header — flush current hook
            if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[[")) {
                if (in_hooks_section) {
                    if (current_type != null and current_command != null) {
                        try self.registerHook(HookConfig{
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

            // Parse key = value pairs
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                // Strip quotes from value
                const unquoted = if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
                    val[1 .. val.len - 1]
                else
                    val;

                if (std.mem.eql(u8, key, "type")) {
                    current_type = parseHookType(unquoted);
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

        // Flush last hook entry
        if (in_hooks_section) {
            if (current_type != null and current_command != null) {
                try self.registerHook(HookConfig{
                    .hook_type = current_type.?,
                    .command = current_command.?,
                    .enabled = current_enabled,
                    .timeout_ms = current_timeout_ms,
                });
            } else {
                if (current_command) |cmd| self.allocator.free(cmd);
            }
        }
    }

    /// Parse a HookType from a string representation.
    pub fn parseHookType(name: []const u8) ?HookType {
        if (std.mem.eql(u8, name, "PreToolUse")) return .PreToolUse;
        if (std.mem.eql(u8, name, "PostToolUse")) return .PostToolUse;
        if (std.mem.eql(u8, name, "SessionStart")) return .SessionStart;
        if (std.mem.eql(u8, name, "SessionEnd")) return .SessionEnd;
        if (std.mem.eql(u8, name, "Notification")) return .Notification;
        if (std.mem.eql(u8, name, "PreSessionLoad")) return .PreSessionLoad;
        if (std.mem.eql(u8, name, "PostSessionSave")) return .PostSessionSave;
        return null;
    }

    /// Run a hook's shell command, passing context as environment variables.
    fn runCommand(self: *HookRegistry, hook: HookConfig, context: *const HookContext) !HookResult {
        // Build the shell command arguments
        var argv_list = ArrayList([]const u8).init(self.allocator);
        defer argv_list.deinit();
        try argv_list.append("sh");
        try argv_list.append("-c");
        try argv_list.append(hook.command);

        var child = std.process.Child.init(argv_list.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        // Set environment variables from context
        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        // Inherit current environment
        if (std.process.getEnvMap(self.allocator)) |env| {
            var iter = env.iterator();
            while (iter.next()) |entry| {
                env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
            // env is a const EnvMap returned from getEnvMap, no need to deinit
            // as it borrows from the process environment
        } else |_| {}

        // Set hook context as environment variables
        env_map.put("HOOK_TYPE", @tagName(context.hook_type)) catch {};
        if (context.tool_name) |tn| {
            env_map.put("HOOK_TOOL_NAME", tn) catch {};
        }
        if (context.arguments) |args| {
            env_map.put("HOOK_ARGUMENTS", args) catch {};
        }
        if (context.result) |res| {
            env_map.put("HOOK_RESULT", res) catch {};
        }
        if (context.session_id) |sid| {
            env_map.put("HOOK_SESSION_ID", sid) catch {};
        }

        child.env_map = &env_map;

        // Spawn the child process
        child.spawn() catch |err| {
            const err_msg = std.fmt.allocPrint(self.allocator, "Failed to spawn hook: {}", .{err}) catch "Failed to spawn hook";
            return HookResult{
                .allowed = true,
                .output = err_msg,
                .exit_code = -1,
            };
        };

        // Read stdout
        var output_buf: [4096]u8 = undefined;
        var output = ArrayList(u8).init(self.allocator);
        defer output.deinit();

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.read(&output_buf) catch break;
                if (n == 0) break;
                try output.appendSlice(output_buf[0..n]);
            }
        }

        // Read stderr
        var stderr_output = ArrayList(u8).init(self.allocator);
        defer stderr_output.deinit();

        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.read(&output_buf) catch break;
                if (n == 0) break;
                try stderr_output.appendSlice(output_buf[0..n]);
            }
        }

        // Wait for completion
        const term = child.wait() catch {
            const fail_output = self.allocator.dupe(u8, "Hook wait failed") catch "Hook wait failed";
            return HookResult{
                .allowed = true,
                .output = fail_output,
                .exit_code = -1,
            };
        };

        const exit_code: i32 = switch (term) {
            .Exited => |code| code,
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| -@as(i32, @intCast(code)),
        };

        // Combine stdout + stderr
        var combined = ArrayList(u8).init(self.allocator);
        defer combined.deinit();
        try combined.appendSlice(output.items);
        if (stderr_output.items.len > 0) {
            if (combined.items.len > 0) try combined.appendSlice("\n");
            try combined.appendSlice(stderr_output.items);
        }

        const result_output = if (combined.items.len > 0)
            try self.allocator.dupe(u8, combined.items)
        else
            try self.allocator.dupe(u8, "");

        return HookResult{
            .allowed = exit_code == 0,
            .output = result_output,
            .exit_code = exit_code,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "HookRegistry init/deinit" {
    const allocator = std.testing.allocator;
    var registry = HookRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.initialized);
    try std.testing.expect(registry.hooks.items.len == 0);
}

test "HookRegistry registerHook and removeHook" {
    const allocator = std.testing.allocator;
    var registry = HookRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerHook(HookConfig{
        .hook_type = .PreToolUse,
        .command = "echo 'pre-tool'",
    });

    try std.testing.expect(registry.hooks.items.len == 1);
    try std.testing.expect(registry.hooks.items[0].hook_type == .PreToolUse);
    try std.testing.expect(std.mem.eql(u8, registry.hooks.items[0].command, "echo 'pre-tool'"));
    try std.testing.expect(registry.hooks.items[0].enabled == true);

    registry.removeHook(0);
    try std.testing.expect(registry.hooks.items.len == 0);
}

test "HookRegistry shouldProceed returns true when no hooks match" {
    const allocator = std.testing.allocator;
    var registry = HookRegistry.init(allocator);
    defer registry.deinit();

    var ctx = HookContext{
        .hook_type = .PreToolUse,
        .tool_name = "read_file",
        .timestamp = std.time.milliTimestamp(),
    };

    const proceed = try registry.shouldProceed(&ctx);
    try std.testing.expect(proceed == true);
}

test "HookRegistry parseHookType" {
    try std.testing.expect(HookRegistry.parseHookType("PreToolUse") == .PreToolUse);
    try std.testing.expect(HookRegistry.parseHookType("PostToolUse") == .PostToolUse);
    try std.testing.expect(HookRegistry.parseHookType("SessionStart") == .SessionStart);
    try std.testing.expect(HookRegistry.parseHookType("SessionEnd") == .SessionEnd);
    try std.testing.expect(HookRegistry.parseHookType("Notification") == .Notification);
    try std.testing.expect(HookRegistry.parseHookType("PreSessionLoad") == .PreSessionLoad);
    try std.testing.expect(HookRegistry.parseHookType("PostSessionSave") == .PostSessionSave);
    try std.testing.expect(HookRegistry.parseHookType("invalid") == null);
}

test "HookRegistry parseHooksToml" {
    const allocator = std.testing.allocator;
    var registry = HookRegistry.init(allocator);
    defer registry.deinit();

    const toml_content =
        \\[[hooks]]
        \\type = "PreToolUse"
        \\command = "echo 'checking'"
        \\enabled = true
        \\timeout_ms = 5000
        \\
        \\[[hooks]]
        \\type = "PostToolUse"
        \\command = "echo 'done'"
        \\enabled = false
    ;

    try registry.parseHooksToml(toml_content);

    try std.testing.expect(registry.hooks.items.len == 2);
    try std.testing.expect(registry.hooks.items[0].hook_type == .PreToolUse);
    try std.testing.expect(std.mem.eql(u8, registry.hooks.items[0].command, "echo 'checking'"));
    try std.testing.expect(registry.hooks.items[0].enabled == true);
    try std.testing.expect(registry.hooks.items[0].timeout_ms == 5000);
    try std.testing.expect(registry.hooks.items[1].hook_type == .PostToolUse);
    try std.testing.expect(registry.hooks.items[1].enabled == false);
}

test "HookRegistry loadFromConfig with missing file" {
    const allocator = std.testing.allocator;
    var registry = HookRegistry.init(allocator);
    defer registry.deinit();

    // Missing file should silently succeed (no hooks to load)
    try registry.loadFromConfig("/tmp/nonexistent_hooks_config_12345.toml");
    try std.testing.expect(registry.hooks.items.len == 0);
}

test "HookContext default fields" {
    const ctx = HookContext{
        .hook_type = .Notification,
        .timestamp = 12345,
    };
    try std.testing.expect(ctx.hook_type == .Notification);
    try std.testing.expect(ctx.tool_name == null);
    try std.testing.expect(ctx.arguments == null);
    try std.testing.expect(ctx.result == null);
    try std.testing.expect(ctx.session_id == null);
    try std.testing.expect(ctx.timestamp == 12345);
}
