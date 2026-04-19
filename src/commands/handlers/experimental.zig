const std = @import("std");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const graph_mod = @import("graph");
const agent_loop_mod = @import("agent_loop");
const workflow_mod = @import("workflow");
const compaction_mod = @import("compaction");
const scaffold_mod = @import("scaffold");
const knowledge_schema = @import("knowledge_schema");
const knowledge_vault_mod = @import("knowledge_vault_mod");
const knowledge_ingest_mod = @import("knowledge_ingest_mod");
const knowledge_query_mod = @import("knowledge_query_mod");
const knowledge_lint_mod = @import("knowledge_lint_mod");
const knowledge_persistence_mod = @import("knowledge_persistence_mod");
const worker_mod = @import("worker");
const worker_runner_mod = @import("worker_runner");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const skills_resolver = @import("skills_resolver");
const skills_agents_parser = @import("skills_agents_parser");
const skills_loader_mod = @import("skills_loader");
const hooks_executor_mod = @import("hooks_executor");
const lifecycle = @import("lifecycle_hooks");
const coordinator_mod = @import("coordinator");
const background_agent_mod = @import("background_agent");
const layered_memory_mod = @import("layered_memory");
const adversarial_mod = @import("adversarial");
const skill_pipeline_mod = @import("skill_pipeline");
const skill_sync_mod = @import("skill_sync");
const template_mod = @import("template");
const file_type_mod = @import("file_type");
const phase_runner_mod = @import("phase_runner");
const cognition_mod = @import("cognition");
const guardian_mod = @import("guardian");
const autopilot_mod = @import("autopilot");
const orchestration_mod = @import("orchestration");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleGraph(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Check for subcommands
    if (args.remaining.len > 0 and std.mem.eql(u8, args.remaining[0], "analyze")) {
        try handleGraphAnalyze(args);
        return;
    }

    var kg = graph_mod.KnowledgeGraph.init(allocator);
    defer kg.deinit();

    if (args.remaining.len > 0) {
        for (args.remaining) |file_path| {
            stdout_print("Indexing: {s}\n", .{file_path});
            kg.indexFile(file_path) catch |err| {
                stdout_print("  Error indexing {s}: {}\n", .{ file_path, err });
            };
        }
    } else {
        const default_files = [_][]const u8{
            "src/main.zig",
            "src/ai/client.zig",
            "src/ai/registry.zig",
            "src/commands/handlers.zig",
            "src/commands/chat.zig",
            "src/config/config.zig",
            "src/cli/args.zig",
        };
        stdout_print("Indexing default source files...\n\n", .{});
        for (&default_files) |file_path| {
            kg.indexFile(file_path) catch continue;
        }
    }
}

/// Handle `crushcode autopilot <subcommand>` — autopilot agents wired to real work.
/// Subcommands:
///   run <agent-id>      Run a specific autopilot agent with real pipeline work
///   status <agent-id>   Show agent status
///   list                List all autopilot agents
///   schedule            Show next scheduled run times
///   run-all             Run all scheduled agents
pub fn handleAutopilot(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode autopilot <run|status|list|schedule|run-all> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  run <agent-id>      Run autopilot agent with real pipeline work\n", .{});
        stdout_print("  status <agent-id>   Show agent status\n", .{});
        stdout_print("  list                List all autopilot agents\n", .{});
        stdout_print("  schedule            Show next scheduled run times\n", .{});
        stdout_print("  run-all             Run all scheduled agents\n", .{});
        stdout_print("\nAgents: morning-refresh, nightly-consolidate, weekly-review, health-check\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcommand, "list")) {
        var pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch return;
        defer pipeline.deinit();
        var engine = autopilot_mod.AutopilotEngine.init(allocator, &pipeline, null, ".", ".crushcode/autopilot/") catch return;
        defer engine.deinit();
        const listing = engine.listAgents(allocator) catch return;
        defer allocator.free(listing);
        stdout_print("{s}\n", .{listing});
        return;
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode autopilot run <agent-id>\n", .{});
            stdout_print("\nAvailable agents:\n", .{});
            stdout_print("  morning-refresh      Reindex knowledge graph (50 files)\n", .{});
            stdout_print("  nightly-consolidate  Sync vault to memory, distill insights\n", .{});
            stdout_print("  weekly-review        Full scan (200 files) + consolidation\n", .{});
            stdout_print("  health-check         Read-only pipeline health diagnostics\n", .{});
            return;
        }
        const agent_id = sub_args[0];

        // Create pipeline with memory support
        var pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch {
            stdout_print("Error: failed to initialize knowledge pipeline\n", .{});
            return;
        };
        defer pipeline.deinit();

        // Create guardian (graceful degradation if fails)
        var guardian: ?guardian_mod.Guardian = guardian_mod.Guardian.init(allocator) catch null;
        defer if (guardian != null) guardian.?.deinit();

        var engine = autopilot_mod.AutopilotEngine.init(
            allocator,
            &pipeline,
            if (guardian != null) &guardian.? else null,
            ".",
            ".crushcode/autopilot/",
        ) catch {
            stdout_print("Error: failed to initialize autopilot engine\n", .{});
            return;
        };
        defer engine.deinit();

        stdout_print("\nRunning autopilot agent: {s}\n", .{agent_id});

        var result = engine.runAgentWork(agent_id) catch |err| {
            if (err == autopilot_mod.AutopilotError.AgentNotFound) {
                stdout_print("Error: agent '{s}' not found\n", .{agent_id});
                stdout_print("Use: morning-refresh, nightly-consolidate, weekly-review, or health-check\n", .{});
            } else {
                stdout_print("Error running agent: {}\n", .{err});
            }
            return;
        };
        defer result.deinit(allocator);

        stdout_print("\n=== Autopilot Result ===\n", .{});
        stdout_print("  Agent:    {s}\n", .{result.agent_id});
        stdout_print("  Kind:     {s}\n", .{@tagName(result.agent_kind)});
        stdout_print("  Status:   {s}\n", .{@tagName(result.status)});
        stdout_print("  Summary:  {s}\n", .{result.work_summary});
        stdout_print("  Scanned:  {d}\n", .{result.files_scanned});
        stdout_print("  Indexed:  {d}\n", .{result.files_indexed});
        stdout_print("  Vault:    {d}\n", .{result.vault_nodes});
        stdout_print("  Graph:    {d}\n", .{result.graph_nodes});
        stdout_print("  Insights: {d}\n", .{result.insights_created});
        if (result.error_message) |msg| {
            stdout_print("  Error:    {s}\n", .{msg});
        }
        stdout_print("\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "status")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode autopilot status <agent-id>\n", .{});
            return;
        }
        const agent_id = sub_args[0];

        var pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch return;
        defer pipeline.deinit();
        var engine = autopilot_mod.AutopilotEngine.init(allocator, &pipeline, null, ".", ".crushcode/autopilot/") catch return;
        defer engine.deinit();

        const status_str = engine.getAgentStatus(agent_id) orelse {
            stdout_print("Agent not found: {s}\n", .{agent_id});
            return;
        };
        defer allocator.free(status_str);
        stdout_print("{s}\n", .{status_str});
        return;
    }

    if (std.mem.eql(u8, subcommand, "schedule")) {
        var pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch return;
        defer pipeline.deinit();
        var engine = autopilot_mod.AutopilotEngine.init(allocator, &pipeline, null, ".", ".crushcode/autopilot/") catch return;
        defer engine.deinit();

        const schedule = engine.bg_manager.listSchedule(allocator) catch return;
        defer allocator.free(schedule);
        stdout_print("{s}\n", .{schedule});
        return;
    }

    if (std.mem.eql(u8, subcommand, "run-all")) {
        var pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch return;
        defer pipeline.deinit();
        var guardian: ?guardian_mod.Guardian = guardian_mod.Guardian.init(allocator) catch null;
        defer if (guardian != null) guardian.?.deinit();
        var engine = autopilot_mod.AutopilotEngine.init(
            allocator,
            &pipeline,
            if (guardian != null) &guardian.? else null,
            ".",
            ".crushcode/autopilot/",
        ) catch return;
        defer engine.deinit();

        stdout_print("\nRunning all scheduled autopilot agents...\n\n", .{});
        engine.runScheduledWork() catch {};
        engine.printStats();
        return;
    }

    stdout_print("Unknown subcommand: {s}\n", .{subcommand});
    stdout_print("Use: run, status, list, schedule, or run-all\n", .{});
}

/// Handle `crushcode graph analyze` — compute PageRank and print top important files
fn handleGraphAnalyze(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var kg = graph_mod.KnowledgeGraph.init(allocator);
    defer kg.deinit();

    // Parse --top N flag
    var top_n: u32 = 10;
    var file_start: usize = args.remaining.len; // default: no files
    var i: usize = 1; // skip "analyze"
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--top")) {
            i += 1;
            if (i < args.remaining.len) {
                top_n = std.fmt.parseInt(u32, args.remaining[i], 10) catch 10;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--top=")) {
            top_n = std.fmt.parseInt(u32, args.remaining[i][6..], 10) catch 10;
        } else {
            // First non-flag argument = start of file list
            file_start = i;
            break;
        }
    }

    // Index files
    const has_files = file_start < args.remaining.len;
    if (has_files) {
        for (args.remaining[file_start..]) |file_path| {
            stdout_print("Indexing: {s}\n", .{file_path});
            kg.indexFile(file_path) catch |err| {
                stdout_print("  Error indexing {s}: {}\n", .{ file_path, err });
            };
        }
    } else if (!has_files) {
        const default_files = [_][]const u8{
            "src/main.zig",
            "src/ai/client.zig",
            "src/ai/registry.zig",
            "src/commands/handlers.zig",
            "src/commands/chat.zig",
            "src/config/config.zig",
            "src/cli/args.zig",
            "src/graph/graph.zig",
            "src/graph/types.zig",
            "src/graph/algorithms.zig",
        };
        stdout_print("Indexing default source files...\n\n", .{});
        for (&default_files) |file_path| {
            kg.indexFile(file_path) catch continue;
        }
    }

    stdout_print("\n=== Graph Analysis ===\n", .{});
    stdout_print("Nodes: {d} | Edges: {d}\n\n", .{ kg.nodes.count(), kg.edges.items.len });

    // PageRank
    stdout_print("--- PageRank (Top {d} Important Nodes) ---\n", .{top_n});
    var pr = kg.computePageRank(allocator) catch return;
    defer pr.deinit();

    // Sort by rank descending
    var rank_entries = array_list_compat.ArrayList(struct { []const u8, f64 }).init(allocator);
    defer rank_entries.deinit();

    var pr_iter = pr.ranks.iterator();
    while (pr_iter.next()) |entry| {
        rank_entries.append(.{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
    }

    std.sort.insertion(@TypeOf(rank_entries.items[0]), rank_entries.items, {}, struct {
        fn cmp(_: void, a: @TypeOf(rank_entries.items[0]), b: @TypeOf(rank_entries.items[0])) bool {
            return a[1] > b[1];
        }
    }.cmp);

    const limit = @min(top_n, @as(u32, @intCast(rank_entries.items.len)));
    for (rank_entries.items[0..limit], 0..) |entry, idx| {
        stdout_print("  {d:2}. {s} (rank: {d:.4})\n", .{ idx + 1, entry[0], entry[1] });
    }

    // Bridge detection
    stdout_print("\n--- Bridge Nodes (Articulation Points) ---\n", .{});
    const bridges = kg.findBridges(allocator) catch &[_][]const u8{};
    defer {
        for (bridges) |id| allocator.free(id);
        allocator.free(bridges);
    }
    if (bridges.len == 0) {
        stdout_print("  No bridge nodes detected\n", .{});
    } else {
        for (bridges, 0..) |id, idx| {
            stdout_print("  {d}. {s}\n", .{ idx + 1, id });
        }
    }

    // Tag clustering
    stdout_print("\n--- Tag Clusters ---\n", .{});
    const clusters_err = kg.clusterByTags(allocator);
    if (clusters_err) |clusters| {
        defer {
            for (clusters) |*c| c.deinit();
            allocator.free(clusters);
        }
        for (clusters, 0..) |cluster, idx| {
            stdout_print("  {d}. {s} ({d} nodes)\n", .{ idx + 1, cluster.tag, cluster.node_ids.items.len });
        }
    } else |_| {
        stdout_print("  Could not compute clusters\n", .{});
    }
}

/// Agent loop context — shared state for the AI send callback
var global_agent_ctx: AgentContext = undefined;

/// Agent Loop Engine — uses real AI client to process user requests with tool-calling loop
const AgentContext = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    model: []const u8,
    api_key: []const u8,
    base_url: []const u8,
};

pub fn handleAgentLoop(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Load config by reading config.toml directly
    const config_path = resolveConfigPath(allocator) catch {
        stdout_print("Error: could not resolve config path\n", .{});
        return;
    };
    defer allocator.free(config_path);

    var provider_name: []const u8 = "ollama";
    var model: []const u8 = "gemma4:31b-cloud";
    var api_key: []const u8 = "";

    // Parse config.toml for default_provider, default_model, and API key
    parseConfigToml(allocator, config_path, &provider_name, &model, &api_key) catch |err| {
        stdout_print("Warning: could not parse config ({}) — using defaults\n", .{err});
    };

    // Resolve base URL from provider name
    const base_url = providerBaseUrl(provider_name);
    if (base_url.len == 0) {
        stdout_print("Error: unknown provider '{s}'\n", .{provider_name});
        return;
    }

    stdout_print("\nAgent Loop: Using {s}/{s}\n", .{ provider_name, model });

    // Set up agent loop
    var agent = agent_loop_mod.AgentLoop.init(allocator);
    defer agent.deinit();

    var config = agent_loop_mod.LoopConfig.init();
    config.max_iterations = 15;
    config.show_intermediate = true;
    agent.setConfig(config);

    // Register real tool executors
    agent.registerTool("read_file", toolReadFile) catch |err| {
        stdout_print("Warning: could not register read_file tool: {}\n", .{err});
    };
    agent.registerTool("bash", toolBash) catch |err| {
        stdout_print("Warning: could not register bash tool: {}\n", .{err});
    };

    agent.printStatus();

    // Prepare the AI context for the send callback
    global_agent_ctx = AgentContext{
        .allocator = allocator,
        .provider_name = provider_name,
        .model = model,
        .api_key = api_key,
        .base_url = base_url,
    };

    // Get user message from args or use default
    const user_message = if (args.remaining.len > 0)
        args.remaining[0]
    else
        "Analyze the current project and summarize what it does";

    stdout_print("\n--- Running agent loop ---\n", .{});
    stdout_print("User: {s}\n\n", .{user_message});

    var result = agent.run(agentLoopSend, user_message) catch {
        stdout_print("Error: agent loop failed\n", .{});
        return;
    };
    defer result.deinit();

    stdout_print("\n--- Agent Loop Result ---\n", .{});
    stdout_print("  Final response: {s}\n", .{result.final_response});
    stdout_print("  Iterations: {d}\n", .{result.total_iterations});
    stdout_print("  Tool calls: {d}\n", .{result.total_tool_calls});
    stdout_print("  Retries: {d}\n", .{result.total_retries});
    stdout_print("  Steps: {d}\n", .{result.steps.items.len});

    for (result.steps.items, 0..) |step, i| {
        stdout_print("\n  Step {d}:\n", .{i + 1});
        stdout_print("    AI: {s}\n", .{step.ai_response});
        stdout_print("    Finish: {s}\n", .{step.finish_reason});
        if (step.has_tool_calls) {
            for (step.tool_calls.items) |tc| {
                stdout_print("    Tool call: {s}({s})\n", .{ tc.name, tc.arguments });
            }
            for (step.tool_results.items) |tr| {
                const status = if (tr.success) "OK" else "FAIL";
                stdout_print("    Tool result [{s}]: {s}\n", .{ status, tr.output });
            }
        }
    }
}

/// Resolve the config file path (~/.config/crushcode/config.toml)
fn resolveConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    // Check CRUSHCODE_CONFIG env var first
    if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_CONFIG")) |path| {
        return path;
    } else |_| {}

    // XDG_CONFIG_HOME/crushcode/config.toml or ~/.config/crushcode/config.toml
    const config_dir = if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "crushcode" })
    else |_| blk: {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".config", "crushcode" });
    };
    defer allocator.free(config_dir);

    return std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
}

/// Parse config.toml to extract default_provider, default_model, and the API key for the provider.
/// Simple line-by-line TOML parsing — extracts the fields we need without a full parser.
fn parseConfigToml(allocator: std.mem.Allocator, config_path: []const u8, provider_name: *[]const u8, model: *[]const u8, api_key: *[]const u8) !void {
    const file = std.fs.cwd().openFile(config_path, .{}) catch return;
    defer file.close();

    const file_size = try file.getEndPos();
    const buf = try allocator.alloc(u8, file_size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    var line_iter = std.mem.splitScalar(u8, buf, '\n');
    var in_api_keys_section = false;

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "[")) {
            in_api_keys_section = std.mem.eql(u8, trimmed, "[api_keys]");
            continue;
        }

        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

        if (std.mem.eql(u8, key, "default_provider")) {
            provider_name.* = value;
        } else if (std.mem.eql(u8, key, "default_model")) {
            model.* = value;
        } else if (in_api_keys_section) {
            // Check if this key matches the resolved provider name
            if (std.mem.eql(u8, key, provider_name.*)) {
                api_key.* = value;
            }
        }
    }
}

/// Get the base URL for a provider name
fn providerBaseUrl(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, name, "anthropic")) return "https://api.anthropic.com/v1";
    if (std.mem.eql(u8, name, "gemini")) return "https://generativelanguage.googleapis.com/v1";
    if (std.mem.eql(u8, name, "xai")) return "https://api.x.ai/v1";
    if (std.mem.eql(u8, name, "mistral")) return "https://api.mistral.ai/v1";
    if (std.mem.eql(u8, name, "groq")) return "https://api.groq.com/openai/v1";
    if (std.mem.eql(u8, name, "deepseek")) return "https://api.deepseek.com/v1";
    if (std.mem.eql(u8, name, "together")) return "https://api.together.xyz/v1";
    if (std.mem.eql(u8, name, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, name, "ollama")) return "http://localhost:11434/api";
    if (std.mem.eql(u8, name, "lm-studio")) return "http://localhost:1234/v1";
    if (std.mem.eql(u8, name, "llama-cpp")) return "http://localhost:8080/v1";
    if (std.mem.eql(u8, name, "zai")) return "https://api.z.ai/v1";
    if (std.mem.eql(u8, name, "vercel-gateway")) return "https://sdk.vercel.ai/api/v1";
    return "";
}

/// Get the chat endpoint path for a provider
fn chatPathForProvider(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "ollama")) return "/chat";
    return "/chat/completions";
}

/// Agent loop AI send callback — delegates to realAISend using global context
fn agentLoopSend(allocator: std.mem.Allocator, messages: []const agent_loop_mod.LoopMessage) anyerror!agent_loop_mod.AIResponse {
    return realAISend(allocator, messages, &global_agent_ctx);
}

/// Real AI send function — converts LoopMessage history to HTTP request and returns AIResponse
fn realAISend(allocator: std.mem.Allocator, messages: []const agent_loop_mod.LoopMessage, ctx: *const AgentContext) !agent_loop_mod.AIResponse {
    // Build JSON body with message history
    var json_body = array_list_compat.ArrayList(u8).init(allocator);
    defer json_body.deinit();

    // Strip provider prefix from model name (e.g. "openai/gpt-4o" → "gpt-4o")
    const api_model = if (std.mem.indexOfScalar(u8, ctx.model, '/')) |idx|
        ctx.model[idx + 1 ..]
    else
        ctx.model;

    try json_body.writer().print("{{\"model\":\"{s}\",\"messages\":[", .{api_model});

    for (messages, 0..) |msg, i| {
        if (i > 0) try json_body.appendSlice(",");
        try json_body.appendSlice("{\"role\":\"");
        try json_body.appendSlice(msg.role);
        try json_body.appendSlice("\",\"content\":\"");
        // Escape JSON string content
        for (msg.content) |c| {
            switch (c) {
                '"' => try json_body.appendSlice("\\\""),
                '\\' => try json_body.appendSlice("\\\\"),
                '\n' => try json_body.appendSlice("\\n"),
                '\r' => try json_body.appendSlice("\\r"),
                '\t' => try json_body.appendSlice("\\t"),
                else => try json_body.append(c),
            }
        }
        try json_body.appendSlice("\"}");
        // Include tool_call_id if present (tool result messages)
        if (msg.tool_call_id) |tc_id| {
            // Replace the closing } — we already wrote it, so rewrite the tail
            json_body.items.len -= 1; // remove trailing }
            try json_body.writer().print(",\"tool_call_id\":\"{s}\"}}", .{tc_id});
        }
    }

    try json_body.writer().print("],\"max_tokens\":{d},\"temperature\":{d:.2}}}", .{ 4096, 0.7 });

    // Build endpoint URL
    const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ ctx.base_url, chatPathForProvider(ctx.provider_name) });
    defer allocator.free(endpoint);

    // Build headers
    var headers = array_list_compat.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });

    if (std.mem.eql(u8, ctx.provider_name, "openrouter")) {
        try headers.append(.{ .name = "HTTP-Referer", .value = "https://github.com/crushcode/crushcode" });
        try headers.append(.{ .name = "X-Title", .value = "Crushcode" });
    }

    if (ctx.api_key.len > 0) {
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{ctx.api_key});
        defer allocator.free(auth);
        try headers.append(.{ .name = "Authorization", .value = auth });
    }

    // Make HTTP request
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(endpoint) catch return error.NetworkError;

    var request = client.request(.POST, uri, .{
        .extra_headers = headers.items,
    }) catch return error.NetworkError;
    defer request.deinit();

    const body_slice = json_body.items;
    request.transfer_encoding = .{ .content_length = body_slice.len };

    var body = request.sendBodyUnflushed(&.{}) catch return error.NetworkError;
    body.writer.writeAll(body_slice) catch return error.NetworkError;
    body.end() catch return error.NetworkError;
    request.connection.?.flush() catch return error.NetworkError;

    var response = request.receiveHead(&.{}) catch return error.NetworkError;

    // Read response body
    var response_buf: [8192]u8 = undefined;
    var response_body = array_list_compat.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    var response_transfer_buffer: [8192]u8 = undefined;
    const resp_reader = response.reader(&response_transfer_buffer);
    while (true) {
        const bytes_read = resp_reader.readSliceShort(&response_buf) catch return error.NetworkError;
        if (bytes_read == 0) break;
        try response_body.appendSlice(response_buf[0..bytes_read]);
    }

    const status = response.head.status;
    if (status != .ok) {
        const err_content = if (response_body.items.len > 0)
            response_body.items[0..@min(200, response_body.items.len)]
        else
            "unknown error";
        std.log.err("AI request failed with status {}: {s}", .{ status, err_content });
        return agent_loop_mod.AIResponse{
            .content = "Error: AI request failed",
            .finish_reason = .error_unknown,
            .tool_calls = &.{},
        };
    }

    // Parse response — handle Ollama multi-line JSON vs standard single-object JSON
    if (std.mem.eql(u8, ctx.provider_name, "ollama")) {
        return parseOllamaResponse(allocator, response_body.items);
    }

    return parseOpenAIResponse(allocator, response_body.items);
}

/// Parse a standard OpenAI-format chat completion response
fn parseOpenAIResponse(allocator: std.mem.Allocator, body: []const u8) !agent_loop_mod.AIResponse {
    const Parsed = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    id: []const u8,
                    function: struct {
                        name: []const u8,
                        arguments: []const u8,
                    },
                } = null,
            },
            finish_reason: ?[]const u8 = null,
        },
    };

    var parsed = try std.json.parseFromSlice(Parsed, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) {
        return agent_loop_mod.AIResponse{
            .content = "",
            .finish_reason = .stop,
            .tool_calls = &.{},
        };
    }

    const choice = parsed.value.choices[0];
    const content = choice.message.content orelse "";
    const finish_str = choice.finish_reason orelse "stop";

    const finish_reason: agent_loop_mod.AIResponse.FinishReason =
        if (std.mem.eql(u8, finish_str, "stop") or std.mem.eql(u8, finish_str, "end_turn"))
            .stop
        else if (std.mem.eql(u8, finish_str, "tool_calls") or std.mem.eql(u8, finish_str, "function_call"))
            .tool_calls
        else if (std.mem.eql(u8, finish_str, "length"))
            .length
        else
            .error_unknown;

    // Convert tool calls if present
    const tc_raw = choice.message.tool_calls orelse null;
    var tool_calls_list = array_list_compat.ArrayList(ai_types.ToolCallInfo).init(allocator);
    defer tool_calls_list.deinit();

    if (tc_raw) |calls| {
        for (calls) |tc| {
            try tool_calls_list.append(.{
                .id = tc.id,
                .name = tc.function.name,
                .arguments = tc.function.arguments,
            });
        }
    }

    const content_owned = try allocator.dupe(u8, content);
    const tc_owned = if (tool_calls_list.items.len > 0)
        try allocator.dupe(ai_types.ToolCallInfo, tool_calls_list.items)
    else
        &.{};

    return agent_loop_mod.AIResponse{
        .content = content_owned,
        .finish_reason = finish_reason,
        .tool_calls = tc_owned,
    };
}

/// Parse an Ollama multi-line streaming response into a single AIResponse
fn parseOllamaResponse(allocator: std.mem.Allocator, body: []const u8) !agent_loop_mod.AIResponse {
    const OllamaChunk = struct {
        message: struct { content: ?[]const u8 = null },
        done: bool = false,
    };

    var full_content = array_list_compat.ArrayList(u8).init(allocator);
    defer full_content.deinit();

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var chunk = std.json.parseFromSlice(OllamaChunk, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer chunk.deinit();
        if (chunk.value.message.content) |c| {
            try full_content.appendSlice(c);
        }
    }

    return agent_loop_mod.AIResponse{
        .content = try allocator.dupe(u8, full_content.items),
        .finish_reason = .stop,
        .tool_calls = &.{},
    };
}

/// Real read_file tool — reads a file from the filesystem
fn toolReadFile(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    // arguments is expected to be a file path (or JSON with "path" field)
    const file_path = extractPathFromArgs(arguments);
    if (file_path.len == 0) {
        return agent_loop_mod.ToolResult.init(allocator, call_id, "Error: no file path provided", false);
    }

    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Error reading '{s}': {}", .{ file_path, err });
        defer allocator.free(err_msg);
        return agent_loop_mod.ToolResult.init(allocator, call_id, err_msg, false);
    };
    // ToolResult.init dupes the output, so free the original
    defer allocator.free(content);

    return agent_loop_mod.ToolResult.init(allocator, call_id, content, true);
}

/// Real bash tool — executes a shell command and returns stdout/stderr
fn toolBash(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    const cmd = extractPathFromArgs(arguments);
    if (cmd.len == 0) {
        return agent_loop_mod.ToolResult.init(allocator, call_id, "Error: no command provided", false);
    }

    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const result = child.spawnAndWait() catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Error running command: {}", .{err});
        defer allocator.free(err_msg);
        return agent_loop_mod.ToolResult.init(allocator, call_id, err_msg, false);
    };

    // Read stdout if available
    var output_buf: [4096]u8 = undefined;
    var output = array_list_compat.ArrayList(u8).init(allocator);
    defer output.deinit();

    if (child.stdout) |stdout| {
        while (true) {
            const n = stdout.read(&output_buf) catch break;
            if (n == 0) break;
            try output.appendSlice(output_buf[0..n]);
        }
    }

    if (child.stderr) |stderr| {
        while (true) {
            const n = stderr.read(&output_buf) catch break;
            if (n == 0) break;
            if (output.items.len > 0) try output.appendSlice("\n");
            try output.appendSlice(output_buf[0..n]);
        }
    }

    const success = switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };

    const output_str = if (output.items.len > 0) output.items else "(no output)";
    return agent_loop_mod.ToolResult.init(allocator, call_id, output_str, success);
}

/// Extract a file path or command from tool arguments.
/// Handles both bare strings and JSON like {"path": "..."} or {"command": "..."}
fn extractPathFromArgs(args: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args, " \t\n\r");
    if (trimmed.len == 0) return "";

    // If starts with {, try to parse as JSON and extract first value
    if (trimmed[0] == '{') {
        // Simple extraction: find first quoted value after a colon
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            var start = colon_pos + 1;
            while (start < trimmed.len and (trimmed[start] == ' ' or trimmed[start] == '\t' or trimmed[start] == '"')) {
                start += 1;
            }
            if (start < trimmed.len) {
                var end = start;
                while (end < trimmed.len and trimmed[end] != '"' and trimmed[end] != '}') {
                    end += 1;
                }
                return trimmed[start..end];
            }
        }
    }

    return trimmed;
}

pub fn handleWorkflow(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse args: workflow <name> [--phases N]
    var workflow_name: []const u8 = "default-workflow";
    var phase_count: u32 = 3;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--phases")) {
            i += 1;
            if (i < args.remaining.len) {
                phase_count = std.fmt.parseInt(u32, args.remaining[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--phases=")) {
            phase_count = std.fmt.parseInt(u32, args.remaining[i][9..], 10) catch 3;
        } else if (std.mem.startsWith(u8, args.remaining[i], "--xml")) {
            // skip flag
        } else {
            workflow_name = args.remaining[i];
        }
    }

    var workflow = workflow_mod.PhaseWorkflow.init(allocator, workflow_name) catch return;
    defer workflow.deinit();

    // Add N phases with descriptive names and dependencies
    var phase_idx: u32 = 0;
    while (phase_idx < phase_count) : (phase_idx += 1) {
        const phase_num_f64: f64 = @floatFromInt(phase_idx + 1);

        const name = switch (phase_idx) {
            0 => "Phase 1: Setup",
            1 => "Phase 2: Implementation",
            2 => "Phase 3: Testing",
            else => "Additional Phase",
        };
        const goal = switch (phase_idx) {
            0 => "Initialize project structure and dependencies",
            1 => "Build core features and integrations",
            2 => "Write tests and verify functionality",
            else => "Complete additional work",
        };

        const phase = allocator.create(workflow_mod.WorkflowPhase) catch continue;
        phase.* = workflow_mod.WorkflowPhase.init(allocator, phase_num_f64, name, goal) catch continue;
        if (phase_idx > 0) {
            phase.addDependency(@floatFromInt(phase_idx)) catch {};
        }
        workflow.addPhase(phase) catch {};
    }

    // Progress through the lifecycle: complete first half, start one, leave rest pending
    const phases_to_complete = phase_count / 2;
    var p: u32 = 1;
    while (p <= phases_to_complete) : (p += 1) {
        workflow.startPhase(@floatFromInt(p)) catch {};
        workflow.completePhase(@floatFromInt(p)) catch {};
    }
    // Start the next phase (shows running state)
    if (phases_to_complete < phase_count) {
        workflow.startPhase(@floatFromInt(phases_to_complete + 1)) catch {};
    }

    // Print progress view
    workflow.printProgress();

    // Print XML output
    stdout_print("\n--- Workflow XML ---\n", .{});
    const xml = workflow.toXml(allocator) catch return;
    defer allocator.free(xml);
    stdout_print("{s}\n", .{xml});
}

/// Handle `crushcode phase-run [name] [--phases N] [--no-adversarial]`
/// Runs a multi-phase workflow with adversarial gate checks.
pub fn handlePhaseRun(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var phase_count: u32 = 3;
    var plan_name: []const u8 = "default-plan";
    var use_adversarial = true;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--no-adversarial")) {
            use_adversarial = false;
        } else if (std.mem.eql(u8, args.remaining[i], "--phases")) {
            i += 1;
            if (i < args.remaining.len) {
                phase_count = std.fmt.parseInt(u32, args.remaining[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--phases=")) {
            phase_count = std.fmt.parseInt(u32, args.remaining[i][9..], 10) catch 3;
        } else {
            plan_name = args.remaining[i];
        }
    }

    var runner = phase_runner_mod.PhaseRunner.init(allocator, .{
        .name = plan_name,
        .use_adversarial_gates = use_adversarial,
        .verbose = true,
    }) catch return;
    defer runner.deinit();

    // Add phases based on count
    const phase_templates = [_]struct { name: []const u8, goal: []const u8 }{
        .{ .name = "discuss", .goal = "Gather requirements and clarify scope for the user goal objective feature" },
        .{ .name = "plan", .goal = "Create detailed implementation plan with task steps build create write add fix update" },
        .{ .name = "execute", .goal = "Implement the planned changes and build features done complete success finished" },
        .{ .name = "verify", .goal = "Verify implementation meets requirements with test check criteria success pass validate" },
        .{ .name = "ship", .goal = "Ship the verified changes with pass ok success passed green all tests" },
    };
    const count = @min(phase_count, phase_templates.len);
    for (phase_templates[0..count], 0..) |tmpl, idx| {
        const tasks = [1][]const u8{tmpl.goal};
        const phase_num: f64 = @floatFromInt(idx + 1);
        runner.addPhase(phase_num, tmpl.name, tmpl.goal, &tasks) catch continue;
    }

    stdout_print("\n Running workflow: {s} ({d} phases, adversarial={s})\n\n", .{ plan_name, count, if (use_adversarial) "on" else "off" });

    var result = runner.run() catch {
        stdout_print(" Phase runner failed\n", .{});
        return;
    };
    defer result.deinit();

    runner.workflow.printProgress();
    phase_runner_mod.printResult(&result);
}

pub fn handleCompact(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse args: compact <file> [--max-tokens N]
    var file_path: ?[]const u8 = null;
    var max_tokens: u64 = 8000;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--max-tokens")) {
            i += 1;
            if (i < args.remaining.len) {
                max_tokens = std.fmt.parseInt(u64, args.remaining[i], 10) catch 8000;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--max-tokens=")) {
            max_tokens = std.fmt.parseInt(u64, args.remaining[i][13..], 10) catch 8000;
        } else if (file_path == null) {
            file_path = args.remaining[i];
        }
    }

    const path = file_path orelse {
        stdout_print("Usage: crushcode compact <file> [--max-tokens N]\n", .{});
        return;
    };

    // Read file content
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        stdout_print("Error reading file '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(content);

    // Count non-empty lines (first pass)
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    if (line_count == 0) {
        stdout_print("File is empty: {s}\n", .{path});
        return;
    }

    // Allocate messages array and fill from lines (second pass)
    const messages = allocator.alloc(compaction_mod.CompactMessage, line_count) catch return;
    defer allocator.free(messages);

    var msg_idx: usize = 0;
    iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) {
            messages[msg_idx] = .{
                .role = if (msg_idx % 2 == 0) "user" else "assistant",
                .content = line,
                .timestamp = null,
            };
            msg_idx += 1;
        }
    }

    // Create compactor and run compaction
    var compactor = compaction_mod.ContextCompactor.init(allocator, max_tokens);
    defer compactor.deinit();

    var estimated_tokens: u64 = 0;
    for (messages) |msg| {
        estimated_tokens += compaction_mod.ContextCompactor.estimateTokens(msg.content);
    }

    compactor.printStatus(estimated_tokens);

    var result = compactor.compact(messages) catch return;
    defer result.deinit();
    stdout_print("\nCompaction Result:\n", .{});
    stdout_print("  Source file: {s}\n", .{path});
    stdout_print("  Total messages: {d}\n", .{line_count});
    stdout_print("  Messages summarized: {d}\n", .{result.messages_summarized});
    stdout_print("  Tokens saved: {d}\n", .{result.tokens_saved});
    stdout_print("  Recent messages preserved: {d}\n", .{result.messages.len});
    if (result.summary.len > 0) {
        stdout_print("\n--- Generated Summary ---\n{s}\n", .{result.summary});
    }
}

// ============================================================
// Scaffold command helpers
// ============================================================

/// Metadata persisted to .crushcode/scaffold/<name>.json
const ScaffoldMeta = struct {
    name: []const u8,
    description: []const u8 = "A project scaffolded by Crushcode",
    tech_stack: []const []const u8 = &[_][]const u8{},
};

fn showScaffoldUsage() void {
    stdout_print("Usage: crushcode scaffold <subcommand> [args...]\n\n", .{});
    stdout_print("Subcommands:\n", .{});
    stdout_print("  new <name> [--stack tech1,tech2]  Create new project scaffolder\n", .{});
    stdout_print("  generate <name> [--dir <dir>]     Generate PROJECT.md, REQUIREMENTS.md, ROADMAP.md\n", .{});
    stdout_print("  requirements <name>               Show requirements for a project\n", .{});
    stdout_print("  phases <name>                     Show phases for a project\n", .{});
    stdout_print("  list                              List saved scaffolders\n\n", .{});
    stdout_print("Examples:\n", .{});
    stdout_print("  crushcode scaffold new my-app --stack zig,sqlite\n", .{});
    stdout_print("  crushcode scaffold generate my-app\n", .{});
    stdout_print("  crushcode scaffold generate my-app --dir ./docs\n", .{});
}

/// Build a ProjectScaffolder with 3 default requirements and 3 phases.
fn createDefaultScaffolder(allocator: std.mem.Allocator, name: []const u8, desc: []const u8) !scaffold_mod.ProjectScaffolder {
    var scaffolder = try scaffold_mod.ProjectScaffolder.init(allocator, name, desc);
    errdefer scaffolder.deinit();

    // REQ-01: Setup (critical)
    const req1 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req1.* = scaffold_mod.Requirement.init(allocator, "REQ-01", "Setup", .critical) catch return error.OutOfMemory;
    req1.setDescription("Project setup and initial configuration") catch {};
    req1.setCategory("Setup") catch {};
    req1.addCriterion("Project structure created") catch {};
    req1.addCriterion("Build system configured") catch {};
    scaffolder.addRequirement(req1) catch {};

    // REQ-02: Core Features (high)
    const req2 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req2.* = scaffold_mod.Requirement.init(allocator, "REQ-02", "Core Features", .high) catch return error.OutOfMemory;
    req2.setDescription("Implement core functionality") catch {};
    req2.setCategory("Features") catch {};
    req2.addCriterion("Main features working") catch {};
    scaffolder.addRequirement(req2) catch {};

    // REQ-03: Testing (medium)
    const req3 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req3.* = scaffold_mod.Requirement.init(allocator, "REQ-03", "Testing", .medium) catch return error.OutOfMemory;
    req3.setDescription("Write tests for core functionality") catch {};
    req3.setCategory("Testing") catch {};
    req3.addCriterion("Test suite passes") catch {};
    scaffolder.addRequirement(req3) catch {};

    // Phase 1: Foundation
    const ph1 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph1.* = scaffold_mod.ScaffoldPhase.init(allocator, 1, "Foundation") catch return error.OutOfMemory;
    ph1.setDescription("Set up project structure and dependencies") catch {};
    ph1.addRequirement("REQ-01") catch {};
    scaffolder.addPhase(ph1) catch {};

    // Phase 2: Features
    const ph2 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph2.* = scaffold_mod.ScaffoldPhase.init(allocator, 2, "Features") catch return error.OutOfMemory;
    ph2.setDescription("Build core features") catch {};
    ph2.addRequirement("REQ-02") catch {};
    scaffolder.addPhase(ph2) catch {};

    // Phase 3: Polish
    const ph3 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph3.* = scaffold_mod.ScaffoldPhase.init(allocator, 3, "Polish") catch return error.OutOfMemory;
    ph3.setDescription("Testing, documentation, and polish") catch {};
    ph3.addRequirement("REQ-03") catch {};
    scaffolder.addPhase(ph3) catch {};

    return scaffolder;
}

fn scaffoldSavePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".crushcode/scaffold/{s}.json", .{name});
}

/// Persist scaffold metadata (name, description, tech_stack) to disk.
fn saveScaffoldMeta(allocator: std.mem.Allocator, name: []const u8, desc: []const u8, tech_stack: []const []const u8) !void {
    std.fs.cwd().makePath(".crushcode/scaffold") catch {};

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"tech_stack\":[", .{ name, desc });
    for (tech_stack, 0..) |tech, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{tech});
    }
    try writer.writeAll("]}");

    const path = try scaffoldSavePath(allocator, name);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Load scaffold metadata from .crushcode/scaffold/<name>.json. Returns null if not found.
fn loadScaffoldMeta(allocator: std.mem.Allocator, name: []const u8) !?ScaffoldMeta {
    const path = try scaffoldSavePath(allocator, name);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ScaffoldMeta, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Dupe all strings before parsed.deinit() frees the arena
    const duped_name = try allocator.dupe(u8, parsed.value.name);
    const duped_desc = try allocator.dupe(u8, parsed.value.description);
    const duped_stack = try allocator.alloc([]const u8, parsed.value.tech_stack.len);
    for (parsed.value.tech_stack, 0..) |tech, i| {
        duped_stack[i] = try allocator.dupe(u8, tech);
    }

    return ScaffoldMeta{
        .name = duped_name,
        .description = duped_desc,
        .tech_stack = duped_stack,
    };
}

fn deinitScaffoldMeta(allocator: std.mem.Allocator, meta: ScaffoldMeta) void {
    allocator.free(meta.name);
    allocator.free(meta.description);
    for (meta.tech_stack) |tech| allocator.free(tech);
    allocator.free(meta.tech_stack);
}

fn scaffoldWriteFile(path: []const u8, content: []const u8) void {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        stdout_print("  Error: could not write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        stdout_print("  Error: could not write content to {s}\n", .{path});
    };
}

/// `crushcode scaffold new <name> [--stack tech1,tech2] [--desc "description"]`
fn scaffoldNew(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var project_name: ?[]const u8 = null;
    var stack_str: ?[]const u8 = null;
    var description: []const u8 = "A new project";

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--stack")) {
            i += 1;
            if (i < rest.len) stack_str = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--stack=")) {
            stack_str = rest[i][8..];
        } else if (std.mem.eql(u8, rest[i], "--desc")) {
            i += 1;
            if (i < rest.len) description = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--desc=")) {
            description = rest[i][7..];
        } else if (project_name == null) {
            project_name = rest[i];
        }
    }

    const name = project_name orelse {
        stdout_print("Usage: crushcode scaffold new <project-name> [--stack tech1,tech2] [--desc \"description\"]\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, description) catch return;
    defer scaffolder.deinit();

    // Add tech stack from --stack or defaults
    if (stack_str) |ss| {
        var tech_iter = std.mem.splitScalar(u8, ss, ',');
        while (tech_iter.next()) |tech| {
            const trimmed = std.mem.trim(u8, tech, " \t");
            if (trimmed.len > 0) {
                scaffolder.addTech(trimmed) catch {};
            }
        }
    } else {
        scaffolder.addTech("Zig") catch {};
        scaffolder.addTech("Zig stdlib") catch {};
    }

    scaffolder.printSummary();

    // Save metadata to .crushcode/scaffold/<name>.json
    saveScaffoldMeta(allocator, name, description, scaffolder.tech_stack.items) catch {
        stdout_print("\nWarning: could not save scaffold metadata to .crushcode/scaffold/\n", .{});
        return;
    };
    stdout_print("\nProject '{s}' saved to .crushcode/scaffold/{s}.json\n", .{ name, name });
}

/// `crushcode scaffold generate <name> [--dir <dir>]`
fn scaffoldGenerate(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var project_name: ?[]const u8 = null;
    var output_dir: []const u8 = ".";

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--dir")) {
            i += 1;
            if (i < rest.len) output_dir = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--dir=")) {
            output_dir = rest[i][6..];
        } else if (project_name == null) {
            project_name = rest[i];
        }
    }

    const name = project_name orelse {
        stdout_print("Usage: crushcode scaffold generate <project-name> [--dir <dir>]\n", .{});
        return;
    };

    // Create scaffolder with defaults
    var scaffolder = createDefaultScaffolder(allocator, name, "A project scaffolded by Crushcode") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state if available
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    // Default tech stack if none loaded
    if (scaffolder.tech_stack.items.len == 0) {
        scaffolder.addTech("Zig") catch {};
        scaffolder.addTech("Zig stdlib") catch {};
    }

    // Generate markdown content
    const project_md = scaffolder.generateProjectMd() catch return;
    defer allocator.free(project_md);
    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);
    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);

    // Ensure output directory exists
    std.fs.cwd().makePath(output_dir) catch {};

    // Write files to disk
    const project_path = std.fmt.allocPrint(allocator, "{s}/PROJECT.md", .{output_dir}) catch return;
    defer allocator.free(project_path);
    const reqs_path = std.fmt.allocPrint(allocator, "{s}/REQUIREMENTS.md", .{output_dir}) catch return;
    defer allocator.free(reqs_path);
    const roadmap_path = std.fmt.allocPrint(allocator, "{s}/ROADMAP.md", .{output_dir}) catch return;
    defer allocator.free(roadmap_path);

    scaffoldWriteFile(project_path, project_md);
    scaffoldWriteFile(reqs_path, reqs_md);
    scaffoldWriteFile(roadmap_path, roadmap_md);

    stdout_print("\n=== Generated files for '{s}' ===\n\n", .{name});
    stdout_print("  {s}/PROJECT.md\n", .{output_dir});
    stdout_print("  {s}/REQUIREMENTS.md\n", .{output_dir});
    stdout_print("  {s}/ROADMAP.md\n\n", .{output_dir});
}

/// `crushcode scaffold list`
fn scaffoldList() void {
    stdout_print("\nSaved scaffolders (.crushcode/scaffold/):\n\n", .{});

    var dir = std.fs.cwd().openDir(".crushcode/scaffold", .{ .iterate = true }) catch {
        stdout_print("  No saved scaffolders found.\n", .{});
        stdout_print("  Use 'crushcode scaffold new <name>' to create one.\n", .{});
        return;
    };
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const name = entry.name[0 .. entry.name.len - 5]; // strip .json
            stdout_print("  {s}\n", .{name});
            count += 1;
        }
    }

    if (count == 0) {
        stdout_print("  No saved scaffolders found.\n", .{});
        stdout_print("  Use 'crushcode scaffold new <name>' to create one.\n", .{});
    } else {
        stdout_print("\n  Total: {d} project(s)\n", .{count});
    }
}

/// `crushcode scaffold requirements <name>`
fn scaffoldRequirements(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const name = if (rest.len > 0) rest[0] else {
        stdout_print("Usage: crushcode scaffold requirements <project-name>\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, "Project requirements") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);

    stdout_print("\n{s}\n", .{reqs_md});
}

/// `crushcode scaffold phases <name>`
fn scaffoldPhases(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const name = if (rest.len > 0) rest[0] else {
        stdout_print("Usage: crushcode scaffold phases <project-name>\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, "Project phases") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);

    stdout_print("\n{s}\n", .{roadmap_md});
}

/// Handle `crushcode scaffold <subcommand>` — project scaffolding with requirements and phases.
/// Subcommands: new, generate, list, requirements, phases
pub fn handleScaffold(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        showScaffoldUsage();
        return;
    }

    const sub = args.remaining[0];
    const rest = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, sub, "new")) {
        try scaffoldNew(allocator, rest);
    } else if (std.mem.eql(u8, sub, "generate")) {
        try scaffoldGenerate(allocator, rest);
    } else if (std.mem.eql(u8, sub, "list")) {
        scaffoldList();
    } else if (std.mem.eql(u8, sub, "requirements")) {
        try scaffoldRequirements(allocator, rest);
    } else if (std.mem.eql(u8, sub, "phases")) {
        try scaffoldPhases(allocator, rest);
    } else {
        stdout_print("Unknown subcommand: {s}\n\n", .{sub});
        showScaffoldUsage();
    }
}

/// Default vault directory for persistence
const default_vault_dir = ".crushcode/knowledge";

/// Handle `crushcode knowledge <subcommand>` — knowledge operations (ingest/query/lint/status/save/load)
pub fn handleKnowledge(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode knowledge <ingest|query|lint|status|save|load> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  ingest <path>   Ingest file or directory into knowledge vault\n", .{});
        stdout_print("  query <text>    Search knowledge base\n", .{});
        stdout_print("  lint            Run health checks on knowledge vault\n", .{});
        stdout_print("  status          Show vault statistics\n", .{});
        stdout_print("  save            Save current vault to disk\n", .{});
        stdout_print("  load            Load vault from disk\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    // Create in-memory vault
    var vault = knowledge_schema.KnowledgeVault.init(allocator, ".knowledge") catch return;
    defer vault.deinit();

    if (std.mem.eql(u8, subcommand, "ingest")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode knowledge ingest <file_or_directory>\n", .{});
            return;
        }

        // Auto-load from disk first if vault exists
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (pers.vaultExists()) {
            _ = pers.loadVault(&vault) catch {};
        }

        var ingester = knowledge_ingest_mod.KnowledgeIngester.init(allocator, &vault);
        const target_path = sub_args[0];

        // Check if it's a file or directory
        const stat = std.fs.cwd().statFile(target_path) catch |err| {
            stdout_print("Error: cannot access '{s}': {}\n", .{ target_path, err });
            return;
        };

        const result = switch (stat.kind) {
            .directory => ingester.ingestDirectory(target_path) catch {
                stdout_print("Error ingesting directory\n", .{});
                return;
            },
            else => ingester.ingestFile(target_path) catch {
                stdout_print("Error ingesting file\n", .{});
                return;
            },
        };

        stdout_print("\n=== Ingest Results ===\n", .{});
        stdout_print("  Created: {d}\n", .{result.nodes_created});
        stdout_print("  Updated: {d}\n", .{result.nodes_updated});
        stdout_print("  Skipped: {d}\n", .{result.nodes_skipped});
        stdout_print("  Errors:  {d}\n", .{result.errors});
        stdout_print("  Vault size: {d} nodes\n", .{vault.count()});

        // Auto-save after ingest
        pers.saveVault(&vault) catch {
            stdout_print("  Warning: failed to auto-save vault to disk\n", .{});
            return;
        };
        stdout_print("  Vault saved to {s}\n", .{default_vault_dir});
    } else if (std.mem.eql(u8, subcommand, "query")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode knowledge query <search text>\n", .{});
            return;
        }

        // Auto-load from disk if vault is empty and persisted vault exists
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                const load_result = pers.loadVault(&vault) catch {
                    stdout_print("Warning: could not load persisted vault\n", .{});
                    return;
                };
                if (load_result.nodes_loaded > 0) {
                    stdout_print("  Loaded {d} nodes from disk\n", .{load_result.nodes_loaded});
                }
            }
        }

        // Join remaining args as search text
        const search_text = if (sub_args.len > 1)
            std.mem.join(allocator, " ", sub_args) catch return
        else
            sub_args[0];
        defer if (sub_args.len > 1) allocator.free(search_text);

        var querier = knowledge_query_mod.KnowledgeQuerier.init(allocator, &vault);
        const results = querier.query(search_text, 10) catch {
            stdout_print("Error querying knowledge base\n", .{});
            return;
        };
        defer {
            for (results) |*r| r.deinit(allocator);
            allocator.free(results);
        }

        stdout_print("\n=== Query Results for \"{s}\" ===\n", .{search_text});
        if (results.len == 0) {
            stdout_print("  No results found\n", .{});
        } else {
            for (results, 0..) |*r, i| {
                stdout_print("\n  {d}. {s} (relevance: {d:.2})\n", .{ i + 1, r.title, r.relevance });
                stdout_print("     ID: {s}\n", .{r.node_id});
                if (r.source) |s| stdout_print("     Source: {s}\n", .{s});
                stdout_print("     Snippet: {s}\n", .{r.snippet});
            }
        }
    } else if (std.mem.eql(u8, subcommand, "lint")) {
        // Auto-load from disk if vault is empty
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                _ = pers.loadVault(&vault) catch {};
            }
        }

        var linter = knowledge_lint_mod.KnowledgeLinter.init(allocator, &vault);
        const findings = linter.lint() catch {
            stdout_print("Error running linter\n", .{});
            return;
        };
        defer {
            for (findings) |f| {
                f.deinit();
                allocator.destroy(f);
            }
            allocator.free(findings);
        }

        stdout_print("\n=== Knowledge Lint Results ===\n", .{});
        stdout_print("  Nodes checked: {d}\n", .{vault.count()});
        stdout_print("  Findings: {d}\n\n", .{findings.len});

        // Group by severity
        var critical_count: u32 = 0;
        var warning_count: u32 = 0;
        var info_count: u32 = 0;
        for (findings) |f| {
            switch (f.severity) {
                .critical => critical_count += 1,
                .warning => warning_count += 1,
                .info => info_count += 1,
            }
        }
        stdout_print("  Critical: {d} | Warnings: {d} | Info: {d}\n\n", .{ critical_count, warning_count, info_count });

        for (findings) |f| {
            const sev_label = switch (f.severity) {
                .critical => "CRITICAL",
                .warning => "WARNING",
                .info => "INFO",
            };
            stdout_print("  [{s}] {s}: {s}\n", .{ sev_label, @tagName(f.rule), f.message });
            if (f.location) |loc| stdout_print("    Location: {s}\n", .{loc});
            if (f.suggestion) |sug| stdout_print("    Suggestion: {s}\n", .{sug});
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        // Auto-load from disk if vault is empty
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                _ = pers.loadVault(&vault) catch {};
            }
        }

        var mgr = knowledge_vault_mod.VaultManager.init(allocator, &vault);
        const stats = mgr.getStats();

        // Check persistence status
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        const is_persisted = pers.vaultExists();

        stdout_print("\n=== Knowledge Vault Status ===\n", .{});
        stdout_print("  Path: {s}\n", .{vault.path});
        stdout_print("  Persisted: {s}\n", .{if (is_persisted) "yes (.crushcode/knowledge/)" else "no"});
        stdout_print("  Total nodes: {d}\n", .{stats.total_nodes});
        stdout_print("  File nodes: {d}\n", .{stats.file_nodes});
        stdout_print("  Graph nodes: {d}\n", .{stats.graph_nodes});
        stdout_print("  Manual nodes: {d}\n", .{stats.manual_nodes});
        stdout_print("  AI-generated nodes: {d}\n", .{stats.ai_nodes});
        stdout_print("  Total tags: {d}\n", .{stats.total_tags});
        stdout_print("  Total citations: {d}\n", .{stats.total_citations});
        stdout_print("  Total accesses: {d}\n", .{stats.total_accesses});
        stdout_print("  Avg confidence: {d:.2}\n", .{stats.avg_confidence});
        stdout_print("  Low confidence (<0.3): {d}\n", .{stats.low_confidence_nodes});
    } else if (std.mem.eql(u8, subcommand, "save")) {
        // Auto-load from disk first to preserve existing data
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (pers.vaultExists()) {
            _ = pers.loadVault(&vault) catch {};
        }

        if (vault.count() == 0) {
            stdout_print("Nothing to save. Use 'crushcode knowledge ingest <path>' first.\n", .{});
            return;
        }

        pers.saveVault(&vault) catch {
            stdout_print("Error: failed to save vault to {s}\n", .{default_vault_dir});
            return;
        };
        stdout_print("\n=== Vault Saved ===\n", .{});
        stdout_print("  Location: {s}\n", .{default_vault_dir});
        stdout_print("  Nodes: {d}\n", .{vault.count()});
    } else if (std.mem.eql(u8, subcommand, "load")) {
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (!pers.vaultExists()) {
            stdout_print("No persisted vault found at {s}\n", .{default_vault_dir});
            stdout_print("Use 'crushcode knowledge ingest <path>' to create one.\n", .{});
            return;
        }

        const result = pers.loadVault(&vault) catch {
            stdout_print("Error: failed to load vault from {s}\n", .{default_vault_dir});
            return;
        };
        stdout_print("\n=== Vault Loaded ===\n", .{});
        stdout_print("  Location: {s}\n", .{default_vault_dir});
        stdout_print("  Nodes loaded: {d}\n", .{result.nodes_loaded});
        stdout_print("  Nodes failed: {d}\n", .{result.nodes_failed});
        stdout_print("  Unique tags: {d}\n", .{result.tags_found});
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: ingest, query, lint, status, save, or load\n", .{});
    }
}

/// Handle `crushcode worker <subcommand>` — worker agent execution engine.
/// Subcommands:
///   run "<task>" [--specialty <type>] [--model <model>]  Spawn a worker and execute a task
///   results <id>                                         Read and display worker output
///   list                                                 Show all workers and their status
pub fn handleWorker(args: args_mod.Args) !void {
    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode worker <run|results|list> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  run \"<task>\" [--specialty <type>] [--model <model>]  Execute a task in a worker\n", .{});
        stdout_print("  results <id>                                         Read worker output\n", .{});
        stdout_print("  list                                                 Show all workers\n", .{});
        stdout_print("\nSpecialties: researcher, file_ops, executor, publisher, collector\n", .{});
        return;
    }

    const subcommand = args.remaining[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        handleWorkerList();
        return;
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        try handleWorkerRun(args.remaining[1..]);
        return;
    }

    if (std.mem.eql(u8, subcommand, "results")) {
        try handleWorkerResults(args.remaining[1..]);
        return;
    }

    stdout_print("Unknown subcommand: {s}\n", .{subcommand});
    stdout_print("Use: run, results, or list\n", .{});
}

/// Global worker pool (persists across commands in same process)
var global_worker_pool: ?worker_mod.WorkerPool = null;

fn getOrCreatePool(allocator: std.mem.Allocator) *worker_mod.WorkerPool {
    if (global_worker_pool == null) {
        global_worker_pool = worker_mod.WorkerPool.init(allocator);
    }
    return &global_worker_pool.?;
}

/// Handle `crushcode worker run "<task>" [--specialty <type>] [--model <model>]`
fn handleWorkerRun(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode worker run \"<task>\" [--specialty <type>] [--model <model>]\n", .{});
        return;
    }

    var task_prompt: ?[]const u8 = null;
    var specialty: worker_mod.WorkerSpecialty = .researcher;
    var model: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--specialty")) {
            i += 1;
            if (i < sub_args.len) {
                const val = sub_args[i];
                if (std.mem.eql(u8, val, "researcher")) {
                    specialty = .researcher;
                } else if (std.mem.eql(u8, val, "file_ops")) {
                    specialty = .file_ops;
                } else if (std.mem.eql(u8, val, "executor")) {
                    specialty = .executor;
                } else if (std.mem.eql(u8, val, "publisher")) {
                    specialty = .publisher;
                } else if (std.mem.eql(u8, val, "collector")) {
                    specialty = .collector;
                } else {
                    stdout_print("Unknown specialty: {s} (using researcher)\n", .{val});
                }
            }
        } else if (std.mem.startsWith(u8, sub_args[i], "--specialty=")) {
            const val = sub_args[i][11..];
            if (std.mem.eql(u8, val, "file_ops")) specialty = .file_ops;
            if (std.mem.eql(u8, val, "executor")) specialty = .executor;
            if (std.mem.eql(u8, val, "publisher")) specialty = .publisher;
            if (std.mem.eql(u8, val, "collector")) specialty = .collector;
        } else if (std.mem.eql(u8, sub_args[i], "--model")) {
            i += 1;
            if (i < sub_args.len) {
                model = sub_args[i];
            }
        } else if (std.mem.startsWith(u8, sub_args[i], "--model=")) {
            model = sub_args[i][7..];
        } else if (task_prompt == null) {
            task_prompt = sub_args[i];
        }
    }

    const prompt = task_prompt orelse {
        stdout_print("Error: no task prompt provided\n", .{});
        return;
    };

    const pool = getOrCreatePool(allocator);

    const w = if (model) |m|
        try pool.spawnWorkerWithModel(specialty, prompt, m)
    else
        try pool.spawnWorker(specialty, prompt);

    stdout_print("\n=== Worker Spawned ===\n", .{});
    stdout_print("  ID:        {s}\n", .{w.id});
    stdout_print("  Specialty: {s}\n", .{@tagName(w.specialty)});
    if (w.model_preference) |mp| {
        stdout_print("  Model:     {s}\n", .{mp});
    }
    stdout_print("  Status:    {s}\n", .{@tagName(w.status)});
    stdout_print("  Output:    {s}\n", .{w.output_path});
    stdout_print("\nWorker is pending execution. Use `crushcode worker results {s}` to check output.\n", .{w.id});
}

/// Handle `crushcode worker results <id>`
fn handleWorkerResults(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode worker results <worker-id>\n", .{});
        return;
    }

    const worker_id = sub_args[0];
    const pool = getOrCreatePool(allocator);

    const status = pool.checkStatus(worker_id);
    stdout_print("\n=== Worker {s} ===\n", .{worker_id});
    stdout_print("  Status: {s}\n", .{@tagName(status)});

    if (status == .completed) {
        const output = pool.getResult(worker_id) catch |err| {
            stdout_print("  Error reading result: {}\n", .{err});
            return;
        };
        if (output) |content| {
            defer allocator.free(content);
            stdout_print("\n--- Output ---\n{s}\n", .{content});
        } else {
            stdout_print("  (no output)\n", .{});
        }
    } else if (status == .running) {
        stdout_print("  Worker is still running...\n", .{});
    } else if (status == .failed) {
        stdout_print("  Worker failed or not found.\n", .{});
    } else if (status == .pending) {
        stdout_print("  Worker is pending execution.\n", .{});
    }
}

/// Handle `crushcode worker list`
fn handleWorkerList() void {
    const pool = getOrCreatePool(std.heap.page_allocator);
    pool.printStatus();
}

/// Handle `crushcode hooks <subcommand>` — hook execution engine management.
/// Subcommands:
///   list               Show all registered hook scripts with status
///   run <hook_name>    Manually trigger a specific hook
///   test               Dry-run all hooks, show what would execute
///   discover           Scan directories and show discovered hooks
pub fn handleHooks(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode hooks <list|run|test|discover> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  list               Show all registered hook scripts\n", .{});
        stdout_print("  run <hook_name>    Manually trigger a hook\n", .{});
        stdout_print("  test               Dry-run all hooks (no execution)\n", .{});
        stdout_print("  discover           Scan .crushcode/hooks/ and .claude/hooks/\n", .{});
        return;
    }

    const subcommand = args.remaining[0];

    // Create a lifecycle hooks instance and executor
    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = hooks_executor_mod.HookExecutor.init(allocator, &lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    if (std.mem.eql(u8, subcommand, "list")) {
        // Auto-discover before listing
        _ = executor.discoverHooks() catch 0;
        executor.printStatus();
    } else if (std.mem.eql(u8, subcommand, "run")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode hooks run <hook_name>\n", .{});
            return;
        }
        const hook_name = args.remaining[1];

        // Auto-discover first
        _ = executor.discoverHooks() catch 0;

        var ctx = lifecycle.HookContext.init(allocator);
        defer ctx.deinit();
        ctx.phase = .pre_tool;

        const result = executor.executeSingle(hook_name, &ctx);
        if (result) |r| {
            defer {
                var mut_r = r;
                mut_r.deinit(allocator);
            }
            const status = if (r.success) "SUCCESS" else "FAILED";
            stdout_print("\n=== Hook Result ===\n", .{});
            stdout_print("  Hook:   {s}\n", .{r.hook_name});
            stdout_print("  Status: {s}\n", .{status});
            stdout_print("  Exit:   {d}\n", .{r.exit_code});
            stdout_print("  Time:   {d}ms\n", .{r.duration_ms});
            if (r.output.len > 0) {
                stdout_print("\n--- Output ---\n{s}\n", .{r.output});
            }
        } else {
            stdout_print("Hook not found: {s}\n", .{hook_name});
            stdout_print("Use 'crushcode hooks list' to see registered hooks.\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "test")) {
        // Auto-discover
        _ = executor.discoverHooks() catch 0;

        executor.dry_run = true;
        stdout_print("\n=== Hook Test (Dry Run) ===\n", .{});

        if (executor.scripts.items.len == 0) {
            stdout_print("  No hook scripts found.\n", .{});
            stdout_print("  Place scripts in .crushcode/hooks/ or .claude/hooks/\n", .{});
            stdout_print("  Naming: pre-tool-*.sh, post-edit-*.sh, etc.\n", .{});
            return;
        }

        // Test each registered hook
        var ctx = lifecycle.HookContext.init(allocator);
        defer ctx.deinit();
        ctx.phase = .pre_tool;

        for (executor.scripts.items) |script| {
            const test_result = executor.testHook(script.name, &ctx);
            if (test_result) |r| {
                defer {
                    var mut_r = r;
                    mut_r.deinit(allocator);
                }
                const enabled = if (script.enabled) "enabled" else "disabled";
                stdout_print("  [{s}] {s} → {s}\n", .{ enabled, script.name, r.output });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "discover")) {
        stdout_print("\n=== Discovering Hooks ===\n", .{});

        const count = executor.discoverHooks() catch 0;

        stdout_print("  Scanned: .crushcode/hooks/\n", .{});
        stdout_print("  Scanned: .claude/hooks/\n", .{});
        stdout_print("  Discovered: {d} hook scripts\n\n", .{count});

        if (count > 0) {
            for (executor.scripts.items) |script| {
                stdout_print("  {s} ({s}) → {s}\n", .{ script.name, @tagName(script.phase), script.script_path });
            }
        } else {
            stdout_print("  No hook scripts found.\n", .{});
            stdout_print("  Create scripts like .crushcode/hooks/pre-tool-lint.sh\n", .{});
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: list, run, test, or discover\n", .{});
    }
}

/// Handle `crushcode skills resolve "<context>"` — resolve skills for a context/query
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

/// Handle `crushcode memory <subcommand>` — 4-layer memory operations.
/// Subcommands:
///   layers                Show all layers with entry counts
///   insights              Show insights layer entries with confidence
///   distill               Trigger manual distillation
///   search "<query>"      Search across layers
///   store <layer> <key> "<value>"  Store an entry
///   stats                 Show memory statistics
pub fn handleMemory(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode memory <layers|insights|distill|search|store|stats> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  layers                        Show all layers with entry counts\n", .{});
        stdout_print("  insights                      Show insights layer entries with confidence\n", .{});
        stdout_print("  distill                       Trigger manual distillation\n", .{});
        stdout_print("  search \"<query>\"              Search across layers\n", .{});
        stdout_print("  store <layer> <key> \"<value>\" Store an entry in a layer\n", .{});
        stdout_print("  stats                         Show memory statistics\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    var lm = try layered_memory_mod.LayeredMemory.init(allocator, ".");
    defer lm.deinit();

    // Auto-load from disk if persisted data exists
    lm.loadFromDisk() catch {};

    if (std.mem.eql(u8, subcommand, "layers")) {
        lm.printLayers();
    } else if (std.mem.eql(u8, subcommand, "insights")) {
        stdout_print("\n=== Insights Layer ===\n", .{});
        const list = &lm.insights_entries;
        if (list.items.len == 0) {
            stdout_print("  No insights entries.\n", .{});
            stdout_print("  Use 'crushcode memory distill' to create insights from working memory.\n", .{});
        } else {
            for (list.items, 0..) |entry, idx| {
                stdout_print("  {d}. [{s}] {s} = {s} (conf: {d:.2}, src: {s})\n", .{
                    idx + 1,
                    entry.id,
                    entry.key,
                    entry.value,
                    entry.confidence,
                    entry.source,
                });
                if (entry.tags.items.len > 0) {
                    stdout_print("     tags: ", .{});
                    for (entry.tags.items, 0..) |t, ti| {
                        if (ti > 0) stdout_print(", ", .{});
                        stdout_print("{s}", .{t});
                    }
                    stdout_print("\n", .{});
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "distill")) {
        lm.distill_config.min_changes = 1; // Allow manual trigger regardless of change count
        const count = lm.distill() catch {
            stdout_print("Error: distillation failed\n", .{});
            return;
        };
        stdout_print("\n=== Distillation Complete ===\n", .{});
        stdout_print("  Insights created: {d}\n", .{count});
        if (count > 0) {
            try lm.saveToDisk();
            stdout_print("  Memory saved to disk.\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "search")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode memory search \"<query>\"\n", .{});
            return;
        }
        const query = sub_args[0];
        const results = lm.search(query) catch {
            stdout_print("Error: search failed\n", .{});
            return;
        };
        defer allocator.free(results);

        stdout_print("\n=== Search Results for \"{s}\" ===\n", .{query});
        if (results.len == 0) {
            stdout_print("  No results found.\n", .{});
        } else {
            for (results, 0..) |entry, idx| {
                const layer_name = @tagName(entry.layer);
                stdout_print("  {d}. [{s}] {s} = {s}\n", .{
                    idx + 1,
                    layer_name,
                    entry.key,
                    entry.value,
                });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "store")) {
        if (sub_args.len < 3) {
            stdout_print("Usage: crushcode memory store <layer> <key> \"<value>\"\n", .{});
            stdout_print("Layers: session, working, insights, project\n", .{});
            return;
        }
        const layer_str = sub_args[0];
        const key = sub_args[1];
        const value = sub_args[2];

        const layer: layered_memory_mod.MemoryLayer =
            if (std.mem.eql(u8, layer_str, "session")) .session else if (std.mem.eql(u8, layer_str, "working")) .working else if (std.mem.eql(u8, layer_str, "insights")) .insights else if (std.mem.eql(u8, layer_str, "project")) .project else {
                stdout_print("Unknown layer: {s}\nUse: session, working, insights, or project\n", .{layer_str});
                return;
            };

        const entry = lm.store(layer, key, value, "manual", &.{}) catch {
            stdout_print("Error: failed to store entry\n", .{});
            return;
        };

        try lm.saveToDisk();
        stdout_print("Stored [{s}] {s} = {s} (id: {s})\n", .{ layer_str, key, value, entry.id });
    } else if (std.mem.eql(u8, subcommand, "stats")) {
        const stats = lm.getStats();
        stdout_print("\n=== Memory Statistics ===\n", .{});
        stdout_print("  Session entries:  {d}\n", .{stats.session_count});
        stdout_print("  Working entries:  {d}\n", .{stats.working_count});
        stdout_print("  Insights entries: {d}\n", .{stats.insights_count});
        stdout_print("  Project entries:  {d}\n", .{stats.project_count});
        stdout_print("  Total:            {d}\n", .{stats.total});
        stdout_print("  Avg confidence:   {d:.2}\n", .{stats.avg_confidence});
        stdout_print("  Low confidence:   {d}\n", .{stats.low_confidence_count});
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: layers, insights, distill, search, store, or stats\n", .{});
    }
}

/// Global pipeline runner (persists across commands in same process)
var global_pipeline_runner: ?skill_pipeline_mod.PipelineRunner = null;

fn getOrCreatePipelineRunner(allocator: std.mem.Allocator) *skill_pipeline_mod.PipelineRunner {
    if (global_pipeline_runner == null) {
        global_pipeline_runner = skill_pipeline_mod.PipelineRunner.init(allocator, ".crushcode/pipeline-results/") catch {
            stdout_print("Error: failed to initialize pipeline runner\n", .{});
            return &global_pipeline_runner.?;
        };
    }
    return &global_pipeline_runner.?;
}

/// Handle `crushcode pipeline <subcommand>` — multi-phase skill execution engine.
/// Subcommands:
///   run "<template>"   Build and run a pipeline from a built-in template
///   status [idx]       Show pipeline status (or specific pipeline by index)
///   list               List all registered pipelines
///   templates          List available pipeline templates
///   results [idx]      Show pipeline results
pub fn handlePipeline(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode pipeline <run|status|list|templates|results> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  run \"<template>\"   Build and run a pipeline template\n", .{});
        stdout_print("  status [idx]       Show pipeline status\n", .{});
        stdout_print("  list               List all pipelines\n", .{});
        stdout_print("  templates          List available templates\n", .{});
        stdout_print("  results [idx]      Show pipeline results\n", .{});
        stdout_print("\nTemplates: research, refactor, review\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};
    const runner = getOrCreatePipelineRunner(allocator);

    if (std.mem.eql(u8, subcommand, "run")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode pipeline run \"<template>\"\n", .{});
            stdout_print("Templates: research, refactor, review\n", .{});
            return;
        }
        const template_name = sub_args[0];
        const pipeline = runner.buildFromTemplate(template_name) catch |err| {
            if (err == error.UnknownTemplate) {
                stdout_print("Unknown template: {s}\n", .{template_name});
                stdout_print("Available: research, refactor, review\n", .{});
                return;
            }
            stdout_print("Error building template: {}\n", .{err});
            return;
        };

        stdout_print("\n=== Running Pipeline: {s} ===\n", .{pipeline.name});
        stdout_print("  Template:  {s}\n", .{template_name});
        stdout_print("  Steps:     {d}\n", .{pipeline.steps.items.len});
        stdout_print("  Phases:    scan → enrich → create → report\n\n", .{});

        const idx = runner.pipelines.items.len - 1;
        var result = runner.runPipeline(idx) catch |err| {
            stdout_print("Error running pipeline: {}\n", .{err});
            return;
        };
        defer result.deinit(allocator);

        stdout_print("\n=== Pipeline Result ===\n", .{});
        stdout_print("  Pipeline:  {s}\n", .{result.pipeline_name});
        stdout_print("  Status:    {s}\n", .{@tagName(result.status)});
        stdout_print("  Steps:     {d}/{d} completed, {d} failed\n", .{
            result.completed_steps,
            result.total_steps,
            result.failed_steps,
        });
        stdout_print("  Duration:  {d}ms\n", .{result.duration_ms});
        if (result.output_path.len > 0) {
            stdout_print("  Output:    {s}\n", .{result.output_path});
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        if (sub_args.len > 0) {
            const idx = std.fmt.parseInt(usize, sub_args[0], 10) catch {
                stdout_print("Invalid index: {s}\n", .{sub_args[0]});
                return;
            };
            const status_str = runner.getPipelineStatus(idx) catch |err| {
                if (err == error.PipelineNotFound) {
                    stdout_print("Pipeline not found at index {d}\n", .{idx});
                    return;
                }
                stdout_print("Error: {}\n", .{err});
                return;
            };
            defer allocator.free(status_str);
            stdout_print("{s}\n", .{status_str});
        } else {
            // Show all pipelines
            for (runner.pipelines.items, 0..) |_, idx| {
                const status_str = runner.getPipelineStatus(idx) catch continue;
                defer allocator.free(status_str);
                stdout_print("{s}\n", .{status_str});
            }
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        const listing = runner.listPipelines() catch {
            stdout_print("Error listing pipelines\n", .{});
            return;
        };
        defer allocator.free(listing);
        stdout_print("{s}\n", .{listing});
    } else if (std.mem.eql(u8, subcommand, "templates")) {
        const templates = skill_pipeline_mod.PipelineRunner.listTemplates(allocator) catch {
            stdout_print("Error listing templates\n", .{});
            return;
        };
        defer allocator.free(templates);
        stdout_print("{s}\n", .{templates});
    } else if (std.mem.eql(u8, subcommand, "results")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode pipeline results <index>\n", .{});
            return;
        }
        const idx = std.fmt.parseInt(usize, sub_args[0], 10) catch {
            stdout_print("Invalid index: {s}\n", .{sub_args[0]});
            return;
        };
        const results = runner.getResults(idx) catch |err| {
            if (err == error.PipelineNotFound) {
                stdout_print("Pipeline not found at index {d}\n", .{idx});
                return;
            }
            stdout_print("Error: {}\n", .{err});
            return;
        };
        if (results.len == 0) {
            stdout_print("No results yet for pipeline {d}\n", .{idx});
        } else {
            for (results, 0..) |r, i| {
                stdout_print("  {d}. {s} [{s}]\n", .{ i + 1, r.pipeline_name, @tagName(r.status) });
            }
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: run, status, list, templates, or results\n", .{});
    }
}

/// Global thinking engine (persists across commands in same process)
var global_think_engine: ?adversarial_mod.ThinkingEngine = null;

fn getOrCreateThinkEngine(allocator: std.mem.Allocator) *adversarial_mod.ThinkingEngine {
    if (global_think_engine == null) {
        global_think_engine = adversarial_mod.ThinkingEngine.init(allocator);
    }
    return &global_think_engine.?;
}

/// Handle `crushcode think <subcommand>` — adversarial thinking tools.
/// Subcommands:
///   challenge "<idea>"               Argue against an idea using knowledge history
///   emerge                            Surface hidden patterns across accumulated knowledge
///   connect "<topic_a>" "<topic_b>"   Bridge two unrelated domains
///   graduate "<idea>"                 Turn an idea into a structured project plan
///   history                           Show past thinking results
pub fn handleThink(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode think <challenge|emerge|connect|graduate|history> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  challenge \"<idea>\"              Argue against an idea\n", .{});
        stdout_print("  emerge                          Surface hidden patterns\n", .{});
        stdout_print("  connect \"<a>\" \"<b>\"            Bridge two unrelated domains\n", .{});
        stdout_print("  graduate \"<idea>\"               Turn idea into project plan\n", .{});
        stdout_print("  history                         Show past thinking results\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const engine = getOrCreateThinkEngine(allocator);

    if (std.mem.eql(u8, subcommand, "challenge")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode think challenge \"<idea>\"\n", .{});
            return;
        }
        const idea = args.remaining[1];
        const result = engine.challenge(idea) catch {
            stdout_print("Error running challenge\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
        stdout_print("Perspectives generated: {d}\n", .{result.perspectives.len});
    } else if (std.mem.eql(u8, subcommand, "emerge")) {
        const result = engine.emerge() catch {
            stdout_print("Error running emerge\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "connect")) {
        if (args.remaining.len < 3) {
            stdout_print("Usage: crushcode think connect \"<topic_a>\" \"<topic_b>\"\n", .{});
            return;
        }
        const topic_a = args.remaining[1];
        const topic_b = args.remaining[2];
        const result = engine.connect(topic_a, topic_b) catch {
            stdout_print("Error running connect\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "graduate")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode think graduate \"<idea>\"\n", .{});
            return;
        }
        const idea = args.remaining[1];
        const result = engine.graduate(idea) catch {
            stdout_print("Error running graduate\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "history")) {
        const history = engine.getHistory(20);
        stdout_print("\n=== Thinking History ({d} results) ===\n\n", .{history.len});
        if (history.len == 0) {
            stdout_print("  No thinking results yet. Use challenge, emerge, connect, or graduate first.\n", .{});
        } else {
            for (history, 0..) |item, i| {
                const snippet = if (item.output.len > 60) item.output[0..60] else item.output;
                stdout_print("  {d}. [{s}] confidence={d:.2}\n", .{ i + 1, @tagName(item.mode), item.confidence });
                stdout_print("     Input: {s}\n", .{item.input});
                stdout_print("     Output: {s}...\n", .{snippet});
            }
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: challenge, emerge, connect, graduate, or history\n", .{});
    }
}

pub fn handleSkillSync(args: args_mod.Args) !void {
    skill_sync_mod.handleSkillSync(args.remaining);
}

pub fn handleTemplate(args: args_mod.Args) !void {
    try template_mod.handleTemplate(args.remaining);
}

/// Handle `crushcode preview` — file preview with line numbers, highlighting, and diff
pub fn handlePreview(args: args_mod.Args) !void {
    const code_preview = @import("code_preview");

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode preview <file> [file...]\n", .{});
        stdout_print("       crushcode preview --highlight <line> <file>\n", .{});
        stdout_print("       crushcode preview --snippet <line> <file>\n", .{});
        stdout_print("       crushcode preview --diff <file1> <file2>\n", .{});
        return;
    }

    // Parse flags
    var highlight_line: ?u32 = null;
    var context_lines: u32 = 10;
    var mode: code_preview.PreviewMode = .full;
    var file_start: usize = 0;
    var diff_mode = false;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--highlight")) {
            i += 1;
            if (i < args.remaining.len) {
                highlight_line = std.fmt.parseInt(u32, args.remaining[i], 10) catch {
                    stdout_print("Error: invalid line number '{s}'\n", .{args.remaining[i]});
                    return;
                };
                mode = .full;
            }
        } else if (std.mem.eql(u8, args.remaining[i], "--snippet")) {
            i += 1;
            if (i < args.remaining.len) {
                highlight_line = std.fmt.parseInt(u32, args.remaining[i], 10) catch {
                    stdout_print("Error: invalid line number '{s}'\n", .{args.remaining[i]});
                    return;
                };
                mode = .snippet;
            }
        } else if (std.mem.eql(u8, args.remaining[i], "--diff")) {
            diff_mode = true;
        } else if (std.mem.eql(u8, args.remaining[i], "--context")) {
            i += 1;
            if (i < args.remaining.len) {
                context_lines = std.fmt.parseInt(u32, args.remaining[i], 10) catch 10;
            }
        } else {
            // First non-flag = start of file list
            file_start = i;
            break;
        }
    }

    const files = args.remaining[file_start..];

    if (diff_mode) {
        if (files.len < 2) {
            stdout_print("Error: --diff requires two file paths\n", .{});
            return;
        }
        code_preview.printDiff(files[0], files[1]);
        return;
    }

    if (files.len == 0) {
        stdout_print("Error: no file specified\n", .{});
        return;
    }

    for (files) |file_path| {
        code_preview.printPreview(file_path, highlight_line, context_lines, mode);
    }
}

pub fn handleDetect(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var detector = file_type_mod.FileDetector.init(allocator) catch {
        stdout_print("Error: failed to initialize file detector\n", .{});
        return;
    };
    defer detector.deinit();

    // Use global --json flag from args_mod, parse --mime from remaining
    var mime_only = false;
    var files = array_list_compat.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    for (args.remaining) |arg| {
        if (std.mem.eql(u8, arg, "--mime")) {
            mime_only = true;
        } else {
            try files.append(arg);
        }
    }

    if (files.items.len == 0) {
        stdout_print("Usage: crushcode detect [options] <file...>\n\nOptions:\n  --json, -j   Output as JSON\n  --mime       Show MIME type only\n", .{});
        return;
    }

    for (files.items) |file_path| {
        var result = detector.detectFile(file_path) catch {
            stdout_print("Error: could not read '{s}'\n", .{file_path});
            continue;
        };
        defer result.deinit();

        if (args.json) {
            if (result.content_type) |ct| {
                stdout_print(
                    \\{{"file":"{s}","type":"{s}","mime":"{s}","group":"{s}","confidence":{d:.2},"method":"{s}","size":{},"is_text":{}"}}
                    \\
                , .{
                    result.file_path,
                    ct.label,
                    ct.mime_type,
                    ct.group,
                    result.confidence,
                    @tagName(result.detected_by),
                    result.file_size,
                    ct.is_text,
                });
            } else {
                stdout_print(
                    \\{{"file":"{s}","type":null,"confidence":0.00,"method":"{s}","size":{}}}
                    \\
                , .{
                    result.file_path,
                    @tagName(result.detected_by),
                    result.file_size,
                });
            }
        } else if (mime_only) {
            if (result.content_type) |ct| {
                stdout_print("{s}\n", .{ct.mime_type});
            } else {
                stdout_print("application/octet-stream\n", .{});
            }
        } else {
            stdout_print("File: {s}\n", .{result.file_path});
            if (result.content_type) |ct| {
                stdout_print("  Type:        {s}\n", .{ct.label});
                stdout_print("  Description: {s}\n", .{ct.description});
                stdout_print("  MIME:        {s}\n", .{ct.mime_type});
                stdout_print("  Group:       {s}\n", .{ct.group});
                stdout_print("  Text:        {s}\n", .{if (ct.is_text) "yes" else "no"});
            } else {
                stdout_print("  Type:        unknown\n", .{});
            }
            stdout_print("  Confidence:  {d:.0}%\n", .{result.confidence * 100});
            stdout_print("  Method:      {s}\n", .{@tagName(result.detected_by)});
            stdout_print("  Size:        {} bytes\n", .{result.file_size});
            stdout_print("\n", .{});
        }
    }
}
