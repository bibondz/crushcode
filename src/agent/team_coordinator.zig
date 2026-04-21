/// LiveAgentTeam — parallel agent execution with real AI calls.
///
/// Manages a team of agent slots that can run tasks concurrently using
/// std.Thread for parallelism. Each agent slot tracks its own task,
/// status, result, and token/cost usage.
///
/// Used by the TUI `/team` commands and the orchestration engine.

const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ── Enums ──────────────────────────────────────────────────────────────────────

pub const AgentStatus = enum {
    idle,
    running,
    done,
    failed,
    cancelled,
};

// ── Result Types ───────────────────────────────────────────────────────────────

pub const TeamResult = struct {
    agent_id: u32,
    agent_name: []const u8,
    task_prompt: []const u8,
    status: AgentStatus,
    output: []const u8,
    token_usage: u64,
    cost: f64,
    duration_ms: u64,

    pub fn deinit(self: *const TeamResult, allocator: Allocator) void {
        allocator.free(self.agent_name);
        allocator.free(self.task_prompt);
        allocator.free(self.output);
    }
};

// ── Agent Slot ─────────────────────────────────────────────────────────────────

pub const AgentSlot = struct {
    id: u32,
    name: []const u8,
    task: ?[]const u8,
    model: ?[]const u8,
    context: []const u8,
    status: AgentStatus,
    result: ?[]const u8,
    token_usage: u64,
    cost: f64,
    thread: ?std.Thread,

    pub fn deinit(self: *AgentSlot, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.task) |t| allocator.free(t);
        if (self.model) |m| allocator.free(m);
        allocator.free(self.context);
        if (self.result) |r| allocator.free(r);
    }
};

// ── Thread Context ─────────────────────────────────────────────────────────────

/// Context passed to each worker thread. Contains all info needed
/// to make an AI call and write back results to the agent slot.
pub const ThreadContext = struct {
    allocator: Allocator,
    slot: *AgentSlot,
    /// Full prompt assembled from task + context
    full_prompt: []const u8,
    /// Provider config for thread-local AI client
    provider_name: []const u8,
    provider_base_url: []const u8,
    provider_api_key: []const u8,
    model_name: []const u8,
    start_time: i64,

    pub fn deinit(self: *ThreadContext, allocator: Allocator) void {
        allocator.free(self.full_prompt);
        allocator.free(self.provider_name);
        allocator.free(self.provider_base_url);
        allocator.free(self.provider_api_key);
        allocator.free(self.model_name);
    }
};

// ── LiveAgentTeam ──────────────────────────────────────────────────────────────

pub const LiveAgentTeam = struct {
    allocator: Allocator,
    name: []const u8,
    agents: array_list_compat.ArrayList(AgentSlot),
    max_parallel: u32,
    total_budget_tokens: u64,
    used_budget_tokens: u64,
    next_agent_id: u32,
    mutex: std.Thread.Mutex,

    /// Initialize a new LiveAgentTeam.
    pub fn init(allocator: Allocator) LiveAgentTeam {
        return LiveAgentTeam{
            .allocator = allocator,
            .name = "",
            .agents = array_list_compat.ArrayList(AgentSlot).init(allocator),
            .max_parallel = 4,
            .total_budget_tokens = 0,
            .used_budget_tokens = 0,
            .next_agent_id = 1,
            .mutex = .{},
        };
    }

    /// Free all owned resources. Joins any running threads first.
    pub fn deinit(self: *LiveAgentTeam) void {
        // Cancel and join all running agents
        for (self.agents.items) |*agent| {
            if (agent.status == .running) {
                agent.status = .cancelled;
            }
            if (agent.thread) |thread| {
                thread.join();
                agent.thread = null;
            }
            agent.deinit(self.allocator);
        }
        self.agents.deinit();
        if (self.name.len > 0) self.allocator.free(self.name);
    }

    /// Create/reset the team with a name, parallel limit, and budget.
    pub fn createTeam(self: *LiveAgentTeam, name: []const u8, max_parallel: u32, budget_tokens: u64) !void {
        // Clean up existing agents
        for (self.agents.items) |*agent| {
            if (agent.thread) |thread| {
                thread.join();
            }
            agent.deinit(self.allocator);
        }
        self.agents.clearAndFree();

        if (self.name.len > 0) self.allocator.free(self.name);
        self.name = try self.allocator.dupe(u8, name);
        self.max_parallel = max_parallel;
        self.total_budget_tokens = budget_tokens;
        self.used_budget_tokens = 0;
        self.next_agent_id = 1;
    }

    /// Assign a task to a new agent slot. Returns the agent ID.
    pub fn assignTask(self: *LiveAgentTeam, task_prompt: []const u8, model: ?[]const u8, context: []const u8) !u32 {
        const id = self.next_agent_id;
        self.next_agent_id += 1;

        const agent_name = try std.fmt.allocPrint(self.allocator, "agent-{d}", .{id});

        const slot = AgentSlot{
            .id = id,
            .name = agent_name,
            .task = try self.allocator.dupe(u8, task_prompt),
            .model = if (model) |m| try self.allocator.dupe(u8, m) else null,
            .context = try self.allocator.dupe(u8, context),
            .status = .idle,
            .result = null,
            .token_usage = 0,
            .cost = 0.0,
            .thread = null,
        };

        try self.agents.append(slot);
        return id;
    }

    /// Execute all assigned tasks in parallel using std.Thread.
    /// Each agent makes a real AI call using the provided provider config.
    pub fn executeAll(self: *LiveAgentTeam, provider_name: []const u8, base_url: []const u8, api_key: []const u8, default_model: []const u8) !void {
        var launched: u32 = 0;
        var thread_contexts = array_list_compat.ArrayList(*ThreadContext).init(self.allocator);
        defer thread_contexts.deinit();

        for (self.agents.items) |*agent| {
            if (agent.status != .idle) continue;
            if (launched >= self.max_parallel) break;
            if (agent.task == null) continue;

            // Build full prompt from task + context
            var prompt_buf = array_list_compat.ArrayList(u8).init(self.allocator);
            defer prompt_buf.deinit();
            const writer = prompt_buf.writer();
            if (agent.context.len > 0) {
                writer.print("Context: {s}\n\n", .{agent.context}) catch {};
            }
            writer.print("{s}", .{agent.task.?}) catch {};
            const full_prompt = try prompt_buf.toOwnedSlice();

            const model_to_use = agent.model orelse default_model;

            // Create thread context
            const tctx = try self.allocator.create(ThreadContext);
            tctx.* = ThreadContext{
                .allocator = self.allocator,
                .slot = agent,
                .full_prompt = full_prompt,
                .provider_name = try self.allocator.dupe(u8, provider_name),
                .provider_base_url = try self.allocator.dupe(u8, base_url),
                .provider_api_key = try self.allocator.dupe(u8, api_key),
                .model_name = try self.allocator.dupe(u8, model_to_use),
                .start_time = std.time.milliTimestamp(),
            };
            try thread_contexts.append(tctx);

            agent.status = .running;
            const thread = try std.Thread.spawn(.{}, workerThread, .{tctx});
            agent.thread = thread;
            launched += 1;
        }

        // Wait for all launched threads to complete
        for (thread_contexts.items) |tctx| {
            if (tctx.slot.thread) |thread| {
                thread.join();
                tctx.slot.thread = null;
            }
        }

        // Clean up thread contexts
        for (thread_contexts.items) |tctx| {
            tctx.deinit(self.allocator);
            self.allocator.destroy(tctx);
        }
    }

    /// Get JSON status of all agents. Caller owns the returned string.
    pub fn getStatus(self: *LiveAgentTeam) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("{\"team\":\"");
        try writer.writeAll(self.name);
        try writer.print("\",\"max_parallel\":{d},\"budget_tokens\":{d},\"used_tokens\":{d},\"agents\":[", .{
            self.max_parallel,
            self.total_budget_tokens,
            self.used_budget_tokens,
        });

        for (self.agents.items, 0..) |agent, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{d},\"name\":\"{s}\",\"status\":\"{s}\"", .{
                agent.id,
                agent.name,
                @tagName(agent.status),
            });
            if (agent.task) |t| {
                try writer.writeAll(",\"task\":\"");
                // Escape basic JSON characters in task
                try writeJsonEscaped(writer, t);
                try writer.writeAll("\"");
            }
            if (agent.result) |r| {
                try writer.writeAll(",\"result\":\"");
                try writeJsonEscaped(writer, r);
                try writer.writeAll("\"");
            }
            try writer.print(",\"tokens\":{d},\"cost\":{d:.4}}}", .{
                agent.token_usage,
                agent.cost,
            });
        }

        try writer.writeAll("]}");
        return try buf.toOwnedSlice();
    }

    /// Collect results from all completed agents.
    pub fn getResults(self: *LiveAgentTeam) ![]TeamResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = array_list_compat.ArrayList(TeamResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        for (self.agents.items) |agent| {
            if (agent.status == .done or agent.status == .failed) {
                try results.append(TeamResult{
                    .agent_id = agent.id,
                    .agent_name = try self.allocator.dupe(u8, agent.name),
                    .task_prompt = if (agent.task) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                    .status = agent.status,
                    .output = if (agent.result) |r| try self.allocator.dupe(u8, r) else try self.allocator.dupe(u8, ""),
                    .token_usage = agent.token_usage,
                    .cost = agent.cost,
                    .duration_ms = 0,
                });
            }
        }

        return try results.toOwnedSlice();
    }

    /// Cancel a specific agent by ID.
    pub fn cancelAgent(self: *LiveAgentTeam, agent_id: u32) void {
        for (self.agents.items) |*agent| {
            if (agent.id == agent_id) {
                agent.status = .cancelled;
                return;
            }
        }
    }

    /// Cancel all running agents.
    pub fn cancelAll(self: *LiveAgentTeam) void {
        for (self.agents.items) |*agent| {
            if (agent.status == .running) {
                agent.status = .cancelled;
            }
        }
    }

    /// Get count of agents by status.
    pub fn countByStatus(self: *const LiveAgentTeam, status: AgentStatus) u32 {
        var count: u32 = 0;
        for (self.agents.items) |agent| {
            if (agent.status == status) count += 1;
        }
        return count;
    }
};

// ── Worker Thread ──────────────────────────────────────────────────────────────

/// Worker thread function. Creates a thread-local AI client and executes
/// the task. Uses thread-local arena allocator to avoid sharing state.
fn workerThread(tctx: *ThreadContext) void {
    const start = std.time.milliTimestamp();

    // Check if cancelled before starting
    if (tctx.slot.status == .cancelled) {
        tctx.slot.result = tctx.allocator.dupe(u8, "Cancelled") catch "Cancelled";
        return;
    }

    // Use a thread-local arena for the AI client internals
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build the AI client using the registry module's types
    const result_output = blk: {
        const registry = @import("registry");
        const core_api = @import("core_api");

        const provider = registry.Provider{
            .name = tctx.provider_name,
            .config = .{
                .base_url = tctx.provider_base_url,
                .api_key = tctx.provider_api_key,
                .models = &.{},
            },
            .allocator = arena_alloc,
        };

        var client = core_api.AIClient.init(
            arena_alloc,
            provider,
            tctx.model_name,
            tctx.provider_api_key,
        ) catch |err| {
            break :blk std.fmt.allocPrint(tctx.allocator, "AI client init failed: {s}", .{@errorName(err)}) catch
                tctx.allocator.dupe(u8, "AI client init failed") catch "AI client init failed";
        };
        defer client.deinit();

        const response = client.sendChat(tctx.full_prompt) catch |err| {
            break :blk std.fmt.allocPrint(tctx.allocator, "sendChat failed: {s}", .{@errorName(err)}) catch
                tctx.allocator.dupe(u8, "sendChat failed") catch "sendChat failed";
        };

        const content = if (response.choices.len > 0)
            response.choices[0].message.content orelse ""
        else
            "";

        break :blk tctx.allocator.dupe(u8, content) catch
            tctx.allocator.dupe(u8, "") catch "";
    };

    const end = std.time.milliTimestamp();
    _ = end - start; // duration available for future use

    // Write results back to the slot
    tctx.slot.result = result_output;
    tctx.slot.token_usage = @intCast(tctx.full_prompt.len + result_output.len);
    tctx.slot.cost = @as(f64, @floatFromInt(tctx.slot.token_usage)) * 0.00001;
    tctx.slot.status = if (tctx.slot.status != .cancelled) .done else .cancelled;
}

// ── JSON Escaping Helper ───────────────────────────────────────────────────────

fn writeJsonEscaped(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{d:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LiveAgentTeam init/deinit" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try testing.expect(team.agents.items.len == 0);
    try testing.expect(team.next_agent_id == 1);
}

test "LiveAgentTeam createTeam resets state" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("test-team", 4, 100000);
    try testing.expectEqualStrings("test-team", team.name);
    try testing.expect(team.max_parallel == 4);
    try testing.expect(team.total_budget_tokens == 100000);
    try testing.expect(team.agents.items.len == 0);

    // Create again should reset
    try team.createTeam("second-team", 2, 50000);
    try testing.expectEqualStrings("second-team", team.name);
    try testing.expect(team.max_parallel == 2);
}

test "LiveAgentTeam assignTask creates agent slots" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("workers", 4, 100000);

    const id1 = try team.assignTask("Research the codebase", null, "project: crushcode");
    const id2 = try team.assignTask("Write unit tests", "sonnet", "");

    try testing.expect(id1 == 1);
    try testing.expect(id2 == 2);
    try testing.expect(team.agents.items.len == 2);

    // Verify first slot
    try testing.expect(team.agents.items[0].status == .idle);
    try testing.expectEqualStrings("Research the codebase", team.agents.items[0].task.?);
    try testing.expect(team.agents.items[0].model == null);
    try testing.expectEqualStrings("project: crushcode", team.agents.items[0].context);

    // Verify second slot
    try testing.expectEqualStrings("Write unit tests", team.agents.items[1].task.?);
    try testing.expectEqualStrings("sonnet", team.agents.items[1].model.?);
}

test "LiveAgentTeam cancelAgent sets status" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("cancel-test", 4, 100000);
    _ = try team.assignTask("Task A", null, "");
    _ = try team.assignTask("Task B", null, "");

    try testing.expect(team.agents.items[0].status == .idle);
    team.cancelAgent(1);
    try testing.expect(team.agents.items[0].status == .cancelled);

    // Agent 2 should still be idle
    try testing.expect(team.agents.items[1].status == .idle);
}

test "LiveAgentTeam cancelAll cancels all agents" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("cancel-all-test", 4, 100000);
    _ = try team.assignTask("Task A", null, "");
    _ = try team.assignTask("Task B", null, "");

    team.cancelAll();
    try testing.expect(team.agents.items[0].status == .cancelled);
    try testing.expect(team.agents.items[1].status == .cancelled);
}

test "LiveAgentTeam getStatus returns valid JSON" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("json-test", 4, 100000);
    _ = try team.assignTask("Analyze code", null, "");

    const status = try team.getStatus();
    defer allocator.free(status);

    try testing.expect(status.len > 0);
    try testing.expect(std.mem.indexOf(u8, status, "\"team\":\"json-test\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"max_parallel\":4") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"budget_tokens\":100000") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"status\":\"idle\"") != null);
}

test "LiveAgentTeam getResults returns completed agents" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("results-test", 4, 100000);
    _ = try team.assignTask("Task A", null, "");
    _ = try team.assignTask("Task B", null, "");

    // Simulate completion of first agent
    team.agents.items[0].status = .done;
    team.agents.items[0].result = try allocator.dupe(u8, "Analysis complete");

    const results = try team.getResults();
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expect(results[0].agent_id == 1);
    try testing.expect(results[0].status == .done);
    try testing.expectEqualStrings("Analysis complete", results[0].output);
}

test "LiveAgentTeam countByStatus" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);
    defer team.deinit();

    try team.createTeam("count-test", 4, 100000);
    _ = try team.assignTask("Task A", null, "");
    _ = try team.assignTask("Task B", null, "");
    _ = try team.assignTask("Task C", null, "");

    try testing.expect(team.countByStatus(.idle) == 3);
    try testing.expect(team.countByStatus(.running) == 0);

    team.agents.items[0].status = .done;
    team.agents.items[1].status = .failed;

    try testing.expect(team.countByStatus(.idle) == 1);
    try testing.expect(team.countByStatus(.done) == 1);
    try testing.expect(team.countByStatus(.failed) == 1);
}

test "LiveAgentTeam deinit cleans up with assigned tasks" {
    const allocator = testing.allocator;
    var team = LiveAgentTeam.init(allocator);

    try team.createTeam("cleanup-test", 4, 100000);
    _ = try team.assignTask("Task A", "sonnet", "ctx");
    _ = try team.assignTask("Task B", null, "");

    // Deinit should free everything without leaks
    team.deinit();
}

test "writeJsonEscaped handles special characters" {
    const allocator = testing.allocator;
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try writeJsonEscaped(buf.writer(), "hello \"world\"\nline2\ttab");
    const result = buf.items;

    try testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\t") != null);
}
