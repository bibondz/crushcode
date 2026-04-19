const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const worker = @import("worker");

const Allocator = std.mem.Allocator;

// ── Enums ──────────────────────────────────────────────────────────────────────

pub const EffortLevel = enum { low, medium, high };
pub const MemoryScope = enum { shared, isolated, session };
pub const PermissionMode = enum { auto, propose, never };
pub const AgentStatus = enum { idle, working, waiting, completed, failed };
pub const MessageType = enum { task_assignment, result, shutdown, status_request, coordination };

// ── AgentMessage ───────────────────────────────────────────────────────────────

pub const AgentMessage = struct {
    from_id: []const u8,
    to_id: []const u8,
    message_type: MessageType,
    content: []const u8,
    timestamp: i64,

    pub fn deinit(self: *const AgentMessage, allocator: Allocator) void {
        allocator.free(self.from_id);
        allocator.free(self.to_id);
        allocator.free(self.content);
    }
};

// ── AgentDefinition ────────────────────────────────────────────────────────────

pub const AgentDefinition = struct {
    allocator: Allocator,
    id: []const u8,
    name: []const u8,
    specialty: worker.WorkerSpecialty,
    effort_level: EffortLevel,
    memory_scope: MemoryScope,
    permission_mode: PermissionMode,
    parent_id: ?[]const u8,
    status: AgentStatus,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        name: []const u8,
        specialty: worker.WorkerSpecialty,
        effort_level: EffortLevel,
    ) !AgentDefinition {
        return AgentDefinition{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .specialty = specialty,
            .effort_level = effort_level,
            .memory_scope = .shared,
            .permission_mode = .auto,
            .parent_id = null,
            .status = .idle,
        };
    }

    pub fn initWithParent(
        allocator: Allocator,
        id: []const u8,
        name: []const u8,
        specialty: worker.WorkerSpecialty,
        effort_level: EffortLevel,
        parent_id: []const u8,
    ) !AgentDefinition {
        var def = try init(allocator, id, name, specialty, effort_level);
        def.parent_id = try allocator.dupe(u8, parent_id);
        return def;
    }

    pub fn deinit(self: *AgentDefinition) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        if (self.parent_id) |pid| self.allocator.free(pid);
    }
};

// ── AgentTeam ──────────────────────────────────────────────────────────────────

pub const AgentTeam = struct {
    allocator: Allocator,
    id: []const u8,
    name: []const u8,
    agents: array_list_compat.ArrayList(*AgentDefinition),
    inbox: array_list_compat.ArrayList(AgentMessage),
    max_agents: u32,
    created_at: i64,

    pub fn init(allocator: Allocator, id: []const u8, name: []const u8, max_agents: u32) !AgentTeam {
        return AgentTeam{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .agents = array_list_compat.ArrayList(*AgentDefinition).init(allocator),
            .inbox = array_list_compat.ArrayList(AgentMessage).init(allocator),
            .max_agents = max_agents,
            .created_at = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *AgentTeam) void {
        for (self.agents.items) |agent| {
            agent.deinit();
            self.allocator.destroy(agent);
        }
        self.agents.deinit();

        for (self.inbox.items) |msg| {
            msg.deinit(self.allocator);
        }
        self.inbox.deinit();

        self.allocator.free(self.id);
        self.allocator.free(self.name);
    }

    pub fn addAgent(self: *AgentTeam, definition: *AgentDefinition) !void {
        if (self.agents.items.len >= self.max_agents) {
            return error.TeamFull;
        }
        try self.agents.append(definition);
    }

    pub fn findAgent(self: *AgentTeam, id: []const u8) ?*AgentDefinition {
        for (self.agents.items) |agent| {
            if (std.mem.eql(u8, agent.id, id)) return agent;
        }
        return null;
    }

    pub fn listIdleAgents(self: *AgentTeam) ![]*AgentDefinition {
        var result = array_list_compat.ArrayList(*AgentDefinition).init(self.allocator);
        errdefer result.deinit();

        for (self.agents.items) |agent| {
            if (agent.status == .idle) {
                try result.append(agent);
            }
        }
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Deliver a message to an agent in this team.
    /// Returns true if the agent was found and message appended to inbox.
    pub fn routeMessage(self: *AgentTeam, msg: AgentMessage) bool {
        // Check if the target agent is in this team
        const found = self.findAgent(msg.to_id) != null;
        if (found) {
            self.inbox.append(msg) catch return false;
            return true;
        }
        return false;
    }
};

// ── TeamCoordinator ────────────────────────────────────────────────────────────

pub const TeamCoordinator = struct {
    allocator: Allocator,
    teams: array_list_compat.ArrayList(*AgentTeam),
    worker_pool: *worker.WorkerPool,
    global_inbox: array_list_compat.ArrayList(AgentMessage),
    active_team: ?*AgentTeam,
    next_team_id: u32,
    next_agent_id: u32,

    pub fn init(allocator: Allocator, worker_pool: *worker.WorkerPool) TeamCoordinator {
        return TeamCoordinator{
            .allocator = allocator,
            .teams = array_list_compat.ArrayList(*AgentTeam).init(allocator),
            .worker_pool = worker_pool,
            .global_inbox = array_list_compat.ArrayList(AgentMessage).init(allocator),
            .active_team = null,
            .next_team_id = 1,
            .next_agent_id = 1,
        };
    }

    pub fn deinit(self: *TeamCoordinator) void {
        for (self.teams.items) |team| {
            team.deinit();
            self.allocator.destroy(team);
        }
        self.teams.deinit();

        for (self.global_inbox.items) |msg| {
            msg.deinit(self.allocator);
        }
        self.global_inbox.deinit();
    }

    /// Create a new team and add it to the coordinator.
    pub fn createTeam(self: *TeamCoordinator, name: []const u8, max_agents: u32) !*AgentTeam {
        const id_str = try std.fmt.allocPrint(self.allocator, "team-{d}", .{self.next_team_id});
        self.next_team_id += 1;

        const team = try self.allocator.create(AgentTeam);
        team.* = try AgentTeam.init(self.allocator, id_str, name, max_agents);
        self.allocator.free(id_str);

        try self.teams.append(team);
        self.active_team = team;
        return team;
    }

    /// Add a new agent to a specific team by team ID.
    pub fn addAgentToTeam(
        self: *TeamCoordinator,
        team_id: []const u8,
        specialty: worker.WorkerSpecialty,
        effort_level: EffortLevel,
    ) !*AgentDefinition {
        const team = self.findTeam(team_id) orelse return error.TeamNotFound;

        const agent_id_str = try std.fmt.allocPrint(self.allocator, "agent-{d}", .{self.next_agent_id});
        self.next_agent_id += 1;

        const agent_name = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ @tagName(specialty), agent_id_str });

        const agent = try self.allocator.create(AgentDefinition);
        agent.* = try AgentDefinition.init(self.allocator, agent_id_str, agent_name, specialty, effort_level);

        self.allocator.free(agent_id_str);
        self.allocator.free(agent_name);

        try team.addAgent(agent);
        return agent;
    }

    /// Convenience: creates a team and spawns N agents with a round-robin specialty assignment.
    pub fn spawnTeam(self: *TeamCoordinator, task_description: []const u8, agent_count: u32) !*AgentTeam {
        const specialties = [_]worker.WorkerSpecialty{
            .researcher,
            .file_ops,
            .executor,
            .publisher,
            .collector,
        };

        const team = try self.createTeam(task_description, 10);

        var i: u32 = 0;
        while (i < agent_count) : (i += 1) {
            const specialty = specialties[i % specialties.len];
            const effort: EffortLevel = switch (specialty) {
                .researcher => .high,
                .executor => .high,
                .file_ops => .medium,
                .publisher => .low,
                .collector => .medium,
            };

            const agent = try self.addAgentToTeam(team.id, specialty, effort);
            agent.status = .working;

            // Send task assignment message
            try self.sendMessage("coordinator", agent.id, .task_assignment, task_description);
        }

        return team;
    }

    /// Enqueue a message from one agent to another.
    pub fn sendMessage(
        self: *TeamCoordinator,
        from_id: []const u8,
        to_id: []const u8,
        message_type: MessageType,
        content: []const u8,
    ) !void {
        const msg = AgentMessage{
            .from_id = try self.allocator.dupe(u8, from_id),
            .to_id = try self.allocator.dupe(u8, to_id),
            .message_type = message_type,
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.milliTimestamp(),
        };

        // Try to route to the active team first
        if (self.active_team) |team| {
            if (team.routeMessage(msg)) {
                return;
            }
        }

        // Try all teams
        for (self.teams.items) |team| {
            if (team.routeMessage(msg)) {
                return;
            }
        }

        // No team found — put in global inbox
        try self.global_inbox.append(msg);
    }

    /// Dequeue and return all messages for a specific agent from all teams and global inbox.
    /// Caller owns the returned slice and must free each message and the slice itself.
    pub fn receiveMessages(self: *TeamCoordinator, agent_id: []const u8) ![]AgentMessage {
        var result = array_list_compat.ArrayList(AgentMessage).init(self.allocator);
        errdefer result.deinit();

        // Collect from global inbox
        var i: usize = 0;
        while (i < self.global_inbox.items.len) {
            const msg = self.global_inbox.items[i];
            if (std.mem.eql(u8, msg.to_id, agent_id)) {
                _ = self.global_inbox.swapRemove(i);
                try result.append(msg);
            } else {
                i += 1;
            }
        }

        // Collect from each team inbox
        for (self.teams.items) |team| {
            var j: usize = 0;
            while (j < team.inbox.items.len) {
                const msg = team.inbox.items[j];
                if (std.mem.eql(u8, msg.to_id, agent_id)) {
                    _ = team.inbox.swapRemove(j);
                    try result.append(msg);
                } else {
                    j += 1;
                }
            }
        }

        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Send a message from one agent to all agents in the active team.
    pub fn broadcastMessage(self: *TeamCoordinator, from_id: []const u8, content: []const u8) !void {
        const team = self.active_team orelse return error.NoActiveTeam;

        for (team.agents.items) |agent| {
            // Don't send to self
            if (std.mem.eql(u8, agent.id, from_id)) continue;

            try self.sendMessage(from_id, agent.id, .coordination, content);
        }
    }

    /// Get a formatted status string for a team.
    pub fn getTeamStatus(self: *TeamCoordinator, team_id: []const u8) ![]const u8 {
        const team = self.findTeam(team_id) orelse return error.TeamNotFound;

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const writer = buf.writer();
        writer.print("=== Team: {s} ({s}) ===\n", .{ team.name, team.id }) catch {};
        writer.print("  Max agents: {d}\n", .{team.max_agents}) catch {};
        writer.print("  Agents:     {d}\n", .{team.agents.items.len}) catch {};
        writer.print("  Messages:   {d}\n", .{team.inbox.items.len}) catch {};
        writer.print("\n", .{}) catch {};

        for (team.agents.items, 0..) |agent, idx| {
            const status_icon = switch (agent.status) {
                .idle => "⏳",
                .working => "🔄",
                .waiting => "⏸️",
                .completed => "✅",
                .failed => "❌",
            };
            writer.print("  {d}. {s} [{s}] {s} effort={s} memory={s}\n", .{
                idx + 1,
                status_icon,
                @tagName(agent.specialty),
                agent.name,
                @tagName(agent.effort_level),
                @tagName(agent.memory_scope),
            }) catch {};
        }

        return buf.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Assign a task from one agent to another via a task_assignment message.
    pub fn delegateTask(
        self: *TeamCoordinator,
        from_id: []const u8,
        to_id: []const u8,
        task_description: []const u8,
    ) !void {
        // Set the receiving agent to working status
        for (self.teams.items) |team| {
            if (team.findAgent(to_id)) |agent| {
                agent.status = .working;
                break;
            }
        }

        try self.sendMessage(from_id, to_id, .task_assignment, task_description);
    }

    /// Collect all result-type messages from a team.
    pub fn collectResults(self: *TeamCoordinator, team_id: []const u8) ![]AgentMessage {
        const team = self.findTeam(team_id) orelse return error.TeamNotFound;

        var result = array_list_compat.ArrayList(AgentMessage).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < team.inbox.items.len) {
            const msg = team.inbox.items[i];
            if (msg.message_type == .result) {
                _ = team.inbox.swapRemove(i);
                try result.append(msg);
            } else {
                i += 1;
            }
        }

        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Find a team by ID.
    pub fn findTeam(self: *TeamCoordinator, team_id: []const u8) ?*AgentTeam {
        for (self.teams.items) |team| {
            if (std.mem.eql(u8, team.id, team_id)) return team;
        }
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "AgentDefinition - init and deinit" {
    const allocator = std.testing.allocator;
    var def = try AgentDefinition.init(allocator, "agent-1", "Researcher-1", .researcher, .high);
    defer def.deinit();

    try testing.expectEqualStrings("agent-1", def.id);
    try testing.expectEqualStrings("Researcher-1", def.name);
    try testing.expectEqual(worker.WorkerSpecialty.researcher, def.specialty);
    try testing.expectEqual(EffortLevel.high, def.effort_level);
    try testing.expectEqual(MemoryScope.shared, def.memory_scope);
    try testing.expectEqual(PermissionMode.auto, def.permission_mode);
    try testing.expect(def.parent_id == null);
    try testing.expectEqual(AgentStatus.idle, def.status);
}

test "AgentDefinition - initWithParent" {
    const allocator = std.testing.allocator;
    var def = try AgentDefinition.initWithParent(allocator, "agent-2", "Sub-1", .executor, .medium, "agent-1");
    defer def.deinit();

    try testing.expect(def.parent_id != null);
    try testing.expectEqualStrings("agent-1", def.parent_id.?);
}

test "AgentTeam - init and addAgent" {
    const allocator = std.testing.allocator;
    var team = try AgentTeam.init(allocator, "team-1", "Test Team", 5);
    defer team.deinit();

    try testing.expectEqualStrings("team-1", team.id);
    try testing.expectEqualStrings("Test Team", team.name);
    try testing.expectEqual(@as(u32, 5), team.max_agents);
    try testing.expectEqual(@as(usize, 0), team.agents.items.len);

    var def = try AgentDefinition.init(allocator, "a-1", "Agent One", .researcher, .high);
    try team.addAgent(&def);
    try testing.expectEqual(@as(usize, 1), team.agents.items.len);
}

test "AgentTeam - findAgent" {
    const allocator = std.testing.allocator;
    var team = try AgentTeam.init(allocator, "team-1", "Test", 5);
    defer team.deinit();

    var def1 = try AgentDefinition.init(allocator, "a-1", "Agent 1", .researcher, .high);
    var def2 = try AgentDefinition.init(allocator, "a-2", "Agent 2", .executor, .medium);
    try team.addAgent(&def1);
    try team.addAgent(&def2);

    const found = team.findAgent("a-2");
    try testing.expect(found != null);
    try testing.expectEqualStrings("Agent 2", found.?.name);

    try testing.expect(team.findAgent("a-999") == null);
}

test "AgentTeam - listIdleAgents" {
    const allocator = std.testing.allocator;
    var team = try AgentTeam.init(allocator, "team-1", "Test", 5);
    defer team.deinit();

    var def1 = try AgentDefinition.init(allocator, "a-1", "Idle 1", .researcher, .high);
    var def2 = try AgentDefinition.init(allocator, "a-2", "Working 1", .executor, .medium);
    def2.status = .working;
    var def3 = try AgentDefinition.init(allocator, "a-3", "Idle 2", .collector, .low);

    try team.addAgent(&def1);
    try team.addAgent(&def2);
    try team.addAgent(&def3);

    const idle = try team.listIdleAgents();
    defer allocator.free(idle);

    try testing.expectEqual(@as(usize, 2), idle.len);
}

test "AgentTeam - max agents limit" {
    const allocator = std.testing.allocator;
    var team = try AgentTeam.init(allocator, "team-1", "Small", 1);
    defer team.deinit();

    var def1 = try AgentDefinition.init(allocator, "a-1", "First", .researcher, .high);
    try team.addAgent(&def1);

    var def2 = try AgentDefinition.init(allocator, "a-2", "Second", .executor, .medium);
    defer def2.deinit();
    try testing.expectError(error.TeamFull, team.addAgent(&def2));
}

test "AgentTeam - routeMessage" {
    const allocator = std.testing.allocator;
    var team = try AgentTeam.init(allocator, "team-1", "Test", 5);
    defer team.deinit();

    var def1 = try AgentDefinition.init(allocator, "a-1", "Agent 1", .researcher, .high);
    try team.addAgent(&def1);

    const msg = AgentMessage{
        .from_id = "coordinator",
        .to_id = "a-1",
        .message_type = .task_assignment,
        .content = "Do research",
        .timestamp = std.time.milliTimestamp(),
    };

    const routed = team.routeMessage(msg);
    try testing.expect(routed);
    try testing.expectEqual(@as(usize, 1), team.inbox.items.len);

    // Message to non-existent agent should not be routed
    const msg2 = AgentMessage{
        .from_id = "coordinator",
        .to_id = "a-999",
        .message_type = .task_assignment,
        .content = "Nothing",
        .timestamp = std.time.milliTimestamp(),
    };
    const routed2 = team.routeMessage(msg2);
    try testing.expect(!routed2);
}

test "TeamCoordinator - createTeam and addAgentToTeam" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    const team = try coord.createTeam("Research Team", 5);
    try testing.expectEqualStrings("team-1", team.id);
    try testing.expect(coord.active_team != null);

    const agent = try coord.addAgentToTeam("team-1", .researcher, .high);
    try testing.expect(agent.id.len > 0);
    try testing.expectEqual(worker.WorkerSpecialty.researcher, agent.specialty);
    try testing.expectEqual(EffortLevel.high, agent.effort_level);

    try testing.expectError(error.TeamNotFound, coord.addAgentToTeam("nonexistent", .executor, .medium));
}

test "TeamCoordinator - sendMessage and receiveMessages" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Test Team", 5);
    const agent = try coord.addAgentToTeam("team-1", .researcher, .high);

    // Send a message to the agent
    try coord.sendMessage("coordinator", agent.id, .task_assignment, "Analyze codebase");

    // Receive messages for the agent
    const messages = try coord.receiveMessages(agent.id);
    defer {
        for (messages) |msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    try testing.expectEqual(@as(usize, 1), messages.len);
    try testing.expectEqual(MessageType.task_assignment, messages[0].message_type);
    try testing.expectEqualStrings("Analyze codebase", messages[0].content);
    try testing.expectEqualStrings("coordinator", messages[0].from_id);
    try testing.expectEqualStrings(agent.id, messages[0].to_id);
}

test "TeamCoordinator - broadcastMessage" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Broadcast Team", 10);
    const agent1 = try coord.addAgentToTeam("team-1", .researcher, .high);
    const agent2 = try coord.addAgentToTeam("team-1", .executor, .medium);
    const agent3 = try coord.addAgentToTeam("team-1", .collector, .low);

    // Broadcast from agent1 to all others
    try coord.broadcastMessage(agent1.id, "Status update: starting work");

    // Agent1 should NOT receive its own broadcast
    const msgs1 = try coord.receiveMessages(agent1.id);
    defer {
        for (msgs1) |msg| msg.deinit(allocator);
        allocator.free(msgs1);
    }
    try testing.expectEqual(@as(usize, 0), msgs1.len);

    // Agent2 should have received the broadcast
    const msgs2 = try coord.receiveMessages(agent2.id);
    defer {
        for (msgs2) |msg| msg.deinit(allocator);
        allocator.free(msgs2);
    }
    try testing.expectEqual(@as(usize, 1), msgs2.len);
    try testing.expectEqual(MessageType.coordination, msgs2[0].message_type);

    // Agent3 should have received the broadcast
    const msgs3 = try coord.receiveMessages(agent3.id);
    defer {
        for (msgs3) |msg| msg.deinit(allocator);
        allocator.free(msgs3);
    }
    try testing.expectEqual(@as(usize, 1), msgs3.len);
}

test "TeamCoordinator - getTeamStatus formatting" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Status Team", 10);
    _ = try coord.addAgentToTeam("team-1", .researcher, .high);
    _ = try coord.addAgentToTeam("team-1", .executor, .medium);

    const status = try coord.getTeamStatus("team-1");
    defer allocator.free(status);

    try testing.expect(status.len > 0);
    // Should contain team name
    try testing.expect(std.mem.indexOf(u8, status, "Status Team") != null);
    // Should contain agent count
    try testing.expect(std.mem.indexOf(u8, status, "Agents:     2") != null);
}

test "TeamCoordinator - spawnTeam convenience method" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    const team = try coord.spawnTeam("Analyze codebase and generate report", 3);

    try testing.expectEqual(@as(usize, 3), team.agents.items.len);

    // All agents should be in working status
    for (team.agents.items) |agent| {
        try testing.expectEqual(AgentStatus.working, agent.status);
    }

    // Each agent should have a task assignment message
    for (team.agents.items) |agent| {
        const msgs = try coord.receiveMessages(agent.id);
        defer {
            for (msgs) |msg| msg.deinit(allocator);
            allocator.free(msgs);
        }
        try testing.expectEqual(@as(usize, 1), msgs.len);
        try testing.expectEqual(MessageType.task_assignment, msgs[0].message_type);
        try testing.expectEqualStrings("Analyze codebase and generate report", msgs[0].content);
    }
}

test "TeamCoordinator - delegateTask between agents" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Delegation Team", 10);
    const agent1 = try coord.addAgentToTeam("team-1", .researcher, .high);
    const agent2 = try coord.addAgentToTeam("team-1", .executor, .medium);

    try testing.expectEqual(AgentStatus.idle, agent2.status);

    try coord.delegateTask(agent1.id, agent2.id, "Execute the research plan");

    // Agent2 should now be working
    try testing.expectEqual(AgentStatus.working, agent2.status);

    // Agent2 should have a task_assignment message
    const msgs = try coord.receiveMessages(agent2.id);
    defer {
        for (msgs) |msg| msg.deinit(allocator);
        allocator.free(msgs);
    }
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqual(MessageType.task_assignment, msgs[0].message_type);
    try testing.expectEqualStrings("Execute the research plan", msgs[0].content);
}

test "TeamCoordinator - collectResults" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Results Team", 10);
    const agent1 = try coord.addAgentToTeam("team-1", .researcher, .high);
    const agent2 = try coord.addAgentToTeam("team-1", .executor, .medium);

    // Send mixed messages
    try coord.sendMessage("coordinator", agent1.id, .task_assignment, "Do work");
    try coord.sendMessage(agent1.id, "coordinator", .result, "Research done");
    try coord.sendMessage(agent2.id, "coordinator", .result, "Execution complete");
    try coord.sendMessage("coordinator", agent2.id, .status_request, "How's it going?");

    // Collect results — coordinator receives results from agents
    // First let's receive agent1's messages so they're removed
    const msgs_a1 = try coord.receiveMessages(agent1.id);
    defer {
        for (msgs_a1) |msg| msg.deinit(allocator);
        allocator.free(msgs_a1);
    }

    const msgs_a2 = try coord.receiveMessages(agent2.id);
    defer {
        for (msgs_a2) |msg| msg.deinit(allocator);
        allocator.free(msgs_a2);
    }

    // The result messages to "coordinator" should be in the team inbox or global inbox
    // Let's check global inbox for result messages
    var result_count: usize = 0;
    for (coord.global_inbox.items) |msg| {
        if (msg.message_type == .result) result_count += 1;
    }
    // We sent 2 result messages to "coordinator" which is not an agent in the team,
    // so they should be in global inbox
    try testing.expectEqual(@as(usize, 2), result_count);
}

test "TeamCoordinator - findTeam" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    _ = try coord.createTeam("Team A", 5);
    _ = try coord.createTeam("Team B", 3);

    try testing.expect(coord.findTeam("team-1") != null);
    try testing.expect(coord.findTeam("team-2") != null);
    try testing.expect(coord.findTeam("team-999") == null);
}

test "TeamCoordinator - multiple teams" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var coord = TeamCoordinator.init(allocator, &pool);
    defer coord.deinit();

    const team1 = try coord.createTeam("Alpha", 5);
    const team2 = try coord.createTeam("Beta", 3);

    const a1 = try coord.addAgentToTeam(team1.id, .researcher, .high);
    const a2 = try coord.addAgentToTeam(team2.id, .executor, .medium);

    // Message from a1 to a2 goes to team2's inbox (or global since a2 is in different team)
    try coord.sendMessage(a1.id, a2.id, .coordination, "Cross-team message");

    const msgs = try coord.receiveMessages(a2.id);
    defer {
        for (msgs) |msg| msg.deinit(allocator);
        allocator.free(msgs);
    }
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("Cross-team message", msgs[0].content);
}

test "EffortLevel enum values" {
    try testing.expectEqual(EffortLevel.low, @as(EffortLevel, @enumFromInt(0)));
    try testing.expectEqual(EffortLevel.medium, @as(EffortLevel, @enumFromInt(1)));
    try testing.expectEqual(EffortLevel.high, @as(EffortLevel, @enumFromInt(2)));
}

test "MessageType enum values" {
    try testing.expectEqual(MessageType.task_assignment, @as(MessageType, @enumFromInt(0)));
    try testing.expectEqual(MessageType.result, @as(MessageType, @enumFromInt(1)));
    try testing.expectEqual(MessageType.shutdown, @as(MessageType, @enumFromInt(2)));
    try testing.expectEqual(MessageType.status_request, @as(MessageType, @enumFromInt(3)));
    try testing.expectEqual(MessageType.coordination, @as(MessageType, @enumFromInt(4)));
}
