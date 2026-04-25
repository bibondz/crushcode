/// Guardian Pipeline — unified security and lifecycle gate.
///
/// Every tool call, file edit, and AI request passes through:
///   1. Governance zone check (auto/propose/never)
///   2. Sensitive path check (block .env, .ssh, etc.)
///   3. Hook script execution (user-defined lifecycle hooks)
///
/// Fuses: hooks/executor + permission/governance + permission/sensitive_paths
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const hooks_executor_mod = @import("hooks_executor");
const lifecycle_hooks_mod = @import("lifecycle_hooks");
const governance_mod = @import("governance");
const sensitive_paths_mod = @import("sensitive_paths");

const Allocator = std.mem.Allocator;
const HookExecutor = hooks_executor_mod.HookExecutor;
const HookResult = hooks_executor_mod.HookResult;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;
const HookContext = lifecycle_hooks_mod.HookContext;
const HookPhase = lifecycle_hooks_mod.HookPhase;
const GovernancePolicy = governance_mod.GovernancePolicy;
const GovernanceZone = governance_mod.GovernanceZone;
const SensitivePathChecker = sensitive_paths_mod.SensitivePathChecker;

/// Verdict returned after checking a tool operation.
pub const GuardianVerdict = enum {
    /// Auto-allowed by governance policy.
    allow,
    /// Needs user approval (governance zone = propose).
    propose,
    /// Blocked by policy, sensitive path, or failing hook.
    block,
};

/// Result of a guardian check — includes verdict, reason, and hook results.
pub const GuardianResult = struct {
    verdict: GuardianVerdict,
    /// Human-readable reason for block/propose (owned by allocator).
    reason: ?[]const u8,
    /// Results from hook execution (owned by executor).
    hook_results: []const HookResult,

    pub fn deinit(self: *GuardianResult, allocator: Allocator) void {
        if (self.reason) |r| allocator.free(r);
        // hook_results are freed separately by the caller using freeHookResults
    }
};

/// Free a slice of HookResult returned by the guardian.
pub fn freeHookResults(allocator: Allocator, results: []const HookResult) void {
    const mutable: []HookResult = @constCast(results);
    for (mutable) |*r| {
        r.deinit(allocator);
    }
    allocator.free(mutable);
}

/// Unified Guardian pipeline — fuses governance, sensitive paths, and hooks.
pub const Guardian = struct {
    allocator: Allocator,
    lifecycle_hooks: LifecycleHooks,
    executor: HookExecutor,
    governance: GovernancePolicy,
    path_checker: SensitivePathChecker,

    /// Create a Guardian instance. Initializes internal LifecycleHooks,
    /// HookExecutor, GovernancePolicy, and SensitivePathChecker.
    /// The executor holds a pointer to lifecycle_hooks, so the Guardian
    /// must be allocated on the heap (not returned by value) if the executor
    /// will be used. For stack allocation, use initStack and then call
    /// initExecutor separately.
    pub fn init(allocator: Allocator) !Guardian {
        var guardian = Guardian{
            .allocator = allocator,
            .lifecycle_hooks = LifecycleHooks.init(allocator),
            .executor = undefined,
            .governance = GovernancePolicy.init(allocator),
            .path_checker = SensitivePathChecker.init(allocator),
        };
        // Initialize executor with pointer to our own lifecycle_hooks field
        guardian.executor = HookExecutor.init(allocator, guardian.lifecycle_hooks, ".crushcode/hooks/");
        return guardian;
    }

    /// Clean up all internal resources.
    pub fn deinit(self: *Guardian) void {
        self.executor.deinit();
        self.governance.deinit();
        self.path_checker.deinit();
        self.lifecycle_hooks.deinit();
    }

    /// Discover hook scripts from .crushcode/hooks/ and .claude/hooks/.
    pub fn discoverHooks(self: *Guardian) !usize {
        return self.executor.discoverHooks();
    }

    /// Core gate — check whether a tool operation is allowed.
    ///
    /// Pipeline:
    ///   1. Governance zone check → block if `never`
    ///   2. Sensitive path check → block if path is protected
    ///   3. Pre-tool hooks → block if any hook fails
    ///   4. Return verdict (allow / propose)
    pub fn checkTool(self: *Guardian, tool_name: []const u8, action: []const u8, file_path: ?[]const u8) !GuardianResult {
        // Step 1: Check governance zone
        const operation = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ tool_name, action }) catch tool_name;
        defer if (std.mem.indexOf(u8, operation, ":") != null) self.allocator.free(operation);

        const zone = self.governance.getZone(operation);

        if (zone == .never) {
            return GuardianResult{
                .verdict = .block,
                .reason = std.fmt.allocPrint(self.allocator, "Operation '{s}' is blocked by governance policy", .{operation}) catch null,
                .hook_results = &.{},
            };
        }

        // Step 2: Check sensitive paths (if file_path provided)
        if (file_path) |fp| {
            if (self.path_checker.isSensitive(fp)) {
                return GuardianResult{
                    .verdict = .block,
                    .reason = std.fmt.allocPrint(self.allocator, "Path '{s}' is sensitive and protected", .{fp}) catch null,
                    .hook_results = &.{},
                };
            }
        }

        // Step 3: Execute pre_tool hooks
        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .pre_tool;
        ctx.tool_name = tool_name;
        ctx.file_path = file_path;

        const hook_results = self.executor.executePhase(.pre_tool, &ctx) catch &.{};

        // Check if any hook blocked the operation
        for (hook_results) |hr| {
            if (!hr.success) {
                return GuardianResult{
                    .verdict = .block,
                    .reason = std.fmt.allocPrint(self.allocator, "Hook '{s}' blocked the operation", .{hr.hook_name}) catch null,
                    .hook_results = hook_results,
                };
            }
        }

        // Return verdict based on governance zone
        return switch (zone) {
            .auto => GuardianResult{ .verdict = .allow, .reason = null, .hook_results = hook_results },
            .propose => GuardianResult{
                .verdict = .propose,
                .reason = std.fmt.allocPrint(self.allocator, "Operation '{s}' requires approval", .{operation}) catch null,
                .hook_results = hook_results,
            },
            .never => unreachable, // exhaustive switch: .never is handled in step 1 (sensitive path check)
        };
    }

    /// Fire post_tool hooks after tool execution completes.
    pub fn notifyPostTool(self: *Guardian, tool_name: []const u8, file_path: ?[]const u8) void {
        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .post_tool;
        ctx.tool_name = tool_name;
        ctx.file_path = file_path;

        const results = self.executor.executePhase(.post_tool, &ctx) catch return;
        freeHookResults(self.allocator, results);
    }

    /// Fire pre_edit hooks + sensitive path check before file edits.
    /// Returns true if the edit is allowed, false if blocked.
    pub fn notifyPreEdit(self: *Guardian, file_path: []const u8) bool {
        // Sensitive path check
        if (self.path_checker.isSensitive(file_path)) {
            return false;
        }

        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .pre_edit;
        ctx.file_path = file_path;

        const results = self.executor.executePhase(.pre_edit, &ctx) catch return true;
        defer freeHookResults(self.allocator, results);

        // Block if any hook failed
        for (results) |hr| {
            if (!hr.success) return false;
        }
        return true;
    }

    /// Fire post_edit hooks after a file edit completes.
    pub fn notifyPostEdit(self: *Guardian, file_path: []const u8) void {
        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .post_edit;
        ctx.file_path = file_path;

        const results = self.executor.executePhase(.post_edit, &ctx) catch return;
        freeHookResults(self.allocator, results);
    }

    /// Fire session_start hooks. Call after pipeline init, before first message.
    pub fn notifySessionStart(self: *Guardian, provider: []const u8, model: []const u8) void {
        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .session_start;
        ctx.provider = provider;
        ctx.model = model;

        const results = self.executor.executePhase(.session_start, &ctx) catch return;
        freeHookResults(self.allocator, results);
    }

    /// Fire session_end hooks. Call in the cleanup/defer block.
    pub fn notifySessionEnd(self: *Guardian) void {
        var ctx = HookContext.init(self.allocator);
        defer ctx.deinit();
        ctx.phase = .session_end;

        const results = self.executor.executePhase(.session_end, &ctx) catch return;
        freeHookResults(self.allocator, results);
    }

    /// Check if a path is sensitive. Delegates to SensitivePathChecker.
    pub fn isPathSensitive(self: *const Guardian, path: []const u8) bool {
        return self.path_checker.isSensitive(path);
    }

    /// Print a summary of guardian status — governance zones, sensitive
    /// patterns, and registered hooks.
    pub fn printStats(self: *Guardian) void {
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Guardian Pipeline Status ===\n", .{}) catch {};
        stdout.print("  Governance zones: {d} policies\n", .{self.governance.policies.count()}) catch {};
        stdout.print("  Sensitive patterns: {d}\n", .{self.path_checker.protected_patterns.items.len}) catch {};
        stdout.print("  Hook scripts: {d}\n", .{self.executor.scripts.items.len}) catch {};

        // Show sensitive patterns
        if (self.path_checker.protected_patterns.items.len > 0) {
            stdout.print("\n  Protected patterns:\n", .{}) catch {};
            for (self.path_checker.protected_patterns.items) |pattern| {
                stdout.print("    - {s}\n", .{pattern}) catch {};
            }
        }

        // Delegate to executor for detailed hook status
        if (self.executor.scripts.items.len > 0) {
            stdout.print("\n", .{}) catch {};
            self.executor.printStatus();
        } else {
            stdout.print("\n  No hook scripts registered.\n", .{}) catch {};
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Guardian init and deinit" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    guardian.deinit();
}

test "Guardian checkTool — auto zone allows" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    // "file_read" is in the auto zone by default
    var result = try guardian.checkTool("read_file", "read", null);
    defer result.deinit(allocator);
    defer freeHookResults(allocator, result.hook_results);

    try testing.expect(result.verdict == .allow);
    try testing.expect(result.reason == null);
}

test "Guardian checkTool — never zone blocks" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    // "file_delete" is in the never zone by default
    var result = try guardian.checkTool("delete", "file_delete", null);
    defer result.deinit(allocator);
    // hook_results is empty (&.{}), no free needed

    try testing.expect(result.verdict == .block);
    try testing.expect(result.reason != null);
    if (result.reason) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "blocked by governance") != null);
    }
}

test "Guardian checkTool — sensitive path blocks" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    // "file_write" is in the propose zone, but .env is sensitive
    var result = try guardian.checkTool("write_file", "file_write", ".env");
    defer result.deinit(allocator);
    // hook_results is empty, no free needed

    try testing.expect(result.verdict == .block);
    try testing.expect(result.reason != null);
    if (result.reason) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "sensitive") != null);
    }
}

test "Guardian checkTool — propose zone requires approval" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    // "file_write" is in the propose zone, and path is not sensitive
    var result = try guardian.checkTool("write_file", "file_write", "/tmp/test.txt");
    defer result.deinit(allocator);
    defer freeHookResults(allocator, result.hook_results);

    try testing.expect(result.verdict == .propose);
    try testing.expect(result.reason != null);
    if (result.reason) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "requires approval") != null);
    }
}

test "Guardian isPathSensitive" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    try testing.expect(guardian.isPathSensitive(".env"));
    try testing.expect(guardian.isPathSensitive("/home/user/.ssh/id_rsa"));
    try testing.expect(!guardian.isPathSensitive("/tmp/build_output.o"));
    try testing.expect(!guardian.isPathSensitive("README.md"));
}

test "Guardian printStats does not crash" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    guardian.printStats();
}

test "Guardian notifySessionStart does not crash" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    guardian.notifySessionStart("ollama", "llama3");
}

test "Guardian notifySessionEnd does not crash" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    guardian.notifySessionEnd();
}

test "Guardian notifyPostTool does not crash" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    guardian.notifyPostTool("shell", null);
}

test "Guardian notifyPreEdit — normal path allowed" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    const allowed = guardian.notifyPreEdit("/tmp/test.zig");
    try testing.expect(allowed == true);
}

test "Guardian notifyPreEdit — sensitive path blocked" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    const allowed = guardian.notifyPreEdit(".env");
    try testing.expect(allowed == false);
}

test "Guardian notifyPostEdit does not crash" {
    const allocator = std.testing.allocator;
    var guardian = try Guardian.init(allocator);
    defer guardian.deinit();

    guardian.notifyPostEdit("/tmp/test.zig");
}
