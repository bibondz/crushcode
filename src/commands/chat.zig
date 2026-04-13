const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const profile_mod = @import("profile");
const client_mod = @import("client");
const core = @import("core_api");
const intent_gate_mod = @import("intent_gate");
const lifecycle_hooks_mod = @import("lifecycle_hooks");
const compaction_mod = @import("compaction");
const graph_mod = @import("graph");
const mcp_bridge_mod = @import("mcp_bridge");
const agent_loop_mod = @import("agent_loop");
const tool_executors = @import("chat_tool_executors");
const tools_mod = @import("tools");
const tool_loader = @import("tool_loader");
const skills_loader_mod = @import("skills_loader");
const json_output_mod = @import("json_output");
const permission_mod = @import("permission_evaluate");
const theme_mod = @import("theme");
const memory_mod = @import("memory");
const slash_commands_mod = @import("slash_commands");
const intensity_mod = @import("intensity");
const hotswap_mod = @import("model_hotswap");
const summarizer_mod = @import("session_summarizer");
const color_mod = @import("color");
const tiered_loader_mod = @import("tiered_loader");
const convergence_mod = @import("convergence");
const adversarial_mod = @import("adversarial_review");
const source_tracker_mod = @import("source_tracker");
const knowledge_lint_mod = @import("knowledge_lint");
const spinner_mod = @import("spinner");
const markdown_mod = @import("markdown_renderer");
const error_display_mod = @import("error_display");

const Config = config_mod.Config;
const Profile = profile_mod.Profile;
const Theme = theme_mod.Theme;
const ColorMode = theme_mod.ColorMode;
const Style = color_mod.Style;
const HookContext = lifecycle_hooks_mod.HookContext;
const IntentGate = intent_gate_mod.IntentGate;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;
const ContextCompactor = compaction_mod.ContextCompactor;
const KnowledgeGraph = graph_mod.KnowledgeGraph;
const Bridge = mcp_bridge_mod.Bridge;
const AgentLoop = agent_loop_mod.AgentLoop;
const AIResponse = agent_loop_mod.AIResponse;
const LoopMessage = agent_loop_mod.LoopMessage;
const ToolRegistry = tools_mod.ToolRegistry;
const SlashCommandRegistry = slash_commands_mod.SlashCommandRegistry;
const Intensity = intensity_mod.Intensity;
const ModelHotSwap = hotswap_mod.ModelHotSwap;
const SessionSummarizer = summarizer_mod.SessionSummarizer;
const LoadTier = tiered_loader_mod.LoadTier;
const ConvergenceDetector = convergence_mod.ConvergenceDetector;

const PermissionEvaluator = permission_mod.PermissionEvaluator;
const PermissionConfig = permission_mod.PermissionConfig;
const PermissionMode = permission_mod.PermissionMode;
/// Module-level permission evaluator — initialized once per chat session
var active_evaluator: ?PermissionEvaluator = null;

fn preRequestHook(ctx: *HookContext) !void {
    out("{s}[hook: {s} → {s}/{s}]{s}\n", .{
        Style.dimmed.start(),
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
        Style.dimmed.reset(),
    });
}

fn postRequestHook(ctx: *HookContext) !void {
    out("{s}[hook: {s} ← {s}/{s} | tokens: {d}]{s}\n", .{
        Style.dimmed.start(),
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
        ctx.token_count,
        Style.dimmed.reset(),
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

fn freeLastMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator) void {
    const removed = messages.pop().?;
    freeChatMessage(removed, allocator);
}

fn freeToolCallInfos(tool_calls: ?[]const ai_types.ToolCallInfo, allocator: std.mem.Allocator) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn freeChatMessage(message: core.ChatMessage, allocator: std.mem.Allocator) void {
    allocator.free(message.role);
    if (message.content) |content| {
        allocator.free(content);
    }
    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }
    freeToolCallInfos(message.tool_calls, allocator);
}

fn rollbackMessagesTo(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, target_len: usize) void {
    while (messages.items.len > target_len) {
        freeLastMessage(messages, allocator);
    }
}

fn clearInteractiveHistory(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, total_input_tokens: *u64, total_output_tokens: *u64, request_count: *u32) void {
    for (messages.items) |msg| {
        freeChatMessage(msg, allocator);
    }
    messages.clearRetainingCapacity();
    total_input_tokens.* = 0;
    total_output_tokens.* = 0;
    request_count.* = 0;
}

fn printInteractiveSessionSummary(messages: []const core.ChatMessage, allocator: std.mem.Allocator, total_input_tokens: u64, total_output_tokens: u64) void {
    var summarizer = SessionSummarizer.init(allocator, 100);
    defer summarizer.deinit();

    for (messages) |msg| {
        const role: summarizer_mod.SessionEntry.Role = if (std.mem.eql(u8, msg.role, "user"))
            .user
        else if (std.mem.eql(u8, msg.role, "assistant"))
            .assistant
        else if (std.mem.eql(u8, msg.role, "system"))
            .system
        else
            .tool;
        summarizer.addEntry(role, msg.content orelse "", null) catch {};
    }

    if (summarizer.getEntries().len == 0) {
        return;
    }

    var summary = summarizer.summarize() catch return;
    defer summary.deinit();

    const total_tokens = if (summary.total_tokens > 0)
        summary.total_tokens
    else
        total_input_tokens + total_output_tokens;

    out("\n--- Session Summary ---\n", .{});
    out("  Messages: {d} user, {d} assistant, {d} tool calls\n", .{ summary.user_messages, summary.assistant_messages, summary.tool_calls });
    out("  Tokens: {d} total\n", .{total_tokens});
    out("  Duration: {d}s\n", .{summary.duration_seconds});
}

fn duplicateToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const ai_types.ToolCallInfo) !?[]const ai_types.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(ai_types.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn appendResponseMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, message: core.ChatMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, message.role),
        .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
        .tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = try duplicateToolCallInfos(allocator, message.tool_calls),
    });
}

const InteractiveBridgeContext = struct {
    allocator: std.mem.Allocator,
    client: *core.AIClient,
    messages: *array_list_compat.ArrayList(core.ChatMessage),
    hooks: *LifecycleHooks,
    provider_name: []const u8,
    model_name: []const u8,
    turn_start_len: usize,
    synced_loop_messages: usize,
    turn_request_count: u32,
    turn_failed: bool,
    total_input_tokens: *u64,
    total_output_tokens: *u64,
    request_count: *u32,
    /// Per-request arena — reset after each AI response.
    /// Eliminates per-token/per-JSON-parse individual allocations.
    /// Tokens accumulate in the arena; whole arena freed on reset.
    request_arena: std.heap.ArenaAllocator,
    json_out: json_output_mod.JsonOutput,
};

threadlocal var active_bridge_context: ?*InteractiveBridgeContext = null;
threadlocal var active_streaming_enabled: bool = false;

fn elapsedMillis(start_ms: i64) u64 {
    const end_ms = std.time.milliTimestamp();
    if (end_ms <= start_ms) {
        return 0;
    }
    return @as(u64, @intCast(end_ms - start_ms));
}

fn appendLoopHistoryMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, loop_message: LoopMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, loop_message.role),
        .content = if (loop_message.content.len > 0) try allocator.dupe(u8, loop_message.content) else null,
        .tool_call_id = if (loop_message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = null,
    });
}

fn syncLoopMessagesToOuterHistory(ctx: *InteractiveBridgeContext, loop_messages: []const LoopMessage) !void {
    while (ctx.synced_loop_messages < loop_messages.len) : (ctx.synced_loop_messages += 1) {
        const loop_message = loop_messages[ctx.synced_loop_messages];
        if (std.mem.eql(u8, loop_message.role, "assistant")) {
            continue;
        }
        try appendLoopHistoryMessage(ctx.messages, ctx.allocator, loop_message);
    }
}

fn interactiveStreamCallback(token: []const u8, done: bool) void {
    _ = done;
    if (token.len == 0) {
        return;
    }

    const stdout = file_compat.File.stdout().writer();
    stdout.print("{s}", .{token}) catch {};
}

fn sendInteractiveLoopMessages(allocator: std.mem.Allocator, loop_messages: []const LoopMessage) anyerror!AIResponse {
    const ctx = active_bridge_context orelse return error.MissingBridgeContext;

    // Reset arena for this request — batch-frees all per-request memory
    // from the previous iteration (tokens, parsed JSON, tool call copies).
    _ = ctx.request_arena.reset(.retain_capacity);
    const arena = ctx.request_arena.allocator();

    try syncLoopMessagesToOuterHistory(ctx, loop_messages);

    const last_content_len = if (ctx.messages.items.len == 0)
        0
    else
        (ctx.messages.items[ctx.messages.items.len - 1].content orelse "").len;

    var pre_request_ctx = HookContext.init(arena);
    defer pre_request_ctx.deinit();
    pre_request_ctx.phase = .pre_request;
    pre_request_ctx.provider = ctx.provider_name;
    pre_request_ctx.model = ctx.model_name;
    pre_request_ctx.token_count = clampUsizeToU32(last_content_len);
    try ctx.hooks.execute(.pre_request, &pre_request_ctx);

    // Show thinking indicator while waiting for AI response (Phase F)
    spinner_mod.StreamingSpinner.showStatic("Thinking");

    out("\n{s}Assistant:{s} ", .{ Style.prompt_assistant.start(), Style.prompt_assistant.reset() });

    var response: core.ChatResponse = undefined;
    if (active_streaming_enabled) {
        // Streaming mode — print tokens as they arrive
        response = ctx.client.sendChatStreaming(ctx.messages.items, interactiveStreamCallback) catch |err| {
            ctx.turn_failed = true;
            spinner_mod.StreamingSpinner.clearStatic();
            error_display_mod.printError("Request Failed", @errorName(err));
            return err;
        };
    } else {
        // Non-streaming mode (default) — more reliable, avoids Zig stdlib HTTP bugs
        response = ctx.client.sendChatWithHistory(ctx.messages.items) catch |err| {
            ctx.turn_failed = true;
            spinner_mod.StreamingSpinner.clearStatic();
            error_display_mod.printError("Request Failed", @errorName(err));
            return err;
        };
    }

    spinner_mod.StreamingSpinner.clearStatic();

    if (response.choices.len == 0) {
        ctx.turn_failed = true;
        error_display_mod.printError("Empty Response", "The AI returned an empty response");
        return error.EmptyResponse;
    }

    ctx.turn_request_count += 1;
    ctx.request_count.* += 1;

    const choice = response.choices[0];
    const content = choice.message.content orelse "";
    const finish_reason_text = choice.finish_reason orelse "stop";

    if (response.usage) |usage| {
        ctx.total_input_tokens.* += usage.prompt_tokens;
        ctx.total_output_tokens.* += usage.completion_tokens;
        out("\n{s}({d} tokens in / {d} out | session total: {d}){s}", .{
            Style.dimmed.start(),
            usage.prompt_tokens,
            usage.completion_tokens,
            ctx.total_input_tokens.* + ctx.total_output_tokens.*,
            Style.dimmed.reset(),
        });

        // JSON: emit assistant response and usage
        ctx.json_out.emitAssistant(content);
        ctx.json_out.emitUsage(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    } else {
        // JSON: emit assistant response without usage
        ctx.json_out.emitAssistant(content);
    }
    out("\n", .{});

    var post_request_ctx = HookContext.init(arena);
    defer post_request_ctx.deinit();
    post_request_ctx.phase = .post_request;
    post_request_ctx.provider = ctx.provider_name;
    post_request_ctx.model = ctx.model_name;
    post_request_ctx.token_count = if (response.usage) |usage|
        clampU64ToU32(usage.total_tokens)
    else
        clampUsizeToU32(content.len);
    try ctx.hooks.execute(.post_request, &post_request_ctx);

    try appendResponseMessage(ctx.messages, allocator, choice.message);
    ctx.synced_loop_messages = loop_messages.len + 1;

    // Arena-allocated tool call parsing — no individual free() needed.
    // All memory reclaimed on next arena reset.
    const parsed_tool_calls = try ctx.client.extractToolCallsWithAllocator(&response, arena);

    if (std.mem.eql(u8, finish_reason_text, "tool_calls") and parsed_tool_calls.len == 0) {
        ctx.turn_failed = true;
        out("\nError: Model requested tool calls but none were parsed\n", .{});
        return error.InvalidToolCallResponse;
    }

    var loop_tool_calls: []const AIResponse.ToolCallInfo = &.{};
    if (parsed_tool_calls.len > 0) {
        // Copy into arena — no individual free needed
        const copied = try arena.alloc(AIResponse.ToolCallInfo, parsed_tool_calls.len);
        for (parsed_tool_calls, 0..) |tool_call, i| {
            copied[i] = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
        }
        loop_tool_calls = copied;
    }

    return .{
        .content = content,
        .finish_reason = AIResponse.FinishReason.fromString(finish_reason_text),
        .tool_calls = loop_tool_calls,
    };
}

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;
    const json_out = json_output_mod.JsonOutput.init(args.json);

    // Check for interactive mode
    if (args.interactive) {
        try handleInteractiveChat(args, config, allocator, json_out);
        return;
    }

    // Single message mode (original behavior)
    if (args.remaining.len == 0) {
        out("Crushcode - AI Coding Assistant\n", .{});
        out("Usage: crushcode chat <message> [--provider <name>] [--model <name>] [--interactive]\n\n", .{});
        out("Available Providers:\n", .{});
        out("  openai - GPT models\n", .{});
        out("  anthropic - Claude models\n", .{});
        out("  gemini - Gemini models\n", .{});
        out("  xai - Grok models\n", .{});
        out("  mistral - Mistral models\n", .{});
        out("  groq - Groq models\n", .{});
        out("  deepseek - DeepSeek models\n", .{});
        out("  together - Together AI\n", .{});
        out("  azure - Azure OpenAI\n", .{});
        out("  vertexai - Google Vertex AI\n", .{});
        out("  bedrock - AWS Bedrock\n", .{});
        out("  ollama - Local LLM\n", .{});
        out("  lm-studio - LM Studio\n", .{});
        out("  llama-cpp - llama.cpp\n", .{});
        out("  openrouter - OpenRouter\n", .{});
        out("  zai - Zhipu AI\n", .{});
        out("  vercel-gateway - Vercel Gateway\n", .{});
        out("\nExamples:\n", .{});
        out("  crushcode chat \"Hello! Can you help me?\"\n", .{});
        out("  crushcode chat --provider openai --model gpt-4o \"Hello\"\n", .{});
        out("  crushcode chat --provider anthropic \"Help me code\"\n", .{});
        out("  crushcode chat --interactive\n", .{});
        return;
    }

    const message = args.remaining[0];

    // Load profile - use --profile flag if provided, otherwise load current
    var profile_opt: ?Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    const provider_name = args.provider orelse if (profile_opt) |*p| p.default_provider else config.default_provider;
    const model_name = args.model orelse if (profile_opt) |*p| p.default_model else config.default_model;

    // Initialize registry and get provider
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        out("Error: Provider '{s}' not found\n", .{provider_name});
        out("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // Get API key - check profile first, then config
    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(provider_name) orelse "";
    }

    if (api_key.len == 0) {
        const warn_msg = std.fmt.allocPrint(allocator, "No API key found for provider '{s}'. Add to ~/.crushcode/config.toml\nExample: {s} = \"your-api-key\"", .{ provider_name, provider_name }) catch "Missing API key";
        defer allocator.free(warn_msg);
        error_display_mod.printWarning("Missing API Key", warn_msg);

        if (!std.mem.eql(u8, provider_name, "ollama") and
            !std.mem.eql(u8, provider_name, "lm_studio") and
            !std.mem.eql(u8, provider_name, "llama_cpp"))
        {
            return error.MissingApiKey;
        }
    }

    // Initialize AI client
    var ai_client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer ai_client.deinit();

    // Set system prompt from profile or config if available
    var chat_sys_prompt: ?[]const u8 = null;
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) chat_sys_prompt = p.system_prompt;
    }
    if (chat_sys_prompt == null) {
        chat_sys_prompt = config.getSystemPrompt();
    }

    // Load skills from skills/ directory and append to system prompt
    var skill_xml: ?[]const u8 = null;
    {
        var skill_loader = skills_loader_mod.SkillLoader.init(allocator);
        defer skill_loader.deinit();

        // Load skills from default directory, silently skip if not found
        skill_loader.loadFromDirectory("skills") catch {};
        const skills = skill_loader.getSkills();
        if (skills.len > 0) {
            skill_xml = try skill_loader.toPromptXml(allocator);
        }
    }

    // Append skill XML to system prompt if skills were loaded
    if (skill_xml) |xml| {
        defer allocator.free(xml);
        if (chat_sys_prompt) |existing| {
            const combined = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ existing, xml });
            ai_client.setSystemPrompt(combined);
        } else {
            ai_client.setSystemPrompt(xml);
        }
    } else if (chat_sys_prompt) |sp| {
        ai_client.setSystemPrompt(sp);
    }

    out("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    // JSON: emit session start
    json_out.emitSessionStart(provider_name, model_name);

    var response: core.ChatResponse = undefined;
    var content_slice: []const u8 = "";

    if (args.stream) {
        // Streaming mode
        var full_content = array_list_compat.ArrayList(u8).init(allocator);
        defer full_content.deinit();

        response = ai_client.sendChatStreaming(&[_]core.ChatMessage{.{
            .role = try allocator.dupe(u8, "user"),
            .content = try allocator.dupe(u8, message),
        }}, struct {
            pub fn callback(token: []const u8, done: bool) void {
                _ = done;
                if (token.len > 0) {
                    // Display token in real-time
                    const stdout = file_compat.File.stdout().writer();
                    stdout.print("{s}", .{token}) catch {};
                }
            }
        }.callback) catch |err| {
            out("\nError sending streaming request: {}\n", .{err});
            json_out.emitError(@errorName(err));
            return err;
        };

        out("\n", .{});
        content_slice = "";
    } else {
        // Non-streaming mode (default)
        response = ai_client.sendChat(message) catch |err| {
            out("\nError sending request: {}\n", .{err});
            json_out.emitError(@errorName(err));
            return err;
        };

        // Safety check - ensure we have a valid response
        if (response.choices.len == 0) {
            error_display_mod.printError("Empty Response", "The AI returned an empty response");
            return error.EmptyResponse;
        }

        // Simple content extraction with inline null check
        const choice = response.choices[0];
        if (choice.message.content) |c| {
            content_slice = c;
        }
    }
    // Render AI response with markdown formatting (Phase F)
    markdown_mod.MarkdownRenderer.render(content_slice);
    out("\n", .{});
    out("---\n", .{});
    out("Provider: {s}\n", .{provider_name});
    out("Model: {s}\n", .{model_name});
    if (response.usage) |usage| {
        out("Tokens used: {d} prompt + {d} completion = {d} total\n", .{
            usage.prompt_tokens,
            usage.completion_tokens,
            usage.total_tokens,
        });
        // Show extended usage info
        const ext = ai_client.extractExtendedUsage(&response);
        out("{s}({d} in / {d} out){s}\n", .{ Style.dimmed.start(), ext.input_tokens, ext.output_tokens, Style.dimmed.reset() });

        // JSON: emit assistant response and usage
        json_out.emitAssistant(content_slice);
        json_out.emitUsage(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    } else {
        // JSON: emit assistant response without usage
        json_out.emitAssistant(content_slice);
    }
    // JSON: emit session end
    json_out.emitSessionEnd();
}

/// Interactive chat mode with streaming support and conversation history
fn handleInteractiveChat(args: args_mod.Args, config: *Config, allocator: std.mem.Allocator, json_out: json_output_mod.JsonOutput) !void {
    // Load profile - use --profile flag if provided, otherwise load current
    var profile_opt: ?Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    var current_provider_name = args.provider orelse if (profile_opt) |*p| p.default_provider else config.default_provider;
    var current_model_name = args.model orelse if (profile_opt) |*p| p.default_model else config.default_model;

    // Initialize registry
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(current_provider_name) orelse {
        const err_msg = std.fmt.allocPrint(allocator, "Provider '{s}' is not registered. Run 'crushcode list' to see available providers.", .{current_provider_name}) catch "Unknown provider";
        defer allocator.free(err_msg);
        error_display_mod.printError("Provider Not Found", err_msg);
        return error.ProviderNotFound;
    };

    // Get API key - check profile first, then config
    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(current_provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(current_provider_name) orelse "";
    }

    if (api_key.len == 0 and !std.mem.eql(u8, current_provider_name, "ollama") and
        !std.mem.eql(u8, current_provider_name, "lm_studio") and
        !std.mem.eql(u8, current_provider_name, "llama_cpp"))
    {
        const key_msg = std.fmt.allocPrint(allocator, "No API key found for provider '{s}'. Add to ~/.crushcode/config.toml or profile.", .{current_provider_name}) catch "Missing API key";
        defer allocator.free(key_msg);
        error_display_mod.printError("Missing API Key", key_msg);
        return error.MissingApiKey;
    }

    // Initialize client
    var client = try core.AIClient.init(allocator, provider, current_model_name, api_key);
    defer client.deinit();

    var hotswap = ModelHotSwap.init(allocator, current_provider_name, current_model_name) catch null;
    defer if (hotswap) |*hs| hs.deinit();

    // Set system prompt from profile or config if available
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) {
            client.setSystemPrompt(p.system_prompt);
        }
    } else if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    // Apply output intensity modifier to system prompt
    const intensity_level = Intensity.parse(args.intensity orelse "normal") orelse .normal;
    if (intensity_level != .normal) {
        const current_prompt = client.system_prompt orelse config.getSystemPrompt() orelse "";
        const modifier = intensity_level.systemPromptMod();
        const enhanced = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ current_prompt, modifier }) catch current_prompt;
        client.setSystemPrompt(enhanced);
        out("{s}[intensity: {s}]{s}\n", .{ Style.dimmed.start(), intensity_level.label(), Style.dimmed.reset() });
    }

    // Initialize permission evaluator from --permission flag
    if (args.permission) |perm_str| {
        const mode = PermissionMode.fromString(perm_str) orelse blk: {
            out("Warning: Unknown permission mode '{s}' — using default\n", .{perm_str});
            break :blk PermissionMode.default;
        };
        const perm_config = PermissionConfig.init(allocator);
        var eval_config = perm_config;
        eval_config.mode = mode;
        active_evaluator = PermissionEvaluator.init(allocator, eval_config);
        out("{s}[Permission] mode: {s}{s}\n", .{ Style.dimmed.start(), mode.toString(), Style.dimmed.reset() });
    }
    tool_executors.setPermissionEvaluator(if (active_evaluator) |*ev| ev else null);
    defer {
        tool_executors.setPermissionEvaluator(null);
        if (active_evaluator) |*ev| {
            ev.deinit();
            active_evaluator = null;
        }
    }

    // Define available tools for function calling (OpenAI schema format)
    const default_tool_schemas = try tool_loader.loadDefaultToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, default_tool_schemas);

    const user_tool_schemas = try tool_loader.loadUserToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, user_tool_schemas);

    const merged_tool_schemas = try tool_loader.mergeToolSchemas(allocator, default_tool_schemas, user_tool_schemas);
    defer tool_loader.freeToolSchemas(allocator, merged_tool_schemas);

    const builtin_tool_schemas = try tool_executors.collectSupportedToolSchemas(allocator, merged_tool_schemas);
    defer allocator.free(builtin_tool_schemas);

    client.setTools(builtin_tool_schemas);

    // Initialize MCP bridge if MCP servers are configured
    var mcp_client = mcp_bridge_mod.MCPClient.init(allocator);
    var mcp_bridge: ?Bridge = if (config.mcp_servers.len > 0) Bridge.init(allocator, &mcp_client) catch null else null;
    var mcp_schemas: []const core.ToolSchema = &.{};
    defer tool_loader.freeToolSchemas(allocator, mcp_schemas);
    var combined_tool_schemas: ?[]const core.ToolSchema = null;
    defer if (combined_tool_schemas) |schemas| allocator.free(schemas);
    defer {
        if (mcp_bridge != null) {
            mcp_bridge.?.deinit();
        }
        mcp_client.deinit();
    }

    // Connect to MCP servers and discover tools
    if (mcp_bridge) |*bridge| {
        for (config.mcp_servers) |server_config| {
            const bridge_config = mcp_bridge_mod.MCPServerConfig{
                .transport = if (std.mem.eql(u8, server_config.transport orelse "stdio", "sse"))
                    mcp_bridge_mod.TransportType.sse
                else if (std.mem.eql(u8, server_config.transport orelse "stdio", "http"))
                    mcp_bridge_mod.TransportType.http
                else
                    mcp_bridge_mod.TransportType.stdio,
                .command = server_config.command,
                .url = server_config.url,
            };
            bridge.addServer(bridge_config) catch |err| {
                std.log.warn("Failed to add MCP server '{s}': {}", .{ server_config.name, err });
                continue;
            };
        }
        bridge.connectAll(&[_]mcp_bridge_mod.MCPServerConfig{});

        mcp_schemas = bridge.getToolSchemas(allocator) catch &[_]core.ToolSchema{};
        if (mcp_schemas.len > 0) {
            var all_tools = array_list_compat.ArrayList(core.ToolSchema).init(allocator);
            defer all_tools.deinit();

            for (builtin_tool_schemas) |ts| {
                try all_tools.append(ts);
            }
            for (mcp_schemas) |ts| {
                try all_tools.append(ts);
            }
            const combined = try all_tools.toOwnedSlice();
            combined_tool_schemas = combined;
            client.setTools(combined);
            std.log.info("Loaded {d} MCP tools from {d} servers", .{ mcp_schemas.len, bridge.getStats().servers });
        }
    }

    // Build codebase knowledge graph with tiered context loading (F2)
    var kg = KnowledgeGraph.init(allocator);
    defer kg.deinit();

    // Select tier based on context loading strategy
    // Default to focused; can be overridden via config in future
    const context_tier = LoadTier.focused;
    const max_files = context_tier.maxPages();

    const default_src_files = [_][]const u8{
        "src/main.zig",
        "src/ai/client.zig",
        "src/ai/registry.zig",
        "src/commands/handlers.zig",
        "src/commands/chat.zig",
        "src/config/config.zig",
        "src/cli/args.zig",
        "src/agent/loop.zig",
        "src/agent/compaction.zig",
        "src/graph/graph.zig",
        "src/graph/parser.zig",
        "src/streaming/session.zig",
        "src/plugin/mod.zig",
        "src/tools/registry.zig",
    };
    var indexed_count: u32 = 0;
    const files_to_index = @min(default_src_files.len, max_files);
    for (default_src_files[0..files_to_index]) |file_path| {
        kg.indexFile(file_path) catch continue;
        indexed_count += 1;
    }
    kg.detectCommunities() catch {};

    // Convergence detector for agent loop iteration tracking (F14)
    var convergence_detector = ConvergenceDetector.init();

    if (indexed_count > 0) {
        const graph_ctx = kg.toCompressedContext(allocator) catch null;
        if (graph_ctx) |ctx| {
            // Build enhanced system prompt with codebase context
            const base_prompt = client.system_prompt orelse "You are a helpful AI coding assistant with access to the user's codebase.";
            const enhanced = std.fmt.allocPrint(allocator,
                \\{s}
                \\
                \\## Codebase Context (Knowledge Graph)
                \\The following is an auto-generated compressed representation of the local codebase structure.
                \\Use this to understand the project architecture without needing to read every file.
                \\
                \\{s}
                \\
                \\## Available Tools
                \\You can call these tools during conversation:
                \\- read_file(path: string) — Read a file's contents
                \\- shell(command: string) — Execute a shell command
                \\- write_file(path: string, content: string) — Write content to a file
                \\- glob(pattern: string) — Find files matching a glob pattern
                \\- grep(pattern: string, path?: string) — Search file contents by regex
                \\- edit(file_path: string, old_string: string, new_string: string) — Replace text in a file
            , .{ base_prompt, ctx }) catch base_prompt;
            client.setSystemPrompt(enhanced);
            out("{s}[graph: {d} files indexed, {d} symbols, {d:.1}x compression]{s}\n", .{
                Style.dimmed.start(),
                indexed_count,
                kg.nodes.count(),
                kg.compressionRatio(),
                Style.dimmed.reset(),
            });
        }
    }

    // Initialize slash command registry
    var slash_registry = SlashCommandRegistry.init(allocator);
    defer slash_registry.deinit();
    try slash_registry.registerDefaults();

    var hooks = LifecycleHooks.init(allocator);
    defer hooks.deinit();
    try registerCoreChatHooks(&hooks);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.registerBuiltinTools();
    const available_tools = try tool_registry.getAvailableTools(allocator);
    defer allocator.free(available_tools);
    std.debug.assert(available_tools.len > 0);

    var agent_loop = AgentLoop.init(allocator);
    defer agent_loop.deinit();
    var loop_config = agent_loop_mod.LoopConfig.init();
    loop_config.show_intermediate = false;
    agent_loop.setConfig(loop_config);
    try tool_executors.registerBuiltinAgentTools(&agent_loop, builtin_tool_schemas);

    // Conversation history
    var messages = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
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

    // Auto-compaction: compact context when approaching token limits
    // Default max context = 128k tokens, compact at 80% = ~102k tokens
    var compactor = ContextCompactor.init(allocator, 128_000);
    defer compactor.deinit();
    compactor.setRecentWindow(10); // Keep last 10 messages at full fidelity

    out("=== Interactive Chat Mode (Streaming) ===\n", .{});
    out("Provider: {s} | Model: {s}\n", .{ current_provider_name, current_model_name });
    out("Type your message and press Enter. Press Ctrl+C to exit.\n", .{});
    out("Commands: /help | /usage | /clear | /hooks | /compact | /graph | /model | /exit\n", .{});
    out("--------------------------------------------\n\n", .{});

    // JSON: emit session start
    json_out.emitSessionStart(current_provider_name, current_model_name);

    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    while (true) {
        // Print prompt
        out("\n{s}You:{s} ", .{ Style.prompt_user.start(), Style.prompt_user.reset() });

        // Read line
        const line = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256 * 1024) catch {
            out("\nError reading input\n", .{});
            break;
        };

        if (line == null) break;

        const user_message = line.?;
        defer allocator.free(user_message);

        if (user_message.len == 0) continue;

        if (std.mem.eql(u8, user_message, "/hooks")) {
            hooks.printHooks();
            continue;
        }

        if (std.mem.eql(u8, user_message, "/compact")) {
            out("\n=== Manual Compaction ===\n", .{});
            compactor.printStatus(total_input_tokens + total_output_tokens);

            if (messages.items.len > 12) {
                out("  Compacting now...\n", .{});
                var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch continue;
                defer compact_msgs.deinit();
                for (messages.items) |msg| {
                    compact_msgs.appendAssumeCapacity(.{
                        .role = msg.role,
                        .content = msg.content orelse "",
                        .timestamp = null,
                    });
                }
                const result = compactor.compact(compact_msgs.items) catch |err| {
                    out("  Compaction failed: {}\n", .{err});
                    continue;
                };
                if (result.messages_summarized > 0) {
                    for (messages.items) |msg| {
                        freeChatMessage(msg, allocator);
                    }
                    messages.clearRetainingCapacity();
                    const summary_content = std.fmt.allocPrint(allocator, "{s}", .{result.summary}) catch continue;
                    messages.append(.{
                        .role = allocator.dupe(u8, "system") catch continue,
                        .content = summary_content,
                        .tool_call_id = null,
                        .tool_calls = null,
                    }) catch continue;
                    for (result.messages) |compact_msg| {
                        messages.append(.{
                            .role = allocator.dupe(u8, compact_msg.role) catch continue,
                            .content = if (compact_msg.content.len > 0) allocator.dupe(u8, compact_msg.content) catch continue else null,
                            .tool_call_id = null,
                            .tool_calls = null,
                        }) catch continue;
                    }
                    allocator.free(result.summary);
                    out("  Compacted {d} messages, saved ~{d} tokens.\n", .{
                        result.messages_summarized,
                        result.tokens_saved,
                    });
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/graph")) {
            out("\n=== Knowledge Graph Status ===\n", .{});
            out("  Files indexed: {d}\n", .{kg.file_count});
            out("  Nodes: {d}\n", .{kg.nodes.count()});
            out("  Edges: {d}\n", .{kg.edges.items.len});
            out("  Communities: {d}\n", .{kg.communities.items.len});
            if (kg.compressionRatio() > 0) {
                out("  Compression: {d:.1}x\n", .{kg.compressionRatio()});
            }
            out("  [graph context already injected into system prompt]\n", .{});
            continue;
        }

        // /model command — show or swap model
        if (std.mem.eql(u8, user_message, "/model") or std.mem.startsWith(u8, user_message, "/model ")) {
            const model_arg = std.mem.trim(u8, user_message["/model".len..], " ");
            if (model_arg.len == 0) {
                if (hotswap) |hs| {
                    out("Current model: {s}/{s} (swaps: {d})\n", .{ hs.providerName(), hs.modelName(), hs.swapCount() });
                } else {
                    out("Current model: {s}/{s}\n", .{ current_provider_name, current_model_name });
                }
            } else {
                const slash_idx = std.mem.indexOfScalar(u8, model_arg, '/');
                if (slash_idx) |idx| {
                    const new_provider = model_arg[0..idx];
                    const new_model = model_arg[idx + 1 ..];
                    const new_provider_cfg = registry.getProvider(new_provider) orelse {
                        out("{s}Error: Provider '{s}' not found{s}\n", .{ Style.err.start(), new_provider, Style.err.reset() });
                        continue;
                    };

                    var new_api_key: []const u8 = "";
                    if (profile_opt) |*p| {
                        new_api_key = p.getApiKey(new_provider) orelse "";
                    }
                    if (new_api_key.len == 0) {
                        new_api_key = config.getApiKey(new_provider) orelse "";
                    }

                    if (new_api_key.len == 0 and !std.mem.eql(u8, new_provider, "ollama") and
                        !std.mem.eql(u8, new_provider, "lm_studio") and
                        !std.mem.eql(u8, new_provider, "llama_cpp"))
                    {
                        out("{s}Error: No API key for provider '{s}'{s}\n", .{ Style.err.start(), new_provider, Style.err.reset() });
                        continue;
                    }

                    if (hotswap) |*hs| {
                        hs.swap(new_provider, new_model, .manual) catch {
                            out("Error swapping model\n", .{});
                            continue;
                        };
                        current_provider_name = hs.providerName();
                        current_model_name = hs.modelName();
                    } else {
                        out("Error: model hot-swap unavailable\n", .{});
                        continue;
                    }

                    client.provider = new_provider_cfg;
                    client.model = current_model_name;
                    client.api_key = new_api_key;

                    out("Swapped to {s}/{s}\n", .{ current_provider_name, current_model_name });
                } else {
                    out("Usage: /model provider/model\n", .{});
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "exit") or std.mem.eql(u8, user_message, "quit")) {
            printInteractiveSessionSummary(messages.items, allocator, total_input_tokens, total_output_tokens);
            out("Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, user_message, "/usage")) {
            out("\n=== Session Usage ===\n", .{});
            out("  Requests: {d}\n", .{request_count});
            out("  Tokens: {d} in / {d} out\n", .{ total_input_tokens, total_output_tokens });
            continue;
        }

        // Check if slash command
        if (SlashCommandRegistry.isSlashCommand(user_message)) {
            const maybe_result = slash_registry.execute(user_message) catch |err| {
                out("Command error: {}\n", .{err});
                continue;
            };

            if (maybe_result) |result_value| {
                var result = result_value;
                defer result.deinit();

                if (result.should_exit) {
                    printInteractiveSessionSummary(messages.items, allocator, total_input_tokens, total_output_tokens);
                    out("Goodbye!\n", .{});
                    break;
                }

                out("{s}\n", .{result.output});
                if (result.should_clear) {
                    clearInteractiveHistory(&messages, allocator, &total_input_tokens, &total_output_tokens, &request_count);
                }
                continue;
            }
        }

        var intent_arena = std.heap.ArenaAllocator.init(allocator);
        defer intent_arena.deinit();

        var intent_gate = IntentGate.init(intent_arena.allocator());
        defer intent_gate.deinit();

        const intent = intent_gate.classify(user_message);
        out("{s}[intent: {s} ({d:.2})]{s}\n", .{
            Style.dimmed.start(),
            IntentGate.intentLabel(intent.intent_type),
            intent.confidence,
            Style.dimmed.reset(),
        });

        const turn_start_len = messages.items.len;

        var bridge_ctx = InteractiveBridgeContext{
            .allocator = allocator,
            .client = &client,
            .messages = &messages,
            .hooks = &hooks,
            .provider_name = current_provider_name,
            .model_name = current_model_name,
            .turn_start_len = turn_start_len,
            .synced_loop_messages = 0,
            .turn_request_count = 0,
            .turn_failed = false,
            .total_input_tokens = &total_input_tokens,
            .total_output_tokens = &total_output_tokens,
            .request_count = &request_count,
            .request_arena = std.heap.ArenaAllocator.init(allocator),
            .json_out = json_out,
        };
        defer bridge_ctx.request_arena.deinit();

        active_bridge_context = &bridge_ctx;
        tool_executors.setJsonOutput(json_out);
        active_streaming_enabled = args.stream;
        var loop_result = try agent_loop.run(sendInteractiveLoopMessages, user_message);
        active_bridge_context = null;
        tool_executors.setJsonOutput(.{ .enabled = false });
        active_streaming_enabled = false;
        defer loop_result.deinit();

        const hit_max_iterations = loop_result.steps.items.len > 0 and
            loop_result.total_iterations >= loop_config.max_iterations and
            loop_result.steps.items[loop_result.steps.items.len - 1].has_tool_calls;

        if (bridge_ctx.turn_failed) {
            rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

        if (hit_max_iterations) {
            out("\nError: Agent loop hit max iterations ({d})\n", .{loop_config.max_iterations});
            rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

        // Convergence detection — check if agent iterations are plateauing (F14)
        if (loop_result.steps.items.len > 1) {
            var converged = false;
            for (loop_result.steps.items, 0..) |step, i| {
                if (i > 0 and step.ai_response.len > 0 and loop_result.steps.items[i - 1].ai_response.len > 0) {
                    const prev = loop_result.steps.items[i - 1].ai_response;
                    const curr = step.ai_response;
                    if (convergence_detector.checkConvergence(prev, curr)) {
                        out("{s}[convergence: iterations plateauing after {d} steps]{s}\n", .{
                            Style.dimmed.start(),
                            i + 1,
                            Style.dimmed.reset(),
                        });
                        converged = true;
                        break;
                    }
                }
            }
            if (!converged) {
                convergence_detector.reset();
            }
        }

        // Auto-compact context when approaching token limits
        const session_tokens = total_input_tokens + total_output_tokens;
        if (compactor.needsCompaction(session_tokens) and messages.items.len > 12) {
            out("\n{s}⚡ Context approaching limit ({d} tokens). Compacting...{s}\n", .{ Style.warning.start(), session_tokens, Style.warning.reset() });

            // Convert ChatMessages to CompactMessages for compaction
            var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch continue;
            defer compact_msgs.deinit();
            for (messages.items) |msg| {
                compact_msgs.appendAssumeCapacity(.{
                    .role = msg.role,
                    .content = msg.content orelse "",
                    .timestamp = null,
                });
            }

            const result = compactor.compact(compact_msgs.items) catch |err| {
                out("Compaction failed: {}\n", .{err});
                continue;
            };

            if (result.messages_summarized > 0) {
                // Free old messages
                for (messages.items) |msg| {
                    freeChatMessage(msg, allocator);
                }
                messages.clearRetainingCapacity();

                // Add summary as a system message
                const summary_content = std.fmt.allocPrint(allocator, "{s}", .{result.summary}) catch continue;

                messages.append(.{
                    .role = allocator.dupe(u8, "system") catch continue,
                    .content = summary_content,
                    .tool_call_id = null,
                    .tool_calls = null,
                }) catch continue;

                // Re-add preserved recent messages
                for (result.messages) |compact_msg| {
                    messages.append(.{
                        .role = allocator.dupe(u8, compact_msg.role) catch continue,
                        .content = if (compact_msg.content.len > 0) allocator.dupe(u8, compact_msg.content) catch continue else null,
                        .tool_call_id = null,
                        .tool_calls = null,
                    }) catch continue;
                }

                // Free the summary if it was allocated (compactor owns it, but we copied it)
                allocator.free(result.summary);

                out("{s}  Compacted {d} messages. Saved ~{d} tokens.{s}\n", .{
                    Style.warning.start(),
                    result.messages_summarized,
                    result.tokens_saved,
                    Style.warning.reset(),
                });
            }
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
