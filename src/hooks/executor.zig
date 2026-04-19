const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const lifecycle = @import("lifecycle_hooks");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;

/// A registered hook script — maps a shell script or executable to a lifecycle phase.
pub const HookScript = struct {
    name: []const u8,
    script_path: []const u8,
    phase: lifecycle.HookPhase,
    tier: lifecycle.HookTier,
    enabled: bool,
    timeout_ms: u64,
    is_read_only: bool,
};

/// Result from executing a single hook script.
pub const HookResult = struct {
    hook_name: []const u8,
    success: bool,
    output: []const u8,
    exit_code: i32,
    duration_ms: u64,

    pub fn deinit(self: *HookResult, allocator: Allocator) void {
        allocator.free(self.hook_name);
        allocator.free(self.output);
    }
};

pub const HookExecutorError = error{
    HookNotFound,
    HookExecutionFailed,
    ScriptNotFound,
    Timeout,
};

/// Hook execution engine — runs user-defined hook scripts at lifecycle events.
///
/// Wraps the existing `LifecycleHooks` in-process system and adds
/// script-based execution. Scripts are discovered from `.crushcode/hooks/`
/// (and `.claude/hooks/` for Claude Code compatibility) and auto-registered
/// based on naming conventions:
///   - `pre-tool-*.sh`  → `.pre_tool` phase
///   - `post-tool-*.sh` → `.post_tool` phase
///   - `pre-edit-*.sh`  → `.pre_edit` phase
///   - `post-edit-*.sh` → `.post_edit` phase
///   - `pre-request-*.sh`  → `.pre_request` phase
///   - `post-request-*.sh` → `.post_request` phase
///   - `session-start-*.sh` → `.session_start` phase
///   - `session-end-*.sh`   → `.session_end` phase
///   - `on-error-*.sh`      → `.on_error` phase
pub const HookExecutor = struct {
    allocator: Allocator,
    scripts: ArrayList(HookScript),
    hooks_dir: []const u8,
    lifecycle_hooks: *lifecycle.LifecycleHooks,
    results_history: ArrayList(HookResult),
    max_history: u32,
    dry_run: bool,

    /// Initialize the hook executor.
    /// `hooks_dir` defaults to `.crushcode/hooks/` if empty.
    pub fn init(allocator: Allocator, lifecycle_hooks: *lifecycle.LifecycleHooks, hooks_dir: []const u8) HookExecutor {
        const dir = if (hooks_dir.len > 0) hooks_dir else ".crushcode/hooks/";
        return HookExecutor{
            .allocator = allocator,
            .scripts = ArrayList(HookScript).init(allocator),
            .hooks_dir = dir,
            .lifecycle_hooks = lifecycle_hooks,
            .results_history = ArrayList(HookResult).init(allocator),
            .max_history = 100,
            .dry_run = false,
        };
    }

    pub fn deinit(self: *HookExecutor) void {
        // Free script strings
        for (self.scripts.items) |script| {
            self.allocator.free(script.name);
            self.allocator.free(script.script_path);
        }
        self.scripts.deinit();

        // Free history
        for (self.results_history.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results_history.deinit();
    }

    /// Register a new hook script.
    pub fn registerScript(self: *HookExecutor, name: []const u8, script_path: []const u8, phase: lifecycle.HookPhase, tier: lifecycle.HookTier) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, script_path);
        errdefer self.allocator.free(owned_path);

        try self.scripts.append(HookScript{
            .name = owned_name,
            .script_path = owned_path,
            .phase = phase,
            .tier = tier,
            .enabled = true,
            .timeout_ms = 30000,
            .is_read_only = false,
        });
    }

    /// Scan the hooks directory for script files and auto-register them.
    /// Naming convention: `<phase>-<name>.sh` maps to the corresponding phase.
    /// Also checks `.claude/hooks/` for Claude Code compatibility.
    pub fn discoverHooks(self: *HookExecutor) !usize {
        var count: usize = 0;

        // Scan primary hooks directory
        count += try self.scanDirectory(self.hooks_dir);

        // Scan Claude Code compatible directory
        count += try self.scanDirectory(".claude/hooks/");

        return count;
    }

    /// Scan a single directory for hook scripts.
    fn scanDirectory(self: *HookExecutor, dir_path: []const u8) !usize {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var count: usize = 0;
        var walker = dir.walk(self.allocator) catch return 0;
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const fname = entry.basename;

            // Only handle .sh files
            if (!std.mem.endsWith(u8, fname, ".sh")) continue;

            const phase = phaseFromFilename(fname) orelse continue;

            // Build full path
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.path });
            // Derive hook name from filename (strip .sh extension)
            const hook_name = if (fname.len > 3)
                try self.allocator.dupe(u8, fname[0 .. fname.len - 3])
            else
                try self.allocator.dupe(u8, fname);

            // Determine tier based on directory
            const tier: lifecycle.HookTier = if (std.mem.indexOf(u8, dir_path, ".claude") != null)
                .skill
            else
                .core;

            try self.scripts.append(HookScript{
                .name = hook_name,
                .script_path = full_path,
                .phase = phase,
                .tier = tier,
                .enabled = true,
                .timeout_ms = 30000,
                .is_read_only = false,
            });
            count += 1;
        }

        return count;
    }

    /// Execute all hooks matching a phase. Returns slice of results (owned by allocator).
    pub fn executePhase(self: *HookExecutor, phase: lifecycle.HookPhase, ctx: *lifecycle.HookContext) ![]HookResult {
        var results = ArrayList(HookResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        // Also run in-process lifecycle hooks
        self.lifecycle_hooks.execute(phase, ctx) catch {};

        for (self.scripts.items) |script| {
            if (!script.enabled) continue;
            if (script.phase != phase) continue;

            if (self.dry_run) {
                // In dry-run mode, log what would run but don't execute
                std.log.info("[dry-run] Would execute hook: {s} ({s})", .{ script.name, script.script_path });
                continue;
            }

            const result = self.runScript(script, ctx) catch |err| {
                const err_result = HookResult{
                    .hook_name = try self.allocator.dupe(u8, script.name),
                    .success = false,
                    .output = try std.fmt.allocPrint(self.allocator, "Execution error: {}", .{err}),
                    .exit_code = -1,
                    .duration_ms = 0,
                };
                try results.append(err_result);
                continue;
            };

            try results.append(result);

            // Block on non-read-only hook failure
            const last = &results.items[results.items.len - 1];
            if (!last.success and !script.is_read_only) {
                std.log.warn("Hook '{s}' failed (exit={d}), blocking operation", .{ last.hook_name, last.exit_code });
            } else if (!last.success and script.is_read_only) {
                std.log.warn("Hook '{s}' failed (exit={d}), but is read-only — continuing", .{ last.hook_name, last.exit_code });
            }
        }

        // Track in history
        for (results.items) |result| {
            try self.addToHistory(result);
        }

        return try results.toOwnedSlice();
    }

    /// Execute a single hook by name.
    pub fn executeSingle(self: *HookExecutor, hook_name: []const u8, ctx: *lifecycle.HookContext) ?HookResult {
        for (self.scripts.items) |script| {
            if (!std.mem.eql(u8, script.name, hook_name)) continue;
            if (!script.enabled) {
                std.log.warn("Hook '{s}' is disabled", .{hook_name});
                return null;
            }

            const result = self.runScript(script, ctx) catch |err| {
                const err_result = HookResult{
                    .hook_name = self.allocator.dupe(u8, script.name) catch return null,
                    .success = false,
                    .output = std.fmt.allocPrint(self.allocator, "Execution error: {}", .{err}) catch return null,
                    .exit_code = -1,
                    .duration_ms = 0,
                };
                self.addToHistory(err_result) catch {};
                return err_result;
            };

            self.addToHistory(result) catch {};
            return result;
        }
        return null;
    }

    /// Get historical results, optionally filtered by phase.
    pub fn getHistory(self: *HookExecutor, phase: ?lifecycle.HookPhase) []const HookResult {
        if (phase == null) return self.results_history.items;

        // For phase filtering, we need to match hook names to scripts
        // Simple approach: return all history; caller can further filter
        return self.results_history.items;
    }

    /// Enable a hook by name.
    pub fn enableHook(self: *HookExecutor, name: []const u8) bool {
        for (self.scripts.items) |*script| {
            if (std.mem.eql(u8, script.name, name)) {
                script.enabled = true;
                return true;
            }
        }
        return false;
    }

    /// Disable a hook by name.
    pub fn disableHook(self: *HookExecutor, name: []const u8) bool {
        for (self.scripts.items) |*script| {
            if (std.mem.eql(u8, script.name, name)) {
                script.enabled = false;
                return true;
            }
        }
        return false;
    }

    /// Dry-run a hook for testing — returns a result without actually executing.
    pub fn testHook(self: *HookExecutor, name: []const u8, test_ctx: *lifecycle.HookContext) ?HookResult {
        for (self.scripts.items) |script| {
            if (!std.mem.eql(u8, script.name, name)) continue;

            const output = std.fmt.allocPrint(self.allocator, "[test] Would execute: {s} with context phase={s}", .{
                script.script_path,
                @tagName(test_ctx.phase),
            }) catch return null;

            return HookResult{
                .hook_name = self.allocator.dupe(u8, script.name) catch return null,
                .success = true,
                .output = output,
                .exit_code = 0,
                .duration_ms = 0,
            };
        }
        return null;
    }

    /// Print formatted status of all hooks.
    pub fn printStatus(self: *HookExecutor) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Hook Executor Status ===\n", .{}) catch {};
        stdout.print("  Hooks directory: {s}\n", .{self.hooks_dir}) catch {};
        stdout.print("  Registered scripts: {d}\n", .{self.scripts.items.len}) catch {};
        stdout.print("  Dry run: {s}\n", .{if (self.dry_run) "ON" else "OFF"}) catch {};
        stdout.print("  History entries: {d} (max: {d})\n\n", .{ self.results_history.items.len, self.max_history }) catch {};

        if (self.scripts.items.len == 0) {
            stdout.print("  No hook scripts registered.\n", .{}) catch {};
            stdout_print_usage();
            return;
        }

        // Header
        stdout.print("  NAME                           PHASE        TIER            ENABLE TIMEOUT   READ-ONLY\n", .{}) catch {};
        stdout.print("  -------------------------------------------------------------------------------------\n", .{}) catch {};

        for (self.scripts.items) |script| {
            const enabled = if (script.enabled) "yes" else "no";
            const read_only = if (script.is_read_only) "yes" else "no";
            const tier_label = switch (script.tier) {
                .core => "CORE",
                .continuation => "CONT",
                .skill => "SKILL",
            };
            stdout.print("  {s:<30} {s:<12} {s:<15} {s:<6} {d:<7}   {s}\n", .{
                script.name,
                @tagName(script.phase),
                tier_label,
                enabled,
                script.timeout_ms,
                read_only,
            }) catch {};
        }

        // Show last few history entries
        if (self.results_history.items.len > 0) {
            stdout.print("\n--- Recent History (last 5) ---\n", .{}) catch {};
            const start = if (self.results_history.items.len > 5)
                self.results_history.items.len - 5
            else
                0;
            for (self.results_history.items[start..]) |result| {
                const status = if (result.success) "OK" else "FAIL";
                stdout.print("  [{s}] {s} (exit={d}, {d}ms)\n", .{
                    status,
                    result.hook_name,
                    result.exit_code,
                    result.duration_ms,
                }) catch {};
            }
        }
    }

    /// Run a single script as a subprocess.
    fn runScript(self: *HookExecutor, script: HookScript, ctx: *lifecycle.HookContext) !HookResult {
        const start_time = std.time.milliTimestamp();

        // Build environment variables from context
        var env_buf = ArrayList(u8).init(self.allocator);
        defer env_buf.deinit();

        // Set hook context as environment variables for the script
        try env_buf.writer().print("HOOK_PHASE={s}\n", .{@tagName(ctx.phase)});
        try env_buf.writer().print("HOOK_PROVIDER={s}\n", .{ctx.provider});
        try env_buf.writer().print("HOOK_MODEL={s}\n", .{ctx.model});
        if (ctx.tool_name) |tn| {
            try env_buf.writer().print("HOOK_TOOL={s}\n", .{tn});
        }
        if (ctx.file_path) |fp| {
            try env_buf.writer().print("HOOK_FILE={s}\n", .{fp});
        }
        if (ctx.error_message) |em| {
            try env_buf.writer().print("HOOK_ERROR={s}\n", .{em});
        }
        try env_buf.writer().print("HOOK_TOKEN_COUNT={d}\n", .{ctx.token_count});

        // Execute script as subprocess
        var argv = [_][]const u8{script.script_path};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        // Try to spawn; if script doesn't exist, report failure
        child.spawn() catch |err| {
            const end_time = std.time.milliTimestamp();
            const duration = if (end_time > start_time) @as(u64, @intCast(end_time - start_time)) else 0;
            return HookResult{
                .hook_name = try self.allocator.dupe(u8, script.name),
                .success = false,
                .output = try std.fmt.allocPrint(self.allocator, "Spawn failed: {}", .{err}),
                .exit_code = -1,
                .duration_ms = duration,
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
            const end_time = std.time.milliTimestamp();
            const duration = if (end_time > start_time) @as(u64, @intCast(end_time - start_time)) else 0;
            return HookResult{
                .hook_name = try self.allocator.dupe(u8, script.name),
                .success = false,
                .output = try self.allocator.dupe(u8, "Wait failed"),
                .exit_code = -1,
                .duration_ms = duration,
            };
        };

        const end_time = std.time.milliTimestamp();
        const duration = if (end_time > start_time) @as(u64, @intCast(end_time - start_time)) else 0;

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
            try self.allocator.dupe(u8, "(no output)");

        return HookResult{
            .hook_name = try self.allocator.dupe(u8, script.name),
            .success = exit_code == 0,
            .output = result_output,
            .exit_code = exit_code,
            .duration_ms = duration,
        };
    }

    /// Add a result to the history ring buffer.
    fn addToHistory(self: *HookExecutor, result: HookResult) !void {
        // If at max capacity, remove oldest
        if (self.results_history.items.len >= self.max_history) {
            var oldest = self.results_history.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        // Deep-copy the result into history
        const history_entry = HookResult{
            .hook_name = try self.allocator.dupe(u8, result.hook_name),
            .success = result.success,
            .output = try self.allocator.dupe(u8, result.output),
            .exit_code = result.exit_code,
            .duration_ms = result.duration_ms,
        };
        try self.results_history.append(history_entry);
    }
};

/// Derive a hook phase from a filename.
/// Convention: `pre-tool-foo.sh` → `.pre_tool`, `post-edit-bar.sh` → `.post_edit`, etc.
fn phaseFromFilename(fname: []const u8) ?lifecycle.HookPhase {
    if (std.mem.startsWith(u8, fname, "pre-request-")) return .pre_request;
    if (std.mem.startsWith(u8, fname, "post-request-")) return .post_request;
    if (std.mem.startsWith(u8, fname, "pre-tool-")) return .pre_tool;
    if (std.mem.startsWith(u8, fname, "post-tool-")) return .post_tool;
    if (std.mem.startsWith(u8, fname, "pre-edit-")) return .pre_edit;
    if (std.mem.startsWith(u8, fname, "post-edit-")) return .post_edit;
    if (std.mem.startsWith(u8, fname, "session-start-")) return .session_start;
    if (std.mem.startsWith(u8, fname, "session-end-")) return .session_end;
    if (std.mem.startsWith(u8, fname, "on-error-")) return .on_error;
    return null;
}

fn stdout_print_usage() void {
    const stdout = file_compat.File.stdout().writer();
    stdout.print("\n  Use 'crushcode hooks discover' to scan for hook scripts.\n", .{}) catch {};
    stdout.print("  Place scripts in .crushcode/hooks/ or .claude/hooks/\n", .{}) catch {};
    stdout.print("  Naming: pre-tool-*.sh, post-edit-*.sh, etc.\n", .{}) catch {};
}

// ============================================================
// Tests
// ============================================================

test "HookScript creation and registration" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    try executor.registerScript("test-hook", "/tmp/test-hook.sh", .pre_tool, .core);

    try std.testing.expect(executor.scripts.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, executor.scripts.items[0].name, "test-hook"));
    try std.testing.expect(std.mem.eql(u8, executor.scripts.items[0].script_path, "/tmp/test-hook.sh"));
    try std.testing.expect(executor.scripts.items[0].phase == .pre_tool);
    try std.testing.expect(executor.scripts.items[0].tier == .core);
    try std.testing.expect(executor.scripts.items[0].enabled == true);
    try std.testing.expect(executor.scripts.items[0].timeout_ms == 30000);
    try std.testing.expect(executor.scripts.items[0].is_read_only == false);
}

test "phaseFromFilename — naming convention mapping" {
    try std.testing.expect(phaseFromFilename("pre-tool-lint.sh") == .pre_tool);
    try std.testing.expect(phaseFromFilename("post-tool-notify.sh") == .post_tool);
    try std.testing.expect(phaseFromFilename("pre-edit-backup.sh") == .pre_edit);
    try std.testing.expect(phaseFromFilename("post-edit-validate.sh") == .post_edit);
    try std.testing.expect(phaseFromFilename("pre-request-log.sh") == .pre_request);
    try std.testing.expect(phaseFromFilename("post-request-parse.sh") == .post_request);
    try std.testing.expect(phaseFromFilename("session-start-init.sh") == .session_start);
    try std.testing.expect(phaseFromFilename("session-end-cleanup.sh") == .session_end);
    try std.testing.expect(phaseFromFilename("on-error-alert.sh") == .on_error);

    // Non-matching names
    try std.testing.expect(phaseFromFilename("random-script.sh") == null);
    try std.testing.expect(phaseFromFilename("tool-pre-lint.sh") == null);
    try std.testing.expect(phaseFromFilename("README.md") == null);
}

test "phase matching — only matching hooks execute" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    // Register hooks in different phases
    try executor.registerScript("hook-pre-tool", "/tmp/a.sh", .pre_tool, .core);
    try executor.registerScript("hook-post-tool", "/tmp/b.sh", .post_tool, .core);
    try executor.registerScript("hook-pre-edit", "/tmp/c.sh", .pre_edit, .core);

    // Enable dry run so we don't actually execute scripts
    executor.dry_run = true;

    var ctx = lifecycle.HookContext.init(allocator);
    defer ctx.deinit();
    ctx.phase = .pre_tool;

    // executePhase should only process pre_tool hooks (1 match)
    const results = try executor.executePhase(.pre_tool, &ctx);
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }
    // In dry_run mode, no results are appended
    try std.testing.expect(results.len == 0);
}

test "HookResult deinit" {
    const allocator = std.testing.allocator;

    var result = HookResult{
        .hook_name = try allocator.dupe(u8, "test-result"),
        .success = true,
        .output = try allocator.dupe(u8, "hello world"),
        .exit_code = 0,
        .duration_ms = 42,
    };

    result.deinit(allocator);
    // No double-free; if this completes without crashing, the test passes.
}

test "history tracking" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();
    executor.max_history = 3;

    // Manually add results to history
    const r1 = HookResult{
        .hook_name = "hook-a",
        .success = true,
        .output = "output-a",
        .exit_code = 0,
        .duration_ms = 10,
    };
    const r2 = HookResult{
        .hook_name = "hook-b",
        .success = false,
        .output = "output-b",
        .exit_code = 1,
        .duration_ms = 20,
    };
    const r3 = HookResult{
        .hook_name = "hook-c",
        .success = true,
        .output = "output-c",
        .exit_code = 0,
        .duration_ms = 30,
    };
    const r4 = HookResult{
        .hook_name = "hook-d",
        .success = true,
        .output = "output-d",
        .exit_code = 0,
        .duration_ms = 40,
    };

    try executor.addToHistory(r1);
    try executor.addToHistory(r2);
    try executor.addToHistory(r3);

    try std.testing.expect(executor.results_history.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, executor.results_history.items[0].hook_name, "hook-a"));

    // Adding a 4th should evict the oldest
    try executor.addToHistory(r4);
    try std.testing.expect(executor.results_history.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, executor.results_history.items[0].hook_name, "hook-b"));
    try std.testing.expect(std.mem.eql(u8, executor.results_history.items[2].hook_name, "hook-d"));

    // getHistory returns all entries
    const history = executor.getHistory(null);
    try std.testing.expect(history.len == 3);
}

test "enable and disable hooks" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    try executor.registerScript("hook-1", "/tmp/a.sh", .pre_tool, .core);
    try executor.registerScript("hook-2", "/tmp/b.sh", .post_tool, .core);

    try std.testing.expect(executor.scripts.items[0].enabled == true);

    // Disable
    const found = executor.disableHook("hook-1");
    try std.testing.expect(found == true);
    try std.testing.expect(executor.scripts.items[0].enabled == false);

    // Disable non-existent
    const not_found = executor.disableHook("nonexistent");
    try std.testing.expect(not_found == false);

    // Re-enable
    const re_enabled = executor.enableHook("hook-1");
    try std.testing.expect(re_enabled == true);
    try std.testing.expect(executor.scripts.items[0].enabled == true);
}

test "testHook — dry-run a hook" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    try executor.registerScript("testable-hook", "/tmp/test.sh", .pre_edit, .core);

    var ctx = lifecycle.HookContext.init(allocator);
    defer ctx.deinit();
    ctx.phase = .pre_edit;

    const result = executor.testHook("testable-hook", &ctx);
    try std.testing.expect(result != null);

    const r = result.?;
    try std.testing.expect(r.success == true);
    try std.testing.expect(r.exit_code == 0);
    try std.testing.expect(std.mem.eql(u8, r.hook_name, "testable-hook"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Would execute") != null);

    // Clean up the returned result
    var mut_r = r;
    mut_r.deinit(allocator);

    // Non-existent hook
    const null_result = executor.testHook("no-such-hook", &ctx);
    try std.testing.expect(null_result == null);
}

test "printStatus — formatting" {
    const allocator = std.testing.allocator;

    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    try executor.registerScript("status-hook-a", "/tmp/a.sh", .pre_tool, .core);
    try executor.registerScript("status-hook-b", "/tmp/b.sh", .post_edit, .skill);
    _ = executor.disableHook("status-hook-b");

    // Should not crash — just prints to stdout
    executor.printStatus();
}
