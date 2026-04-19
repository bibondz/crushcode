const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ── Local type definitions ──────────────────────────────────────────────────────

/// Risk tier for tool classification.
/// Re-defined locally from tool_classifier.zig to avoid cross-module dependency
/// on the full permission module chain.
pub const ToolRiskTier = enum {
    read,
    write,
    destructive,
};

/// Agent category for task delegation.
/// Re-defined locally from parallel.zig to avoid circular dependency.
pub const AgentCategory = enum {
    visual_engineering,
    ultrabrain,
    deep,
    quick,
    general,
    review,
    research,
};

// ── Tool classification data ────────────────────────────────────────────────────

const read_tool_names = [_][]const u8{
    "read_file",
    "glob",
    "grep",
    "list_directory",
    "file_info",
    "git_status",
    "git_diff",
    "git_log",
    "search_files",
};

const write_tool_names = [_][]const u8{
    "write_file",
    "create_file",
    "edit",
    "move_file",
    "copy_file",
};

const destructive_tool_names = [_][]const u8{
    "delete_file",
    "shell",
};

const all_tool_names = read_tool_names ++ write_tool_names ++ destructive_tool_names;

const safe_tool_names = read_tool_names ++ write_tool_names;

const tier_all = [_]ToolRiskTier{ .read, .write, .destructive };
const tier_rw = [_]ToolRiskTier{ .read, .write };
const tier_read_only = [_]ToolRiskTier{.read};

/// Classify a tool into its risk tier.
/// Mirrors tool_classifier.classifyTool — returns .destructive for unknown tools (fail-safe).
fn classifyTool(tool_name: []const u8) ToolRiskTier {
    for (&read_tool_names) |name| {
        if (std.mem.eql(u8, name, tool_name)) return .read;
    }
    for (&write_tool_names) |name| {
        if (std.mem.eql(u8, name, tool_name)) return .write;
    }
    for (&destructive_tool_names) |name| {
        if (std.mem.eql(u8, name, tool_name)) return .destructive;
    }
    return .destructive;
}

// ── DelegationResult ────────────────────────────────────────────────────────────

/// Result from a sub-agent delegation.
/// Contains the task outcome, depth level, and execution metrics.
/// Caller owns strings and must call deinit().
pub const DelegationResult = struct {
    /// Unique task identifier (e.g., "delegated-1-research")
    task_id: []const u8,
    /// Whether the delegated task completed successfully
    success: bool,
    /// Output or summary from the sub-agent execution
    output: []const u8,
    /// Depth level of this delegation (1 = first sub-agent, 2 = second-level)
    depth: u32,
    /// Number of tool calls made during execution
    tools_used: u32,
    /// Wall-clock duration of the delegation in milliseconds
    duration_ms: u64,
    /// Error message if the delegation failed
    error_message: ?[]const u8,

    /// Free all owned strings.
    pub fn deinit(self: *DelegationResult, allocator: Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.output);
        if (self.error_message) |msg| allocator.free(msg);
    }
};

// ── DelegationConfig ────────────────────────────────────────────────────────────

/// Configuration for sub-agent spawning.
/// Controls recursion depth, concurrency, and tool budget.
pub const DelegationConfig = struct {
    /// Maximum recursion depth (default: 2, meaning sub-agents can nest one level deep)
    max_depth: u32,
    /// Maximum number of concurrent sub-agents (default: 3)
    max_concurrent: u32,
    /// Maximum number of tool calls allowed per depth level (default: 10)
    max_tools_per_depth: u32,
    /// Allocator for internal allocations
    allocator: Allocator,

    /// Create a DelegationConfig with sensible defaults.
    pub fn init(allocator: Allocator) DelegationConfig {
        return .{
            .max_depth = 2,
            .max_concurrent = 3,
            .max_tools_per_depth = 10,
            .allocator = allocator,
        };
    }
};

// ── DepthToolPolicy ─────────────────────────────────────────────────────────────

/// Restricted tool set for a given depth.
/// Depth 0 (main agent): all tools (read + write + destructive)
/// Depth 1 (first sub-agent): safe tools only (read + write, no shell/delete)
/// Depth 2+ (deeper sub-agents): read-only tools
pub const DepthToolPolicy = struct {
    /// The depth this policy applies to
    depth: u32,
    /// Risk tiers allowed at this depth
    allowed_tiers: []const ToolRiskTier,

    /// Get the tool policy for a specific depth level.
    pub fn forDepth(depth: u32) DepthToolPolicy {
        if (depth == 0) {
            return .{ .depth = depth, .allowed_tiers = &tier_all };
        } else if (depth == 1) {
            return .{ .depth = depth, .allowed_tiers = &tier_rw };
        } else {
            return .{ .depth = depth, .allowed_tiers = &tier_read_only };
        }
    }

    /// Check if a specific tool is allowed under this policy.
    pub fn isToolAllowed(self: *const DepthToolPolicy, tool_name: []const u8) bool {
        const tier = classifyTool(tool_name);
        for (self.allowed_tiers) |allowed| {
            if (tier == allowed) return true;
        }
        return false;
    }
};

// ── SubAgentDelegator ───────────────────────────────────────────────────────────

/// Manages spawning and tracking of sub-agents with depth-based restrictions.
/// Provides depth limiting, concurrent slot management, and restricted tool policies.
pub const SubAgentDelegator = struct {
    allocator: Allocator,
    config: DelegationConfig,
    active_count: u32,
    total_completed: u32,
    total_failed: u32,
    results: array_list_compat.ArrayList(DelegationResult),
    next_task_id: u32,

    /// Initialize a new SubAgentDelegator with the given configuration.
    pub fn init(allocator: Allocator, config: DelegationConfig) SubAgentDelegator {
        return .{
            .allocator = allocator,
            .config = config,
            .active_count = 0,
            .total_completed = 0,
            .total_failed = 0,
            .results = array_list_compat.ArrayList(DelegationResult).init(allocator),
            .next_task_id = 1,
        };
    }

    /// Free all stored delegation results and internal state.
    pub fn deinit(self: *SubAgentDelegator) void {
        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit();
    }

    /// Check if a new delegation can be spawned at the given depth.
    /// Returns false if depth exceeds max_depth or concurrent slots are full.
    pub fn canDelegate(self: *const SubAgentDelegator, current_depth: u32) bool {
        if (current_depth >= self.config.max_depth) return false;
        if (self.active_count >= self.config.max_concurrent) return false;
        return true;
    }

    /// Spawn a sub-agent task (synchronous simulation).
    /// Increments active_count, creates a DelegationResult, and tracks the delegation.
    /// The returned DelegationResult is owned by the caller and must be freed with deinit().
    /// A copy is also stored internally and freed when SubAgentDelegator.deinit() is called.
    pub fn delegate(
        self: *SubAgentDelegator,
        current_depth: u32,
        task_description: []const u8,
        category: AgentCategory,
    ) !DelegationResult {
        if (current_depth >= self.config.max_depth)
            return error.MaxDepthExceeded;
        if (self.active_count >= self.config.max_concurrent)
            return error.MaxConcurrentReached;

        self.active_count += 1;
        errdefer self.active_count -= 1;

        const start_time = std.time.milliTimestamp();
        const target_depth = current_depth + 1;

        // Generate unique task ID
        const task_id = try std.fmt.allocPrint(
            self.allocator,
            "delegated-{d}-{s}",
            .{ self.next_task_id, @tagName(category) },
        );
        self.next_task_id += 1;

        // Simulated delegation output
        const output = try std.fmt.allocPrint(
            self.allocator,
            "[delegated:{s}] depth={d} {s}",
            .{ @tagName(category), target_depth, task_description },
        );

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

        const stored = DelegationResult{
            .task_id = task_id,
            .success = true,
            .output = output,
            .depth = target_depth,
            .tools_used = 0,
            .duration_ms = duration,
            .error_message = null,
        };

        try self.results.append(stored);
        self.active_count -= 1;
        self.total_completed += 1;

        // Return an owned copy to the caller
        return DelegationResult{
            .task_id = try self.allocator.dupe(u8, stored.task_id),
            .success = stored.success,
            .output = try self.allocator.dupe(u8, stored.output),
            .depth = stored.depth,
            .tools_used = stored.tools_used,
            .duration_ms = stored.duration_ms,
            .error_message = null,
        };
    }

    /// Get allowed tools for a given depth level.
    /// Depth 0: all 16 tools
    /// Depth 1: read + write tools (14 tools, no shell/delete)
    /// Depth 2+: read-only tools (9 tools)
    pub fn getAllowedTools(self: *const SubAgentDelegator, depth: u32) []const []const u8 {
        _ = self;
        if (depth == 0) {
            return &all_tool_names;
        } else if (depth == 1) {
            return &safe_tool_names;
        } else {
            return &read_tool_names;
        }
    }

    /// Check if a specific tool is allowed at a given depth.
    pub fn isToolAllowedAtDepth(self: *const SubAgentDelegator, tool_name: []const u8, depth: u32) bool {
        _ = self;
        const policy = DepthToolPolicy.forDepth(depth);
        return policy.isToolAllowed(tool_name);
    }

    /// Get a formatted stats string about delegation activity.
    /// Caller owns the returned string and must free it.
    pub fn getStats(self: *SubAgentDelegator, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const writer = buf.writer();
        writer.print("=== Sub-Agent Delegation Stats ===\n", .{}) catch {};
        writer.print("  Active: {d}\n", .{self.active_count}) catch {};
        writer.print("  Completed: {d}\n", .{self.total_completed}) catch {};
        writer.print("  Failed: {d}\n", .{self.total_failed}) catch {};
        writer.print("  Max depth: {d}\n", .{self.config.max_depth}) catch {};
        writer.print("  Max concurrent: {d}\n", .{self.config.max_concurrent}) catch {};
        writer.print("  Results stored: {d}\n", .{self.results.items.len}) catch {};

        return buf.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Get all stored delegation results.
    pub fn getResults(self: *const SubAgentDelegator) []const DelegationResult {
        return self.results.items;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "DelegationConfig - default values" {
    const config = DelegationConfig.init(testing.allocator);
    try testing.expectEqual(@as(u32, 2), config.max_depth);
    try testing.expectEqual(@as(u32, 3), config.max_concurrent);
    try testing.expectEqual(@as(u32, 10), config.max_tools_per_depth);
}

test "DepthToolPolicy - forDepth returns correct tiers" {
    const policy0 = DepthToolPolicy.forDepth(0);
    try testing.expectEqual(@as(u32, 0), policy0.depth);
    try testing.expectEqual(@as(usize, 3), policy0.allowed_tiers.len);

    const policy1 = DepthToolPolicy.forDepth(1);
    try testing.expectEqual(@as(u32, 1), policy1.depth);
    try testing.expectEqual(@as(usize, 2), policy1.allowed_tiers.len);

    const policy2 = DepthToolPolicy.forDepth(2);
    try testing.expectEqual(@as(u32, 2), policy2.depth);
    try testing.expectEqual(@as(usize, 1), policy2.allowed_tiers.len);

    // All depths >= 2 should behave the same
    const policy5 = DepthToolPolicy.forDepth(5);
    try testing.expectEqual(@as(usize, 1), policy5.allowed_tiers.len);
}

test "DepthToolPolicy - isToolAllowed enforces depth restrictions" {
    // Depth 0: all tools allowed
    const policy0 = DepthToolPolicy.forDepth(0);
    try testing.expect(policy0.isToolAllowed("read_file"));
    try testing.expect(policy0.isToolAllowed("write_file"));
    try testing.expect(policy0.isToolAllowed("shell"));
    try testing.expect(policy0.isToolAllowed("delete_file"));

    // Depth 1: read + write allowed, destructive blocked
    const policy1 = DepthToolPolicy.forDepth(1);
    try testing.expect(policy1.isToolAllowed("read_file"));
    try testing.expect(policy1.isToolAllowed("grep"));
    try testing.expect(policy1.isToolAllowed("edit"));
    try testing.expect(policy1.isToolAllowed("create_file"));
    try testing.expect(!policy1.isToolAllowed("shell"));
    try testing.expect(!policy1.isToolAllowed("delete_file"));

    // Depth 2: read only
    const policy2 = DepthToolPolicy.forDepth(2);
    try testing.expect(policy2.isToolAllowed("read_file"));
    try testing.expect(policy2.isToolAllowed("glob"));
    try testing.expect(policy2.isToolAllowed("git_log"));
    try testing.expect(!policy2.isToolAllowed("write_file"));
    try testing.expect(!policy2.isToolAllowed("edit"));
    try testing.expect(!policy2.isToolAllowed("shell"));
    try testing.expect(!policy2.isToolAllowed("delete_file"));

    // Unknown tools: treated as destructive, blocked at depth > 0
    try testing.expect(!policy1.isToolAllowed("unknown_tool"));
    try testing.expect(!policy2.isToolAllowed("unknown_tool"));
}

test "SubAgentDelegator - depth limiting" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    // Depth 0 delegation should succeed (creates sub-agent at depth 1)
    var result1 = try delegator.delegate(0, "Research Zig stdlib", .research);
    defer result1.deinit(allocator);
    try testing.expect(result1.success);
    try testing.expectEqual(@as(u32, 1), result1.depth);
    try testing.expectEqualStrings("delegated-1-research", result1.task_id);

    // Depth 1 delegation should succeed (creates sub-agent at depth 2)
    var result2 = try delegator.delegate(1, "Quick fix typo", .quick);
    defer result2.deinit(allocator);
    try testing.expect(result2.success);
    try testing.expectEqual(@as(u32, 2), result2.depth);
    try testing.expectEqualStrings("delegated-2-quick", result2.task_id);

    // Depth 2 delegation should fail (max_depth = 2)
    try testing.expectError(error.MaxDepthExceeded, delegator.delegate(2, "Should fail", .general));

    // Depth 3 should also fail
    try testing.expectError(error.MaxDepthExceeded, delegator.delegate(3, "Also fails", .deep));

    // canDelegate should reflect the same logic
    try testing.expect(delegator.canDelegate(0));
    try testing.expect(delegator.canDelegate(1));
    try testing.expect(!delegator.canDelegate(2));
}

test "SubAgentDelegator - concurrent limits" {
    const allocator = testing.allocator;
    var config = DelegationConfig.init(allocator);
    config.max_concurrent = 2;
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    // Normal delegation works fine
    var r1 = try delegator.delegate(0, "Task A", .general);
    defer r1.deinit(allocator);
    try testing.expect(r1.success);

    var r2 = try delegator.delegate(0, "Task B", .general);
    defer r2.deinit(allocator);
    try testing.expect(r2.success);

    // After completion, active_count is 0 again so another delegation works
    var r3 = try delegator.delegate(0, "Task C", .general);
    defer r3.deinit(allocator);
    try testing.expect(r3.success);

    // Simulate active_count being at max by setting it directly
    delegator.active_count = config.max_concurrent;
    try testing.expect(!delegator.canDelegate(0));
    try testing.expectError(error.MaxConcurrentReached, delegator.delegate(0, "Blocked", .general));
    delegator.active_count = 0;
}

test "SubAgentDelegator - getStats formatting" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    var r1 = try delegator.delegate(0, "Task 1", .research);
    defer r1.deinit(allocator);
    var r2 = try delegator.delegate(1, "Task 2", .quick);
    defer r2.deinit(allocator);

    const stats = try delegator.getStats(allocator);
    defer allocator.free(stats);

    try testing.expect(stats.len > 0);
    try testing.expect(std.mem.indexOf(u8, stats, "Sub-Agent Delegation Stats") != null);
    try testing.expect(std.mem.indexOf(u8, stats, "Completed: 2") != null);
    try testing.expect(std.mem.indexOf(u8, stats, "Failed: 0") != null);
    try testing.expect(std.mem.indexOf(u8, stats, "Max depth: 2") != null);
    try testing.expect(std.mem.indexOf(u8, stats, "Max concurrent: 3") != null);
    try testing.expect(std.mem.indexOf(u8, stats, "Results stored: 2") != null);
}

test "SubAgentDelegator - result tracking and getResults" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    // Delegate three tasks
    var r1 = try delegator.delegate(0, "First task", .general);
    defer r1.deinit(allocator);
    var r2 = try delegator.delegate(0, "Second task", .deep);
    defer r2.deinit(allocator);
    var r3 = try delegator.delegate(1, "Third task", .review);
    defer r3.deinit(allocator);

    // Verify individual results
    try testing.expect(r1.success);
    try testing.expectEqual(@as(u32, 1), r1.depth);
    try testing.expect(std.mem.indexOf(u8, r1.output, "First task") != null);

    try testing.expect(r2.success);
    try testing.expectEqual(@as(u32, 1), r2.depth);
    try testing.expect(std.mem.indexOf(u8, r2.output, "Second task") != null);

    try testing.expect(r3.success);
    try testing.expectEqual(@as(u32, 2), r3.depth);
    try testing.expect(std.mem.indexOf(u8, r3.output, "Third task") != null);

    // Verify stored results
    const results = delegator.getResults();
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqual(@as(u32, 3), delegator.total_completed);
    try testing.expectEqual(@as(u32, 0), delegator.total_failed);
}

test "SubAgentDelegator - getAllowedTools returns correct tool sets" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    // Depth 0: all 16 tools
    const depth0 = delegator.getAllowedTools(0);
    try testing.expectEqual(@as(usize, 16), depth0.len);

    // Depth 1: 14 safe tools (9 read + 5 write)
    const depth1 = delegator.getAllowedTools(1);
    try testing.expectEqual(@as(usize, 14), depth1.len);

    // Depth 2: 9 read-only tools
    const depth2 = delegator.getAllowedTools(2);
    try testing.expectEqual(@as(usize, 9), depth2.len);

    // Verify specific tool presence at each depth
    // Depth 0 should contain "shell"
    var found_shell_depth0 = false;
    for (depth0) |tool| {
        if (std.mem.eql(u8, tool, "shell")) found_shell_depth0 = true;
    }
    try testing.expect(found_shell_depth0);

    // Depth 1 should NOT contain "shell"
    var found_shell_depth1 = false;
    for (depth1) |tool| {
        if (std.mem.eql(u8, tool, "shell")) found_shell_depth1 = true;
    }
    try testing.expect(!found_shell_depth1);

    // Depth 2 should NOT contain "write_file"
    var found_write_depth2 = false;
    for (depth2) |tool| {
        if (std.mem.eql(u8, tool, "write_file")) found_write_depth2 = true;
    }
    try testing.expect(!found_write_depth2);
}

test "SubAgentDelegator - isToolAllowedAtDepth" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    // Depth 0: everything allowed
    try testing.expect(delegator.isToolAllowedAtDepth("read_file", 0));
    try testing.expect(delegator.isToolAllowedAtDepth("edit", 0));
    try testing.expect(delegator.isToolAllowedAtDepth("shell", 0));

    // Depth 1: read + write, no destructive
    try testing.expect(delegator.isToolAllowedAtDepth("read_file", 1));
    try testing.expect(delegator.isToolAllowedAtDepth("write_file", 1));
    try testing.expect(!delegator.isToolAllowedAtDepth("shell", 1));
    try testing.expect(!delegator.isToolAllowedAtDepth("delete_file", 1));

    // Depth 2: read only
    try testing.expect(delegator.isToolAllowedAtDepth("read_file", 2));
    try testing.expect(delegator.isToolAllowedAtDepth("grep", 2));
    try testing.expect(!delegator.isToolAllowedAtDepth("edit", 2));
    try testing.expect(!delegator.isToolAllowedAtDepth("shell", 2));
}

test "SubAgentDelegator - sequential task IDs" {
    const allocator = testing.allocator;
    const config = DelegationConfig.init(allocator);
    var delegator = SubAgentDelegator.init(allocator, config);
    defer delegator.deinit();

    var r1 = try delegator.delegate(0, "Task A", .research);
    defer r1.deinit(allocator);
    var r2 = try delegator.delegate(0, "Task B", .quick);
    defer r2.deinit(allocator);
    var r3 = try delegator.delegate(0, "Task C", .deep);
    defer r3.deinit(allocator);

    try testing.expectEqualStrings("delegated-1-research", r1.task_id);
    try testing.expectEqualStrings("delegated-2-quick", r2.task_id);
    try testing.expectEqualStrings("delegated-3-deep", r3.task_id);
}

test "classifyTool - mirrors tool_classifier behavior" {
    // Read tools
    try testing.expect(classifyTool("read_file") == .read);
    try testing.expect(classifyTool("glob") == .read);
    try testing.expect(classifyTool("grep") == .read);
    try testing.expect(classifyTool("list_directory") == .read);
    try testing.expect(classifyTool("file_info") == .read);
    try testing.expect(classifyTool("git_status") == .read);
    try testing.expect(classifyTool("git_diff") == .read);
    try testing.expect(classifyTool("git_log") == .read);
    try testing.expect(classifyTool("search_files") == .read);

    // Write tools
    try testing.expect(classifyTool("write_file") == .write);
    try testing.expect(classifyTool("create_file") == .write);
    try testing.expect(classifyTool("edit") == .write);
    try testing.expect(classifyTool("move_file") == .write);
    try testing.expect(classifyTool("copy_file") == .write);

    // Destructive tools
    try testing.expect(classifyTool("delete_file") == .destructive);
    try testing.expect(classifyTool("shell") == .destructive);

    // Unknown tools: fail-safe to destructive
    try testing.expect(classifyTool("unknown") == .destructive);
    try testing.expect(classifyTool("") == .destructive);
}
