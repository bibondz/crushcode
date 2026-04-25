const std = @import("std");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const graph_mod = @import("graph");
const agent_loop_mod = @import("agent_loop");
const autopilot_mod = @import("autopilot");
const cognition_mod = @import("cognition");
const guardian_mod = @import("guardian");
const crush_mode_mod = @import("crush_mode");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

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
            // Must dupe — value is a slice into buf which gets freed on return
            provider_name.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "default_model")) {
            model.* = try allocator.dupe(u8, value);
        } else if (in_api_keys_section) {
            // Check if this key matches the resolved provider name
            if (std.mem.eql(u8, key, provider_name.*)) {
                api_key.* = try allocator.dupe(u8, value);
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

/// Crush Mode — auto-agentic execution: plan → execute → verify → commit
///
/// Usage:
///   crushcode crush "<task description>"
///   crushcode crush --auto-approve "<task description>"
///   crushcode crush --no-commit "<task description>"
///   crushcode crush --dry-run "<task description>"
pub fn handleCrush(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Crush Mode — Auto-agentic execution engine\n\n", .{});
        stdout_print("Usage: crushcode crush [options] \"<task description>\"\n\n", .{});
        stdout_print("Options:\n", .{});
        stdout_print("  --auto-approve   Auto-approve all tool calls (reads + writes)\n", .{});
        stdout_print("  --no-commit      Skip auto-commit after completion\n", .{});
        stdout_print("  --no-verify      Skip build verification\n", .{});
        stdout_print("  --dry-run        Parse plan but do not execute\n", .{});
        stdout_print("\nExample:\n", .{});
        stdout_print("  crushcode crush \"Fix all auth bugs and add tests\"\n", .{});
        stdout_print("  crushcode crush --auto-approve \"Refactor the config module\"\n", .{});
        return;
    }

    // Parse options
    var auto_approve = false;
    var no_commit = false;
    var no_verify = false;
    var dry_run = false;
    var task_parts = array_list_compat.ArrayList([]const u8).init(allocator);
    defer task_parts.deinit();

    for (args.remaining) |arg| {
        if (std.mem.eql(u8, arg, "--auto-approve")) {
            auto_approve = true;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            no_commit = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            no_verify = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            try task_parts.append(arg);
        }
    }

    if (task_parts.items.len == 0) {
        stdout_print("Error: no task description provided\n", .{});
        stdout_print("Usage: crushcode crush \"<task description>\"\n", .{});
        return;
    }

    // Join task parts into single description
    const task = try std.mem.join(allocator, " ", task_parts.items);
    defer allocator.free(task);

    stdout_print("\n🤖 Crush Mode\n", .{});
    stdout_print("  Task: {s}\n", .{task});
    stdout_print("  Auto-approve: {s}\n", .{if (auto_approve) "yes" else "reads only"});
    stdout_print("  Auto-commit:  {s}\n", .{if (no_commit) "no" else "yes"});
    stdout_print("  Verify build: {s}\n\n", .{if (no_verify) "no" else "yes"});

    // Get project directory (cwd)
    const cwd = std.process.getCwdAlloc(allocator) catch ".";
    defer allocator.free(cwd);

    // Initialize CrushEngine
    var engine = crush_mode_mod.CrushEngine.init(allocator, task, cwd);
    engine.auto_approve_read = true;
    engine.auto_approve_write = auto_approve;
    engine.auto_verify = !no_verify;
    engine.auto_commit = !no_commit;
    defer engine.deinit();

    if (dry_run) {
        stdout_print("[dry-run] Would plan and execute: {s}\n", .{task});
        return;
    }

    stdout_print("Planning...\n", .{});

    // Build plan prompt
    const plan_prompt = engine.buildPlanPrompt(allocator) catch |err| {
        stdout_print("Error building plan: {}\n", .{err});
        return;
    };
    defer allocator.free(plan_prompt);

    stdout_print("Plan prompt generated ({d} bytes)\n", .{plan_prompt.len});
    stdout_print("\nNote: Full execution requires AI provider connection.\n", .{});
    stdout_print("Use TUI mode (crushcode tui) then /crush for interactive execution.\n", .{});
}
