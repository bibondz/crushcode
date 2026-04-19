const std = @import("std");
const args_mod = @import("args");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const skills_resolver = @import("skills_resolver");
const worker_mod = @import("worker");
const coordinator_mod = @import("coordinator");
const orchestration_mod = @import("orchestration");
const background_agent_mod = @import("background_agent");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleSkillsResolve(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode skills resolve <context_query> [--file <path>]\n", .{});
        stdout_print("  Resolves skills matching the given context/query.\n", .{});
        return;
    }

    var query: []const u8 = "";
    var file_path: []const u8 = "";

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--file")) {
            i += 1;
            if (i < args.remaining.len) {
                file_path = args.remaining[i];
            }
        } else {
            query = args.remaining[i];
        }
    }

    // Determine search paths from common locations
    var search_paths = array_list_compat.ArrayList([]const u8).init(allocator);
    defer search_paths.deinit();

    try search_paths.append("./skills");
    try search_paths.append(".claude/skills");
    try search_paths.append(".crushcode/skills");

    var resolver_state = skills_resolver.SkillResolver.init(allocator, search_paths.items);
    defer resolver_state.deinit();

    // Try loading AGENTS.md
    resolver_state.loadAgentsConfig(".") catch {};

    // Load indices
    resolver_state.loadIndices() catch {};

    stdout_print("\n=== Skills Resolution ===\n", .{});
    stdout_print("  Query: {s}\n", .{query});
    if (file_path.len > 0) stdout_print("  File:  {s}\n", .{file_path});
    stdout_print("\n", .{});

    const effective_file = if (file_path.len > 0) file_path else "unknown";

    const results = try resolver_state.resolveForContext(effective_file, query);
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    if (results.len == 0) {
        stdout_print("  No matching skills found.\n", .{});
    } else {
        for (results, 0..) |res, idx| {
            const source_label = switch (res.source) {
                .agents_md => "AGENTS.md",
                .index_md => "_INDEX.md",
                .trigger_match => "trigger",
                .keyword_match => "keyword",
                .direct_path => "direct",
            };
            stdout_print("  {d}. {s}\n", .{ idx + 1, res.skill_name });
            stdout_print("     Path:      {s}\n", .{res.skill_path});
            stdout_print("     Relevance: {d:.2}\n", .{res.relevance});
            stdout_print("     Source:    {s}\n", .{source_label});
        }
    }
}

/// Handle `crushcode skills scan` — scan project for AGENTS.md, _INDEX.md, SKILL.md files
pub fn handleSkillsScan(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    _ = args;

    var search_paths = array_list_compat.ArrayList([]const u8).init(allocator);
    defer search_paths.deinit();

    try search_paths.append("./skills");
    try search_paths.append(".claude/skills");
    try search_paths.append(".crushcode/skills");

    var resolver_state = skills_resolver.SkillResolver.init(allocator, search_paths.items);
    defer resolver_state.deinit();

    // Try loading AGENTS.md
    resolver_state.loadAgentsConfig(".") catch {};

    // Load indices
    resolver_state.loadIndices() catch {};

    stdout_print("\n=== Skills Scan ===\n\n", .{});

    // Scan for AGENTS.md
    const agents_locations = [_][]const u8{
        "./AGENTS.md",
        "./.claude/AGENTS.md",
        "./.crushcode/AGENTS.md",
    };

    stdout_print("--- AGENTS.md ---\n", .{});
    var agents_found = false;
    for (&agents_locations) |loc| {
        std.fs.cwd().access(loc[2..], .{}) catch continue;
        stdout_print("  Found: {s}\n", .{loc});
        agents_found = true;
    }
    if (!agents_found) {
        stdout_print("  No AGENTS.md found in project.\n", .{});
    }

    // Scan for _INDEX.md files
    stdout_print("\n--- _INDEX.md Files ---\n", .{});
    if (resolver_state.loaded_indices.count() == 0) {
        stdout_print("  No _INDEX.md files found.\n", .{});
    } else {
        var idx_iter = resolver_state.loaded_indices.iterator();
        while (idx_iter.next()) |entry| {
            stdout_print("  {s} ({d} entries)\n", .{ entry.key_ptr.*, entry.value_ptr.len });
            for (entry.value_ptr.*) |idx| {
                const tier = if (idx.is_file_match) "FileMatch" else "KeywordMatch";
                stdout_print("    - {s} [{s}]\n", .{ idx.skill_name, tier });
            }
        }
    }

    // Scan for SKILL.md files in search paths
    stdout_print("\n--- SKILL.md Files ---\n", .{});
    var total_skills: u32 = 0;
    for (search_paths.items) |sp| {
        var dir = std.fs.cwd().openDir(sp, .{ .iterate = true }) catch continue;
        defer dir.close();

        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();

        while (walker.next() catch continue) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.basename, "SKILL.md")) continue;

            stdout_print("  {s}/{s}\n", .{ sp, entry.path });
            total_skills += 1;
        }
    }
    if (total_skills == 0) {
        stdout_print("  No SKILL.md files found in search paths.\n", .{});
    }

    // Show AGENTS.md config if loaded
    if (resolver_state.agents_config) |cfg| {
        stdout_print("\n--- AGENTS.md Config ---\n", .{});
        stdout_print("  Skill paths: {d}\n", .{cfg.skill_paths.len});
        for (cfg.skill_paths) |sp| {
            stdout_print("    - {s}\n", .{sp});
        }
        stdout_print("  Enabled skills: {d}\n", .{cfg.enabled_skills.len});
        for (cfg.enabled_skills) |s| {
            stdout_print("    - {s}\n", .{s});
        }
        stdout_print("  Trigger rules: {d}\n", .{cfg.trigger_rules.len});
        for (cfg.trigger_rules) |r| {
            const auto_label = if (r.auto_load) " (auto)" else "";
            stdout_print("    - {s} → {s}{s}\n", .{ r.pattern, r.skill_name, auto_label });
        }
    }

    stdout_print("\n  Total: {d} _INDEX.md, {d} SKILL.md\n", .{ resolver_state.loaded_indices.count(), total_skills });
}

/// Global coordinator state (persists across commands in same process)
var global_coordinator_pool: ?worker_mod.WorkerPool = null;
var global_coordinator: ?coordinator_mod.TeamCoordinator = null;

fn getOrCreateCoordinator(allocator: std.mem.Allocator) *coordinator_mod.TeamCoordinator {
    if (global_coordinator_pool == null) {
        global_coordinator_pool = worker_mod.WorkerPool.init(allocator);
    }
    if (global_coordinator == null) {
        global_coordinator = coordinator_mod.TeamCoordinator.init(allocator, &global_coordinator_pool.?);
    }
    return &global_coordinator.?;
}

/// Handle `crushcode team <subcommand>` — agent orchestration via OrchestrationEngine.
/// Subcommands:
///   spawn "<task>" [--agents N]  Create team with N agents for a task (default 3)
///   status [team_id]             Show team composition and agent statuses
///   cost "<task>"                Estimate cost for a task using OrchestrationEngine
///   execute <team-id> <phase>    Execute a specific phase of a team plan
///   checkpoints                  List saved checkpoints
///   list                         List all registered capabilities
///   message <from> <to> "<msg>"  Send inter-agent message
pub fn handleTeam(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode team <spawn|status|cost|execute|checkpoints|list|message> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  spawn \"<task>\" [--agents N]  Create team with N agents (default 3)\n", .{});
        stdout_print("  status [team-id]             Show team status or list all teams\n", .{});
        stdout_print("  cost \"<task>\"                Estimate cost for a task\n", .{});
        stdout_print("  execute <team-id> <phase>    Execute a specific phase\n", .{});
        stdout_print("  checkpoints                  List saved checkpoints\n", .{});
        stdout_print("  list                         List all registered capabilities\n", .{});
        stdout_print("  message <from> <to> \"<msg>\"  Send inter-agent message\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcommand, "spawn")) {
        try handleTeamSpawn(allocator, sub_args);
        return;
    }

    if (std.mem.eql(u8, subcommand, "status")) {
        try handleTeamStatus(allocator, sub_args);
        return;
    }

    if (std.mem.eql(u8, subcommand, "cost")) {
        try handleTeamCost(allocator, sub_args);
        return;
    }

    if (std.mem.eql(u8, subcommand, "execute")) {
        try handleTeamExecute(allocator, sub_args);
        return;
    }

    if (std.mem.eql(u8, subcommand, "checkpoints")) {
        try handleTeamCheckpoints(allocator);
        return;
    }

    if (std.mem.eql(u8, subcommand, "list")) {
        handleTeamList(allocator);
        return;
    }

    if (std.mem.eql(u8, subcommand, "message")) {
        try handleTeamMessage(allocator, sub_args);
        return;
    }

    stdout_print("Unknown subcommand: {s}\n", .{subcommand});
    stdout_print("Use: spawn, status, cost, execute, checkpoints, list, or message\n", .{});
}

/// Handle `crushcode team cost "<task>"` — estimate cost using OrchestrationEngine.
fn handleTeamCost(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode team cost \"<task description>\"\n", .{});
        return;
    }

    const task_description = sub_args[0];

    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    const estimate = engine.estimateCost(task_description) catch {
        stdout_print("Error: failed to estimate cost\n", .{});
        return;
    };
    defer estimate.deinit(allocator);

    stdout_print("\n=== Cost Estimate ===\n", .{});
    stdout_print("  Task:          {s}\n", .{task_description});
    stdout_print("  Category:      {s}\n", .{@tagName(estimate.task_category)});
    stdout_print("  Model:         {s}\n", .{estimate.recommended_model});
    stdout_print("  Est. tokens:   {d}\n", .{estimate.estimated_tokens});
    stdout_print("  Est. cost:     ${d:.4}\n", .{estimate.estimated_cost});
    if (estimate.cost_breakdown.len > 0) {
        stdout_print("\n  Breakdown:\n", .{});
        for (estimate.cost_breakdown, 0..) |item, idx| {
            stdout_print("    {d}. {s}: {d} tokens = ${d:.4}\n", .{ idx + 1, item.model, item.tokens, item.cost });
        }
    }
    stdout_print("\n", .{});
}

/// Handle `crushcode team execute <team-id> <phase-index>` — execute a phase.
fn handleTeamExecute(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 2) {
        stdout_print("Usage: crushcode team execute <team-id> <phase-index>\n", .{});
        return;
    }

    const team_id = sub_args[0];
    const phase_index = std.fmt.parseInt(u32, sub_args[1], 10) catch {
        stdout_print("Error: invalid phase index '{s}' — must be a number\n", .{sub_args[1]});
        return;
    };

    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    var result = engine.executePhase(team_id, phase_index) catch |err| {
        if (err == error.TeamNotFound) {
            stdout_print("Error: team '{s}' not found. Spawn a team first with `crushcode team spawn`.\n", .{team_id});
        } else if (err == error.InvalidPhaseIndex) {
            stdout_print("Error: phase index {d} is out of range\n", .{phase_index});
        } else {
            stdout_print("Error executing phase: {}\n", .{err});
        }
        return;
    };
    defer result.deinit(allocator);

    stdout_print("\n=== Phase Execution Result ===\n", .{});
    stdout_print("  Team:      {s}\n", .{result.team_id});
    stdout_print("  Phase:     {s} (index {d})\n", .{ result.phase_name, result.phase_index });
    stdout_print("  Status:    {s}\n", .{@tagName(result.status)});
    stdout_print("  Duration:  {d}ms\n", .{result.duration_ms});
    stdout_print("  Output:    {s}\n", .{result.output});
    if (result.checkpoint_id) |cp_id| {
        stdout_print("  Checkpoint: {s}\n", .{cp_id});
    }
    stdout_print("\n", .{});
}

/// Handle `crushcode team checkpoints` — list saved checkpoints.
fn handleTeamCheckpoints(allocator: std.mem.Allocator) !void {
    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    const checkpoints = engine.listCheckpoints() catch {
        stdout_print("Error: failed to list checkpoints\n", .{});
        return;
    };
    defer {
        for (checkpoints) |cp| allocator.free(cp);
        allocator.free(checkpoints);
    }

    stdout_print("\n=== Checkpoints ({d}) ===\n", .{checkpoints.len});
    if (checkpoints.len == 0) {
        stdout_print("  No checkpoints saved yet\n", .{});
    } else {
        for (checkpoints, 0..) |cp_id, idx| {
            stdout_print("  {d}. {s}\n", .{ idx + 1, cp_id });
        }
    }
    stdout_print("\n", .{});
}

fn handleTeamSpawn(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode team spawn \"<task>\" --agents N\n", .{});
        return;
    }

    var task_description: ?[]const u8 = null;
    var agent_count: u32 = 3;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--agents")) {
            i += 1;
            if (i < sub_args.len) {
                agent_count = std.fmt.parseInt(u32, sub_args[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, sub_args[i], "--agents=")) {
            agent_count = std.fmt.parseInt(u32, sub_args[i][9..], 10) catch 3;
        } else if (task_description == null) {
            task_description = sub_args[i];
        }
    }

    const task = task_description orelse {
        stdout_print("Error: no task description provided\n", .{});
        return;
    };

    if (agent_count == 0) agent_count = 1;
    if (agent_count > 10) agent_count = 10;

    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    const result = engine.spawnTeam(task, agent_count) catch {
        stdout_print("Error: failed to spawn team\n", .{});
        return;
    };
    defer result.deinit(allocator);

    stdout_print("\n=== Team Spawned ===\n", .{});
    stdout_print("  Team ID:   {s}\n", .{result.team_id});
    stdout_print("  Team Name: {s}\n", .{result.team_name});
    stdout_print("  Task:      {s}\n", .{task});
    stdout_print("  Agents:    {d}\n", .{result.agent_count});
    stdout_print("  Est. Cost: ${d:.4}\n", .{result.total_estimated_cost});
    stdout_print("\n  Agent Composition:\n", .{});

    for (result.agents, 0..) |agent, idx| {
        stdout_print("    {d}. {s} [{s}] → {s}\n", .{
            idx + 1,
            agent.agent_name,
            @tagName(agent.specialty),
            agent.model,
        });
    }

    stdout_print("\n  Plan ({d} phases):\n", .{result.plan.total_phases});
    for (result.plan.phases, 0..) |phase, idx| {
        const parallel_marker: []const u8 = if (phase.is_parallel) " (parallel)" else "";
        stdout_print("    {d}. {s} — {s} [{s}] ~{d} tokens ${d:.4}{s}\n", .{
            idx + 1,
            phase.phase_name,
            phase.phase_description,
            phase.recommended_model,
            phase.estimated_tokens,
            phase.estimated_cost,
            parallel_marker,
        });
    }

    stdout_print("\nUse `crushcode team status {s}` to check progress.\n", .{result.team_id});
}

fn handleTeamStatus(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    if (sub_args.len > 0) {
        const team_id = sub_args[0];
        const status_text = engine.getTeamStatus(team_id) orelse {
            stdout_print("Team not found: {s}\n", .{team_id});
            return;
        };
        defer allocator.free(status_text);
        stdout_print("{s}\n", .{status_text});
    } else {
        engine.printStats();
    }
}

fn handleTeamMessage(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (sub_args.len < 3) {
        stdout_print("Usage: crushcode team message <from_id> <to_id> \"<message>\"\n", .{});
        return;
    }

    const from_id = sub_args[0];
    const to_id = sub_args[1];
    const content = sub_args[2];

    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    engine.coordinator.sendMessage(from_id, to_id, .coordination, content) catch {
        stdout_print("Error: failed to send message\n", .{});
        return;
    };

    stdout_print("Message sent: {s} → {s}\n", .{ from_id, to_id });
}

fn handleTeamList(allocator: std.mem.Allocator) void {
    var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
        stdout_print("Error: failed to initialize orchestration engine\n", .{});
        return;
    };
    defer engine.deinit();

    const caps = engine.listCapabilities();
    const team_count = engine.coordinator.teams.items.len;

    stdout_print("\n=== Orchestration Engine ===\n", .{});
    stdout_print("  Teams:         {d}\n", .{team_count});
    stdout_print("  Capabilities:  {d}\n", .{caps.len});
    stdout_print("  WorkerRunner:  {s}\n", .{if (engine.hasWorkerRunner()) "available" else "unavailable"});

    if (team_count == 0 and caps.len == 0) {
        stdout_print("\n  No teams or capabilities. Use `crushcode team spawn \"<task>\"` to create one.\n", .{});
    }

    if (team_count > 0) {
        stdout_print("\n  Teams:\n", .{});
        for (engine.coordinator.teams.items, 0..) |team, idx| {
            stdout_print("    {d}. {s} [{s}] — {d} agents\n", .{
                idx + 1,
                team.name,
                team.id,
                team.agents.items.len,
            });
        }
    }

    if (caps.len > 0) {
        stdout_print("\n  Capabilities:\n", .{});
        for (caps, 0..) |cap, idx| {
            stdout_print("    {d}. {s} ({d} phases)\n", .{ idx + 1, cap.name, cap.phases.items.len });
        }
    }
    stdout_print("\n", .{});
}

/// Global background agent manager (persists across commands in same process)
var global_bg_manager: ?background_agent_mod.BackgroundAgentManager = null;

fn getOrCreateBgManager(allocator: std.mem.Allocator) *background_agent_mod.BackgroundAgentManager {
    if (global_bg_manager == null) {
        global_bg_manager = background_agent_mod.BackgroundAgentManager.init(allocator, ".crushcode/background/results/") catch {
            stdout_print("Error: failed to initialize background agent manager\n", .{});
            return &global_bg_manager.?;
        };
        global_bg_manager.?.registerDefaults() catch {};
    }
    return &global_bg_manager.?;
}

/// Handle `crushcode bg <subcommand>` — background agent scheduler management.
/// Subcommands:
///   list                        Show all background agents with last run time and status
///   run <agent_name>            Manually trigger a background agent
///   status [agent_name]         Detailed status of specific agent
///   schedule                    Show when each agent is next scheduled to run
///   results <agent_name>        Show recent results for an agent
pub fn handleBackground(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode bg <list|run|status|schedule|results> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  list                Show all background agents\n", .{});
        stdout_print("  run <agent_name>    Manually trigger a background agent\n", .{});
        stdout_print("  status [agent]      Show detailed agent status\n", .{});
        stdout_print("  schedule            Show next scheduled run times\n", .{});
        stdout_print("  results <agent>     Show recent results for agent\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};
    const manager = getOrCreateBgManager(allocator);

    if (std.mem.eql(u8, subcommand, "list")) {
        const listing = manager.listAgents(allocator) catch {
            stdout_print("Error listing agents\n", .{});
            return;
        };
        defer allocator.free(listing);
        stdout_print("{s}\n", .{listing});
    } else if (std.mem.eql(u8, subcommand, "run")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode bg run <agent_name>\n", .{});
            stdout_print("\nAvailable agents:\n", .{});
            for (manager.agents.items) |agent| {
                stdout_print("  {s} ({s})\n", .{ agent.id, agent.name });
            }
            return;
        }
        const agent_name = sub_args[0];
        const agent = manager.findAgentByName(agent_name) orelse {
            stdout_print("Agent not found: {s}\n", .{agent_name});
            stdout_print("Use 'crushcode bg list' to see available agents.\n", .{});
            return;
        };

        stdout_print("\nRunning agent: {s}\n", .{agent.name});
        const result = manager.runAgent(agent.id) catch |err| {
            stdout_print("Error running agent: {}\n", .{err});
            return;
        };

        if (result) |r| {
            defer r.deinit(allocator);
            stdout_print("\n=== Agent Result ===\n", .{});
            stdout_print("  Agent:   {s}\n", .{r.agent_name});
            stdout_print("  Status:  {s}\n", .{@tagName(r.status)});
            stdout_print("  Output:  {s}\n", .{r.output_path});
            if (r.started_at != 0) stdout_print("  Started: {d}\n", .{r.started_at});
            if (r.completed_at) |ct| stdout_print("  Ended:   {d}\n", .{ct});
            if (r.error_message) |msg| stdout_print("  Error:   {s}\n", .{msg});
        } else {
            stdout_print("Agent not found or could not run: {s}\n", .{agent_name});
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        if (sub_args.len == 0) {
            // Show status of all agents
            for (manager.agents.items) |agent| {
                const status_str = agent.getFormattedStatus(allocator) catch continue;
                defer allocator.free(status_str);
                stdout_print("\n{s}\n", .{status_str});
            }
            return;
        }
        const agent_name = sub_args[0];
        const agent = manager.findAgentByName(agent_name) orelse {
            stdout_print("Agent not found: {s}\n", .{agent_name});
            return;
        };
        const status_str = agent.getFormattedStatus(allocator) catch {
            stdout_print("Error getting status for {s}\n", .{agent_name});
            return;
        };
        defer allocator.free(status_str);
        stdout_print("\n{s}\n", .{status_str});
    } else if (std.mem.eql(u8, subcommand, "schedule")) {
        const schedule_str = manager.listSchedule(allocator) catch {
            stdout_print("Error generating schedule\n", .{});
            return;
        };
        defer allocator.free(schedule_str);
        stdout_print("{s}\n", .{schedule_str});
    } else if (std.mem.eql(u8, subcommand, "results")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode bg results <agent_name>\n", .{});
            return;
        }
        const agent_name = sub_args[0];
        const agent = manager.findAgentByName(agent_name) orelse {
            stdout_print("Agent not found: {s}\n", .{agent_name});
            return;
        };

        const results = manager.getResults(agent.id, 10);
        defer {
            for (results) |*r| {
                var mut_r = r;
                mut_r.deinit(allocator);
            }
            allocator.free(results);
        }

        stdout_print("\n=== Results for {s} ===\n", .{agent.name});
        if (results.len == 0) {
            stdout_print("  No results yet.\n", .{});
        } else {
            for (results, 0..) |r, idx| {
                stdout_print("\n  {d}. Status: {s}\n", .{ idx + 1, @tagName(r.status) });
                stdout_print("     Output: {s}\n", .{r.output_path});
                stdout_print("     Started: {d}\n", .{r.started_at});
                if (r.completed_at) |ct| {
                    const duration = ct - r.started_at;
                    stdout_print("     Duration: {d}ms\n", .{duration});
                }
                if (r.error_message) |msg| {
                    stdout_print("     Error: {s}\n", .{msg});
                }
            }
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: list, run, status, schedule, or results\n", .{});
    }
}
