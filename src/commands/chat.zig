const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const client_mod = @import("client");
const intent_gate_mod = @import("intent_gate");
const lifecycle_hooks_mod = @import("lifecycle_hooks");

const Config = config_mod.Config;
const HookContext = lifecycle_hooks_mod.HookContext;
const IntentGate = intent_gate_mod.IntentGate;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;

fn preRequestHook(ctx: *HookContext) !void {
    std.debug.print("\x1b[2m[hook: {s} → {s}/{s}]\x1b[0m\n", .{
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
    });
}

fn postRequestHook(ctx: *HookContext) !void {
    std.debug.print("\x1b[2m[hook: {s} ← {s}/{s} | tokens: {d}]\x1b[0m\n", .{
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
        ctx.token_count,
    });
}

fn registerCoreChatHooks(hooks: *LifecycleHooks) !void {
    try hooks.register("chat_pre_request", .core, .pre_request, preRequestHook, 10);
    try hooks.register("chat_post_request", .core, .post_request, postRequestHook, 20);
}

fn clampUsizeToU32(value: usize) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

fn clampU64ToU32(value: u64) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

fn freeLastMessage(messages: *std.ArrayList(client_mod.ChatMessage), allocator: std.mem.Allocator) void {
    const removed = messages.pop().?;
    freeChatMessage(removed, allocator);
}

fn freeToolCallInfos(tool_calls: ?[]const client_mod.ToolCallInfo, allocator: std.mem.Allocator) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn freeChatMessage(message: client_mod.ChatMessage, allocator: std.mem.Allocator) void {
    allocator.free(message.role);
    if (message.content) |content| {
        allocator.free(content);
    }
    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }
    freeToolCallInfos(message.tool_calls, allocator);
}

fn rollbackMessagesTo(messages: *std.ArrayList(client_mod.ChatMessage), allocator: std.mem.Allocator, target_len: usize) void {
    while (messages.items.len > target_len) {
        freeLastMessage(messages, allocator);
    }
}

fn duplicateToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const client_mod.ToolCallInfo) !?[]const client_mod.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(client_mod.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn appendResponseMessage(messages: *std.ArrayList(client_mod.ChatMessage), allocator: std.mem.Allocator, message: client_mod.ChatMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, message.role),
        .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
        .tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = try duplicateToolCallInfos(allocator, message.tool_calls),
    });
}

const ToolExecution = struct {
    display: []const u8,
    result: []const u8,
};

fn buildToolFailure(allocator: std.mem.Allocator, tool_call: client_mod.ParsedToolCall, err: anyerror) !ToolExecution {
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 {s} → error: {s}\n", .{ tool_call.name, @errorName(err) }),
        .result = try std.fmt.allocPrint(allocator, "Tool execution failed: {s}", .{@errorName(err)}),
    };
}

fn executeReadFileTool(allocator: std.mem.Allocator, tool_call: client_mod.ParsedToolCall) !ToolExecution {
    const ReadFileArgs = struct { path: []const u8 };

    var parsed = try std.json.parseFromSlice(ReadFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().openFile(parsed.value.path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, stat.size }),
        .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, stat.size, content }),
    };
}

fn executeShellTool(allocator: std.mem.Allocator, tool_call: client_mod.ParsedToolCall) !ToolExecution {
    const ShellArgs = struct {
        command: []const u8,
        timeout: ?u32 = null,
    };

    var parsed = try std.json.parseFromSlice(ShellArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.timeout != null) {
        return error.ToolTimeoutUnsupported;
    }

    const argv: [3][]const u8 = .{ "sh", "-c", parsed.value.command };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\") → exit {d}\n", .{ parsed.value.command, exit_code }),
        .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout.items, stderr.items }),
    };
}

fn executeWriteFileTool(allocator: std.mem.Allocator, tool_call: client_mod.ParsedToolCall) !ToolExecution {
    const WriteFileArgs = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(WriteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    try file.writeAll(parsed.value.content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 write_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, parsed.value.content.len }),
        .result = try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ parsed.value.content.len, parsed.value.path }),
    };
}

fn executeBuiltinTool(allocator: std.mem.Allocator, tool_call: client_mod.ParsedToolCall) !ToolExecution {
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return executeReadFileTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "shell")) {
        return executeShellTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return executeWriteFileTool(allocator, tool_call);
    }
    return error.UnsupportedTool;
}

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;

    // Check for interactive mode
    if (args.interactive) {
        try handleInteractiveChat(args, config, allocator);
        return;
    }

    // Single message mode (original behavior)
    if (args.remaining.len == 0) {
        std.debug.print("Crushcode - AI Coding Assistant\n", .{});
        std.debug.print("Usage: crushcode chat <message> [--provider <name>] [--model <name>] [--interactive]\n\n", .{});
        std.debug.print("Available Providers:\n", .{});
        std.debug.print("  openai - GPT models\n", .{});
        std.debug.print("  anthropic - Claude models\n", .{});
        std.debug.print("  gemini - Gemini models\n", .{});
        std.debug.print("  xai - Grok models\n", .{});
        std.debug.print("  mistral - Mistral models\n", .{});
        std.debug.print("  groq - Groq models\n", .{});
        std.debug.print("  deepseek - DeepSeek models\n", .{});
        std.debug.print("  together - Together AI\n", .{});
        std.debug.print("  azure - Azure OpenAI\n", .{});
        std.debug.print("  vertexai - Google Vertex AI\n", .{});
        std.debug.print("  bedrock - AWS Bedrock\n", .{});
        std.debug.print("  ollama - Local LLM\n", .{});
        std.debug.print("  lm-studio - LM Studio\n", .{});
        std.debug.print("  llama-cpp - llama.cpp\n", .{});
        std.debug.print("  openrouter - OpenRouter\n", .{});
        std.debug.print("  zai - Zhipu AI\n", .{});
        std.debug.print("  vercel-gateway - Vercel Gateway\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  crushcode chat \"Hello! Can you help me?\"\n", .{});
        std.debug.print("  crushcode chat --provider openai --model gpt-4o \"Hello\"\n", .{});
        std.debug.print("  crushcode chat --provider anthropic \"Help me code\"\n", .{});
        std.debug.print("  crushcode chat --interactive\n", .{});
        return;
    }

    const message = args.remaining[0];
    const provider_name = args.provider orelse config.default_provider;
    const model_name = args.model orelse config.default_model;

    // Initialize registry and get provider
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
        std.debug.print("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // Get API key from config
    const api_key = config.getApiKey(provider_name) orelse "";

    if (api_key.len == 0) {
        std.debug.print("Warning: No API key found for provider '{s}'\n", .{provider_name});
        std.debug.print("Add your API key to ~/.crushcode/config.toml\n", .{});
        std.debug.print("Example: {s} = \"your-api-key\"\n\n", .{provider_name});

        if (!std.mem.eql(u8, provider_name, "ollama") and
            !std.mem.eql(u8, provider_name, "lm_studio") and
            !std.mem.eql(u8, provider_name, "llama_cpp"))
        {
            return error.MissingApiKey;
        }
    }

    // Initialize AI client
    var client = try client_mod.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    // Set system prompt from config if available
    if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    std.debug.print("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    const response = client.sendChat(message) catch |err| {
        std.debug.print("\nError sending request: {}\n", .{err});
        return err;
    };

    // Safety check - ensure we have a valid response
    if (response.choices.len == 0) {
        std.debug.print("\nError: Empty response from AI\n", .{});
        return error.EmptyResponse;
    }

    // Simple content extraction with inline null check
    var content_slice: []const u8 = "";
    const choice = response.choices[0];
    if (choice.message.content) |c| {
        content_slice = c;
    }
    std.debug.print("\n{s}\n\n", .{content_slice});
    std.debug.print("---\n", .{});
    std.debug.print("Provider: {s}\n", .{provider_name});
    std.debug.print("Model: {s}\n", .{model_name});
    if (response.usage) |usage| {
        std.debug.print("Tokens used: {d} prompt + {d} completion = {d} total\n", .{
            usage.prompt_tokens,
            usage.completion_tokens,
            usage.total_tokens,
        });
        // Show extended usage info
        const ext = client.extractExtendedUsage(&response);
        std.debug.print("\x1b[2m({d} in / {d} out)\x1b[0m\n", .{ ext.input_tokens, ext.output_tokens });
    }
}

/// Interactive chat mode with streaming support and conversation history
fn handleInteractiveChat(args: args_mod.Args, config: *Config, allocator: std.mem.Allocator) !void {
    const provider_name = args.provider orelse config.default_provider;
    const model_name = args.model orelse config.default_model;

    // Initialize registry
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
        return error.ProviderNotFound;
    };

    const api_key = config.getApiKey(provider_name) orelse "";

    if (api_key.len == 0 and !std.mem.eql(u8, provider_name, "ollama") and
        !std.mem.eql(u8, provider_name, "lm_studio") and
        !std.mem.eql(u8, provider_name, "llama_cpp"))
    {
        std.debug.print("Error: No API key for provider '{s}'. Add to ~/.crushcode/config.toml\n", .{provider_name});
        return error.MissingApiKey;
    }

    // Initialize client
    var client = try client_mod.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    // Set system prompt from config if available
    if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    var hooks = LifecycleHooks.init(allocator);
    defer hooks.deinit();
    try registerCoreChatHooks(&hooks);

    // Conversation history
    var messages = std.ArrayList(client_mod.ChatMessage).init(allocator);
    defer {
        for (messages.items) |msg| {
            freeChatMessage(msg, allocator);
        }
        messages.deinit();
    }

    // Session token tracking
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var request_count: u32 = 0;

    std.debug.print("=== Interactive Chat Mode (Streaming) ===\n", .{});
    std.debug.print("Provider: {s} | Model: {s}\n", .{ provider_name, model_name });
    std.debug.print("Type your message and press Enter. Press Ctrl+C to exit.\n", .{});
    std.debug.print("Commands: /usage | /clear | /hooks | /exit\n", .{});
    std.debug.print("--------------------------------------------\n\n", .{});

    const stdin = std.io.getStdIn();
    const stdin_reader = stdin.reader();

    while (true) {
        // Print prompt
        std.debug.print("\n\x1b[32mYou:\x1b[0m ", .{});

        // Read line
        const line = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256 * 1024) catch {
            std.debug.print("\nError reading input\n", .{});
            break;
        };

        if (line == null) break;

        const user_message = line.?;
        defer allocator.free(user_message);

        if (user_message.len == 0) continue;

        // Handle built-in commands
        if (std.mem.eql(u8, user_message, "exit") or std.mem.eql(u8, user_message, "quit") or std.mem.eql(u8, user_message, "/exit")) {
            std.debug.print("Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, user_message, "/usage")) {
            std.debug.print("\n=== Session Usage ===\n", .{});
            std.debug.print("  Requests: {d}\n", .{request_count});
            std.debug.print("  Tokens: {d} in / {d} out\n", .{ total_input_tokens, total_output_tokens });
            continue;
        }

        if (std.mem.eql(u8, user_message, "/clear")) {
            for (messages.items) |msg| {
                freeChatMessage(msg, allocator);
            }
            messages.clearRetainingCapacity();
            total_input_tokens = 0;
            total_output_tokens = 0;
            request_count = 0;
            std.debug.print("History cleared.\n", .{});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/hooks")) {
            hooks.printHooks();
            continue;
        }

        var intent_arena = std.heap.ArenaAllocator.init(allocator);
        defer intent_arena.deinit();

        var intent_gate = IntentGate.init(intent_arena.allocator());
        defer intent_gate.deinit();

        const intent = intent_gate.classify(user_message);
        std.debug.print("\x1b[2m[intent: {s} ({d:.2})]\x1b[0m\n", .{
            IntentGate.intentLabel(intent.intent_type),
            intent.confidence,
        });

        const turn_start_len = messages.items.len;

        // Add user message to history
        try messages.append(.{
            .role = try allocator.dupe(u8, "user"),
            .content = try allocator.dupe(u8, user_message),
            .tool_call_id = null,
            .tool_calls = null,
        });

        var iteration: u32 = 0;
        var turn_complete = false;
        var turn_failed = false;

        while (iteration < 25) : (iteration += 1) {
            const last_content_len = if (messages.items.len == 0)
                user_message.len
            else
                (messages.items[messages.items.len - 1].content orelse "").len;

            var pre_request_ctx = HookContext.init(allocator);
            defer pre_request_ctx.deinit();
            pre_request_ctx.phase = .pre_request;
            pre_request_ctx.provider = provider_name;
            pre_request_ctx.model = model_name;
            pre_request_ctx.token_count = clampUsizeToU32(last_content_len);
            try hooks.execute(.pre_request, &pre_request_ctx);

            std.debug.print("\n\x1b[36mAssistant:\x1b[0m ", .{});

            const response = (if (iteration == 0)
                client.sendChatStreaming(messages.items, struct {
                    fn onToken(token: []const u8, done: bool) void {
                        _ = done;
                        const stdout = std.io.getStdOut().writer();
                        stdout.print("{s}", .{token}) catch {};
                    }
                }.onToken)
            else
                client.sendChatWithToolResults(messages.items, struct {
                    fn onToken(token: []const u8, done: bool) void {
                        _ = done;
                        const stdout = std.io.getStdOut().writer();
                        stdout.print("{s}", .{token}) catch {};
                    }
                }.onToken)) catch |err| {
                std.debug.print("\n\nError: {}\n", .{err});
                rollbackMessagesTo(&messages, allocator, turn_start_len);
                turn_failed = true;
                break;
            };

            if (response.choices.len == 0) {
                std.debug.print("\n\nError: Empty response from AI\n", .{});
                rollbackMessagesTo(&messages, allocator, turn_start_len);
                turn_failed = true;
                break;
            }

            request_count += 1;
            const choice = response.choices[0];
            const content = choice.message.content orelse "";

            if (response.usage) |usage| {
                total_input_tokens += usage.prompt_tokens;
                total_output_tokens += usage.completion_tokens;
                std.debug.print("\n\x1b[2m({d} tokens in / {d} out | session total: {d})\x1b[0m", .{
                    usage.prompt_tokens,
                    usage.completion_tokens,
                    total_input_tokens + total_output_tokens,
                });
            }

            var post_request_ctx = HookContext.init(allocator);
            defer post_request_ctx.deinit();
            post_request_ctx.phase = .post_request;
            post_request_ctx.provider = provider_name;
            post_request_ctx.model = model_name;
            post_request_ctx.token_count = if (response.usage) |usage|
                clampU64ToU32(usage.total_tokens)
            else
                clampUsizeToU32(content.len);
            try hooks.execute(.post_request, &post_request_ctx);

            try appendResponseMessage(&messages, allocator, choice.message);

            const finish_reason = choice.finish_reason orelse "stop";
            if (std.mem.eql(u8, finish_reason, "tool_calls")) {
                const tool_calls = try client.extractToolCalls(&response);
                defer if (tool_calls.len > 0) allocator.free(tool_calls);

                if (tool_calls.len == 0) {
                    std.debug.print("\n\nError: Model requested tool calls but none were parsed\n", .{});
                    rollbackMessagesTo(&messages, allocator, turn_start_len);
                    turn_failed = true;
                    break;
                }

                const tool_outputs = try allocator.alloc([]const u8, tool_calls.len);
                defer allocator.free(tool_outputs);

                var output_count: usize = 0;
                defer {
                    for (tool_outputs[0..output_count]) |tool_output| {
                        allocator.free(tool_output);
                    }
                }

                for (tool_calls, 0..) |tool_call, idx| {
                    const execution = executeBuiltinTool(allocator, tool_call) catch |err| try buildToolFailure(allocator, tool_call, err);
                    defer allocator.free(execution.display);

                    std.debug.print("\n{s}", .{execution.display});
                    tool_outputs[idx] = execution.result;
                    output_count += 1;
                }

                const tool_messages = try client.buildToolResultMessages(tool_calls, tool_outputs);
                defer allocator.free(tool_messages);

                for (tool_messages) |tool_message| {
                    try messages.append(tool_message);
                }

                std.debug.print("\n", .{});
                continue;
            }

            std.debug.print("\n", .{});
            turn_complete = true;
            break;
        }

        if (!turn_complete and !turn_failed) {
            std.debug.print("\nError: Agent loop hit max iterations (25)\n", .{});
            rollbackMessagesTo(&messages, allocator, turn_start_len);
        }
    }
}

pub const Args = struct {
    command: []const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    config_file: ?[]const u8,
    interactive: bool = false,
    remaining: [][]const u8,
};
