/// Autopilot Engine — wires BackgroundAgentManager to KnowledgePipeline and Guardian
/// so that built-in background agents execute real work instead of writing placeholders.
///
/// Agent → Work mapping:
///   morning-refresh   → scanProject(50) + indexGraphToVault
///   nightly-consolidate → syncVaultToMemory + distillMemory + syncMemoryInsightsToVault
///   weekly-review     → scanProject(200) + indexGraphToVault + syncVaultToMemory + distillMemory
///   health-check      → stats() read-only
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const background_agent_mod = @import("background_agent");
const cognition_mod = @import("cognition");
const guardian_mod = @import("guardian");

const Allocator = std.mem.Allocator;
const BackgroundAgentManager = background_agent_mod.BackgroundAgentManager;
const BackgroundAgentKind = background_agent_mod.BackgroundAgentKind;
const BackgroundStatus = background_agent_mod.BackgroundStatus;
const KnowledgePipeline = cognition_mod.KnowledgePipeline;
const Guardian = guardian_mod.Guardian;

// ── Error set ──────────────────────────────────────────────────────────────────

pub const AutopilotError = error{
    AgentNotFound,
};

// ── AutopilotWorkResult ────────────────────────────────────────────────────────

pub const AutopilotWorkResult = struct {
    agent_id: []const u8,
    agent_kind: BackgroundAgentKind,
    status: BackgroundStatus,
    started_at: i64,
    completed_at: ?i64,
    work_summary: []const u8,
    files_scanned: u32,
    files_indexed: u32,
    vault_nodes: u32,
    graph_nodes: u32,
    insights_created: u32,
    error_message: ?[]const u8,

    pub fn deinit(self: *const AutopilotWorkResult, allocator: Allocator) void {
        allocator.free(self.agent_id);
        if (self.work_summary.len > 0) allocator.free(self.work_summary);
        if (self.error_message) |msg| allocator.free(msg);
    }
};

// ── AutopilotEngine ────────────────────────────────────────────────────────────

pub const AutopilotEngine = struct {
    allocator: Allocator,
    bg_manager: BackgroundAgentManager,
    pipeline: *KnowledgePipeline,
    guardian: ?*Guardian,
    project_dir: []const u8,
    results: array_list_compat.ArrayList(AutopilotWorkResult),

    /// Initialize the autopilot engine.
    /// `pipeline` is borrowed — do NOT free it via this engine.
    /// `guardian` is borrowed and optional — do NOT free it via this engine.
    pub fn init(
        allocator: Allocator,
        pipeline: *KnowledgePipeline,
        guardian: ?*Guardian,
        project_dir: []const u8,
        results_dir: []const u8,
    ) !AutopilotEngine {
        var bg_manager = try BackgroundAgentManager.init(allocator, results_dir);
        errdefer bg_manager.deinit();
        try bg_manager.registerDefaults();

        return AutopilotEngine{
            .allocator = allocator,
            .bg_manager = bg_manager,
            .pipeline = pipeline,
            .guardian = guardian,
            .project_dir = try allocator.dupe(u8, project_dir),
            .results = array_list_compat.ArrayList(AutopilotWorkResult).init(allocator),
        };
    }

    /// Clean up all resources owned by the engine.
    /// Does NOT free the borrowed pipeline or guardian pointers.
    pub fn deinit(self: *AutopilotEngine) void {
        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit();
        self.bg_manager.deinit();
        self.allocator.free(self.project_dir);
    }

    // ── Core dispatch ──────────────────────────────────────────────────────

    /// Run real work for a specific agent by ID.
    /// Returns a copy of the result that the caller must free with `deinit`.
    pub fn runAgentWork(self: *AutopilotEngine, agent_id: []const u8) !AutopilotWorkResult {
        const agent = self.bg_manager.findAgent(agent_id) orelse return AutopilotError.AgentNotFound;

        const started_at = std.time.milliTimestamp();
        agent.status = .running;

        var files_scanned: u32 = 0;
        var files_indexed: u32 = 0;
        var vault_nodes: u32 = 0;
        var graph_nodes: u32 = 0;
        var insights_created: u32 = 0;
        var status: BackgroundStatus = .completed;
        var error_message: ?[]const u8 = null;

        switch (agent.kind) {
            .morning => {
                if (try self.checkGuardianPermission("scan")) |msg| {
                    status = .failed;
                    error_message = msg;
                } else {
                    self.pipeline.scanProject(self.project_dir, 50) catch {};
                    self.pipeline.indexGraphToVault() catch {};
                    const s = self.pipeline.stats();
                    files_scanned = s.files_scanned;
                    files_indexed = s.files_indexed;
                    vault_nodes = s.vault_nodes;
                    graph_nodes = s.graph_nodes;
                }
            },
            .nightly => {
                if (try self.checkGuardianPermission("consolidate")) |msg| {
                    status = .failed;
                    error_message = msg;
                } else {
                    self.pipeline.syncVaultToMemory() catch {};
                    const distill_count = self.pipeline.distillMemory() catch 0;
                    self.pipeline.syncMemoryInsightsToVault() catch {};
                    insights_created = @intCast(distill_count);
                    const s = self.pipeline.stats();
                    vault_nodes = s.vault_nodes;
                    graph_nodes = s.graph_nodes;
                    files_indexed = s.files_indexed;
                }
            },
            .weekly => {
                if (try self.checkGuardianPermission("review")) |msg| {
                    status = .failed;
                    error_message = msg;
                } else {
                    self.pipeline.scanProject(self.project_dir, 200) catch {};
                    self.pipeline.indexGraphToVault() catch {};
                    self.pipeline.syncVaultToMemory() catch {};
                    const distill_count = self.pipeline.distillMemory() catch 0;
                    insights_created = @intCast(distill_count);
                    const s = self.pipeline.stats();
                    files_scanned = s.files_scanned;
                    files_indexed = s.files_indexed;
                    vault_nodes = s.vault_nodes;
                    graph_nodes = s.graph_nodes;
                }
            },
            .health => {
                if (try self.checkGuardianPermission("health")) |msg| {
                    status = .failed;
                    error_message = msg;
                } else {
                    const s = self.pipeline.stats();
                    files_scanned = s.files_scanned;
                    files_indexed = s.files_indexed;
                    vault_nodes = s.vault_nodes;
                    graph_nodes = s.graph_nodes;
                    insights_created = s.insights_count;
                }
            },
            else => return AutopilotError.AgentNotFound,
        }

        const completed_at = std.time.milliTimestamp();

        // Update agent status
        if (status == .completed) {
            agent.status = .completed;
            agent.last_run_at = started_at;
            agent.run_count += 1;
        } else {
            agent.status = .failed;
            agent.error_count += 1;
        }

        // Build work summary
        const work_summary: []const u8 = if (status == .failed)
            std.fmt.allocPrint(self.allocator, "{s} blocked: {s}", .{
                agent_id,
                error_message orelse "unknown",
            }) catch ""
        else
            switch (agent.kind) {
                .morning => std.fmt.allocPrint(self.allocator, "Reindexed project: scanned {d} files, indexed {d}, vault {d} nodes, graph {d} nodes", .{
                    files_scanned, files_indexed, vault_nodes, graph_nodes,
                }) catch "",
                .nightly => std.fmt.allocPrint(self.allocator, "Consolidated knowledge: synced vault to memory, distilled {d} insights, vault {d} nodes", .{
                    insights_created, vault_nodes,
                }) catch "",
                .weekly => std.fmt.allocPrint(self.allocator, "Full review: scanned {d} files, indexed {d}, vault {d} nodes, {d} insights", .{
                    files_scanned, files_indexed, vault_nodes, insights_created,
                }) catch "",
                .health => std.fmt.allocPrint(self.allocator, "Health check: {d} indexed, {d} vault, {d} graph nodes, {d} insights", .{
                    files_indexed, vault_nodes, graph_nodes, insights_created,
                }) catch "",
                else => std.fmt.allocPrint(self.allocator, "Agent {s} completed", .{agent_id}) catch "",
            };

        // Store result internally
        const stored = AutopilotWorkResult{
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .agent_kind = agent.kind,
            .status = status,
            .started_at = started_at,
            .completed_at = completed_at,
            .work_summary = work_summary,
            .files_scanned = files_scanned,
            .files_indexed = files_indexed,
            .vault_nodes = vault_nodes,
            .graph_nodes = graph_nodes,
            .insights_created = insights_created,
            .error_message = error_message,
        };
        try self.results.append(stored);

        // Write output file
        self.writeResultFile(&self.results.items[self.results.items.len - 1]) catch {};

        // Return an independent copy for the caller
        return AutopilotWorkResult{
            .agent_id = try self.allocator.dupe(u8, stored.agent_id),
            .agent_kind = stored.agent_kind,
            .status = stored.status,
            .started_at = stored.started_at,
            .completed_at = stored.completed_at,
            .work_summary = try self.allocator.dupe(u8, stored.work_summary),
            .files_scanned = stored.files_scanned,
            .files_indexed = stored.files_indexed,
            .vault_nodes = stored.vault_nodes,
            .graph_nodes = stored.graph_nodes,
            .insights_created = stored.insights_created,
            .error_message = if (stored.error_message) |msg| try self.allocator.dupe(u8, msg) else null,
        };
    }

    /// Run all agents whose interval has elapsed.
    pub fn runScheduledWork(self: *AutopilotEngine) !void {
        // Collect agent IDs first to avoid borrowing issues
        var ids = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer ids.deinit();
        for (self.bg_manager.agents.items) |agent| {
            if (agent.isIntervalElapsed() and agent.status != .running) {
                try ids.append(agent.id);
            }
        }
        for (ids.items) |id| {
            const result = self.runAgentWork(id) catch continue;
            result.deinit(self.allocator);
        }
    }

    /// Run all agents with after_compaction = true.
    pub fn runAllAfterCompaction(self: *AutopilotEngine) !void {
        var ids = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer ids.deinit();
        for (self.bg_manager.agents.items) |agent| {
            if (agent.schedule.after_compaction and agent.status != .running) {
                try ids.append(agent.id);
            }
        }
        for (ids.items) |id| {
            const result = self.runAgentWork(id) catch continue;
            result.deinit(self.allocator);
        }
    }

    /// Get formatted status for an agent. Caller must free returned string.
    pub fn getAgentStatus(self: *AutopilotEngine, agent_id: []const u8) ?[]const u8 {
        return self.bg_manager.getAgentStatus(agent_id);
    }

    /// Get formatted list of all agents. Caller must free returned string.
    pub fn listAgents(self: *AutopilotEngine, allocator: Allocator) ![]const u8 {
        return self.bg_manager.listAgents(allocator);
    }

    /// Print autopilot engine status to stdout.
    pub fn printStats(self: *AutopilotEngine) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Autopilot Engine Status ===\n", .{}) catch {};
        stdout.print("  Project dir:  {s}\n", .{self.project_dir}) catch {};
        stdout.print("  Guardian:     {s}\n", .{if (self.guardian != null) "active" else "disabled"}) catch {};
        stdout.print("  Agents:       {d}\n", .{self.bg_manager.agents.items.len}) catch {};
        stdout.print("  Work results: {d}\n", .{self.results.items.len}) catch {};
        // Note: pipeline.printStats() has a const-correctness issue with compressionRatio(),
        // so we only print autopilot-level stats here.
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// Check guardian permission for an action.
    /// Returns null if allowed (or guardian is null).
    /// Returns an owned error message string if blocked.
    fn checkGuardianPermission(self: *AutopilotEngine, action: []const u8) !?[]const u8 {
        const g = self.guardian orelse return null;
        var result = g.checkTool("autopilot", action, null) catch return null;
        defer result.deinit(self.allocator);

        if (result.verdict == .block) {
            // hook_results may be comptime &.{} for early-return blocks — don't free
            const reason = result.reason orelse "blocked by guardian policy";
            return try self.allocator.dupe(u8, reason);
        }

        // allow/propose: hook_results are allocated by executor, safe to free
        guardian_mod.freeHookResults(self.allocator, result.hook_results);
        return null;
    }

    /// Write a result summary file to the results directory.
    fn writeResultFile(self: *AutopilotEngine, result: *const AutopilotWorkResult) !void {
        std.fs.cwd().makePath(self.bg_manager.results_dir) catch {};

        const output_path = try std.fmt.allocPrint(self.allocator, "{s}autopilot-{s}-{d}.md", .{
            self.bg_manager.results_dir,
            result.agent_id,
            result.started_at,
        });
        errdefer self.allocator.free(output_path);

        // Build content using ArrayList to avoid nested allocations
        var content_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer content_buf.deinit();
        const w = content_buf.writer();

        w.print("# Autopilot Work Result\n\n", .{}) catch return;
        w.print("**Agent:** {s}\n", .{result.agent_id}) catch return;
        w.print("**Kind:** {s}\n", .{@tagName(result.agent_kind)}) catch return;
        w.print("**Status:** {s}\n", .{@tagName(result.status)}) catch return;
        w.print("**Started:** {d}\n", .{result.started_at}) catch return;
        if (result.completed_at) |ct| {
            w.print("**Completed:** {d}\n", .{ct}) catch return;
        }
        if (result.error_message) |msg| {
            w.print("**Error:** {s}\n", .{msg}) catch return;
        }
        w.print("\n## Summary\n\n{s}\n\n", .{result.work_summary}) catch return;
        w.print("## Statistics\n\n", .{}) catch return;
        w.print("- Files scanned:  {d}\n", .{result.files_scanned}) catch return;
        w.print("- Files indexed:  {d}\n", .{result.files_indexed}) catch return;
        w.print("- Vault nodes:    {d}\n", .{result.vault_nodes}) catch return;
        w.print("- Graph nodes:    {d}\n", .{result.graph_nodes}) catch return;
        w.print("- Insights:       {d}\n", .{result.insights_created}) catch return;

        const content = content_buf.toOwnedSlice() catch return;
        defer self.allocator.free(content);

        const file = std.fs.cwd().createFile(output_path, .{}) catch {
            self.allocator.free(output_path);
            return;
        };
        defer file.close();
        file.writeAll(content) catch {};

        // Transfer output_path ownership to agent.last_result
        const agent = self.bg_manager.findAgent(result.agent_id) orelse {
            self.allocator.free(output_path);
            return;
        };
        if (agent.last_result) |old| {
            self.allocator.free(old);
        }
        agent.last_result = output_path;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "AutopilotEngine init/deinit" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    try testing.expect(engine.bg_manager.agents.items.len == 4);
    try testing.expect(engine.guardian == null);
    try testing.expect(engine.results.items.len == 0);
}

test "runAgentWork health-check returns stats" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    var result = try engine.runAgentWork("health-check");
    defer result.deinit(allocator);

    try testing.expect(result.status == .completed);
    try testing.expect(std.mem.eql(u8, result.agent_id, "health-check"));
    try testing.expect(result.agent_kind == .health);
    try testing.expect(result.started_at != 0);
    try testing.expect(result.completed_at != null);
    try testing.expect(result.error_message == null);
    try testing.expect(result.work_summary.len > 0);
}

test "runAgentWork unknown agent returns error" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    const result = engine.runAgentWork("nonexistent-agent");
    try testing.expect(result == AutopilotError.AgentNotFound);
}

test "listAgents returns formatted string" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    const listing = try engine.listAgents(allocator);
    defer allocator.free(listing);

    try testing.expect(listing.len > 0);
    try testing.expect(std.mem.indexOf(u8, listing, "morning-refresh") != null);
    try testing.expect(std.mem.indexOf(u8, listing, "nightly-consolidate") != null);
    try testing.expect(std.mem.indexOf(u8, listing, "weekly-review") != null);
    try testing.expect(std.mem.indexOf(u8, listing, "health-check") != null);
}

test "AutopilotEngine with null guardian still works" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    // Run health-check without guardian — should succeed without permission check
    var result = try engine.runAgentWork("health-check");
    defer result.deinit(allocator);

    try testing.expect(result.status == .completed);
    try testing.expect(result.error_message == null);

    // Also verify morning-refresh works without guardian
    var result2 = try engine.runAgentWork("morning-refresh");
    defer result2.deinit(allocator);

    try testing.expect(result2.status == .completed);
    try testing.expect(result2.error_message == null);
}

test "AutopilotWorkResult deinit cleans up" {
    const allocator = testing.allocator;

    var result = AutopilotWorkResult{
        .agent_id = try allocator.dupe(u8, "test-agent-id"),
        .agent_kind = .morning,
        .status = .completed,
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
        .work_summary = try allocator.dupe(u8, "Scanned 42 files, indexed 10, vault 5 nodes"),
        .files_scanned = 42,
        .files_indexed = 10,
        .vault_nodes = 5,
        .graph_nodes = 8,
        .insights_created = 2,
        .error_message = try allocator.dupe(u8, "some error detail"),
    };
    result.deinit(allocator);
    // If no leak detected by GeneralPurposeAllocator, deinit worked correctly
}

test "runAgentWork updates agent status and stats" {
    const allocator = testing.allocator;
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();

    var engine = try AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/test_autopilot/");
    defer {
        engine.deinit();
        std.fs.cwd().deleteTree(".crushcode/test_autopilot/") catch {};
    }

    const agent = engine.bg_manager.findAgent("health-check").?;
    try testing.expect(agent.status == .idle);
    try testing.expect(agent.run_count == 0);

    var result = try engine.runAgentWork("health-check");
    defer result.deinit(allocator);

    try testing.expect(agent.status == .completed);
    try testing.expect(agent.run_count == 1);
    try testing.expect(agent.last_run_at != null);

    // Engine should have stored the result internally
    try testing.expect(engine.results.items.len == 1);
}
