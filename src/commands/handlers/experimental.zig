const std = @import("std");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const graph_mod = @import("graph");
const agent_loop_mod = @import("agent_loop");
const workflow_mod = @import("workflow");
const compaction_mod = @import("compaction");
const scaffold_mod = @import("scaffold");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleGraph(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

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

    kg.detectCommunities() catch {};
    kg.printStats();

    if (kg.nodes.count() > 0) {
        const ctx = kg.toCompressedContext(allocator) catch return;
        defer allocator.free(ctx);
        stdout_print("\n--- Compressed Context Preview ---\n", .{});
        stdout_print("{s}\n", .{ctx});
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

pub fn handleScaffold(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse args: scaffold <name> [--desc "description"] [--tech zig,typescript]
    var project_name: []const u8 = "my-project";
    var description: []const u8 = "A project scaffolded by Crushcode";
    var tech_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--desc")) {
            i += 1;
            if (i < args.remaining.len) {
                description = args.remaining[i];
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--desc=")) {
            description = args.remaining[i][7..];
        } else if (std.mem.eql(u8, args.remaining[i], "--tech")) {
            i += 1;
            if (i < args.remaining.len) {
                tech_str = args.remaining[i];
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--tech=")) {
            tech_str = args.remaining[i][7..];
        } else {
            project_name = args.remaining[i];
        }
    }

    var scaffolder = scaffold_mod.ProjectScaffolder.init(allocator, project_name, description) catch return;
    defer scaffolder.deinit();

    // Add tech stack from --tech flag (comma-separated) or use defaults
    if (tech_str) |ts| {
        var tech_iter = std.mem.splitScalar(u8, ts, ',');
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

    // Add default requirements across priority levels
    const req1 = allocator.create(scaffold_mod.Requirement) catch return;
    req1.* = scaffold_mod.Requirement.init(allocator, "REQ-01", "Core CLI interface", .critical) catch return;
    req1.setDescription("Users can run the CLI and see help output") catch {};
    req1.setCategory("CLI") catch {};
    req1.addCriterion("CLI starts and shows help") catch {};
    req1.addCriterion("Version flag works") catch {};
    scaffolder.addRequirement(req1) catch {};

    const req2 = allocator.create(scaffold_mod.Requirement) catch return;
    req2.* = scaffold_mod.Requirement.init(allocator, "REQ-02", "AI chat integration", .critical) catch return;
    req2.setDescription("Users can chat with AI providers") catch {};
    req2.setCategory("AI") catch {};
    req2.addCriterion("Chat sends messages to provider") catch {};
    req2.addCriterion("Responses display correctly") catch {};
    scaffolder.addRequirement(req2) catch {};

    const req3 = allocator.create(scaffold_mod.Requirement) catch return;
    req3.* = scaffold_mod.Requirement.init(allocator, "REQ-03", "Configuration management", .high) catch return;
    req3.setDescription("Users can configure providers and API keys") catch {};
    req3.setCategory("Config") catch {};
    scaffolder.addRequirement(req3) catch {};

    const req4 = allocator.create(scaffold_mod.Requirement) catch return;
    req4.* = scaffold_mod.Requirement.init(allocator, "REQ-04", "Plugin system", .medium) catch return;
    req4.setDescription("Extensible plugin architecture for tools") catch {};
    req4.setCategory("Plugin") catch {};
    scaffolder.addRequirement(req4) catch {};

    // Add phases with requirement mappings
    const ph1 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph1.* = scaffold_mod.ScaffoldPhase.init(allocator, 1, "Core Setup") catch return;
    ph1.addRequirement("REQ-01") catch {};
    ph1.addRequirement("REQ-03") catch {};
    scaffolder.addPhase(ph1) catch {};

    const ph2 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph2.* = scaffold_mod.ScaffoldPhase.init(allocator, 2, "AI Integration") catch return;
    ph2.addRequirement("REQ-02") catch {};
    scaffolder.addPhase(ph2) catch {};

    const ph3 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph3.* = scaffold_mod.ScaffoldPhase.init(allocator, 3, "Plugin Extensions") catch return;
    ph3.addRequirement("REQ-04") catch {};
    scaffolder.addPhase(ph3) catch {};

    scaffolder.printSummary();

    stdout_print("\n--- Generated PROJECT.md ---\n", .{});
    const project_md = scaffolder.generateProjectMd() catch return;
    defer allocator.free(project_md);
    stdout_print("{s}\n", .{project_md});

    stdout_print("\n--- Generated REQUIREMENTS.md ---\n", .{});
    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);
    stdout_print("{s}\n", .{reqs_md});

    stdout_print("\n--- Generated ROADMAP.md ---\n", .{});
    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);
    stdout_print("{s}\n", .{roadmap_md});
}
