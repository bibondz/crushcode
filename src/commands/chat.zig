const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const chat_helpers = @import("chat_helpers");
const chat_bridge = @import("chat_bridge");
const agent_setup = @import("agent_setup");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

fn estimateCompactTokens(messages: []const compaction_mod.CompactMessage) u64 {
    var total: u64 = 0;
    for (messages) |msg| {
        total += ContextCompactor.estimateTokens(msg.content);
    }
    return total;
}

fn replaceMessagesFromCompaction(
    allocator: std.mem.Allocator,
    messages: *array_list_compat.ArrayList(core.ChatMessage),
    summary: ?[]const u8,
    compact_messages: []const compaction_mod.CompactMessage,
) !void {
    var rebuilt = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
    errdefer {
        for (rebuilt.items) |msg| {
            chat_helpers.freeChatMessage(msg, allocator);
        }
        rebuilt.deinit();
    }

    if (summary) |summary_text| {
        if (summary_text.len > 0) {
            try rebuilt.append(.{
                .role = try allocator.dupe(u8, "system"),
                .content = try allocator.dupe(u8, summary_text),
                .tool_call_id = null,
                .tool_calls = null,
            });
        }
    }

    for (compact_messages) |compact_msg| {
        try rebuilt.append(.{
            .role = try allocator.dupe(u8, compact_msg.role),
            .content = if (compact_msg.content.len > 0) try allocator.dupe(u8, compact_msg.content) else null,
            .tool_call_id = null,
            .tool_calls = null,
        });
    }

    for (messages.items) |msg| {
        chat_helpers.freeChatMessage(msg, allocator);
    }
    messages.clearRetainingCapacity();

    for (rebuilt.items) |msg| {
        try messages.append(msg);
    }
    rebuilt.deinit();
}

fn findLastAssistantMessageIndex(messages: []const core.ChatMessage) ?usize {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (std.mem.eql(u8, message.role, "assistant")) {
            return i;
        }
    }
    return null;
}

fn sourceTypeForRole(role: []const u8) source_tracker_mod.SourceProvenance.SourceType {
    if (std.mem.eql(u8, role, "user")) return .user_input;
    if (std.mem.eql(u8, role, "assistant")) return .ai_generated;
    if (std.mem.eql(u8, role, "tool")) return .tool_output;
    if (std.mem.eql(u8, role, "system")) return .derived;
    return .derived;
}

fn sourceTypeLabel(source_type: source_tracker_mod.SourceProvenance.SourceType) []const u8 {
    return @tagName(source_type);
}

fn revisionOutcomeLabel(outcome: revision_loop_mod.RevisionOutcome) []const u8 {
    return @tagName(outcome);
}

const SessionLintFinding = struct {
    severity: knowledge_lint_mod.LintSeverity,
    rule: knowledge_lint_mod.LintFinding.LintRule,
    message: []const u8,
    location: ?[]const u8 = null,
    suggestion: ?[]const u8 = null,

    fn deinit(self: *SessionLintFinding, allocator: std.mem.Allocator) void {
        if (self.location) |location| allocator.free(location);
        if (self.suggestion) |suggestion| allocator.free(suggestion);
    }
};

fn computeRevisionChangeRatio(prev: []const u8, curr: []const u8) f64 {
    if (prev.len == 0 and curr.len == 0) return 0.0;
    if (prev.len == 0 or curr.len == 0) return 1.0;

    const len_diff = if (prev.len > curr.len) prev.len - curr.len else curr.len - prev.len;
    const max_len = @max(prev.len, curr.len);
    const sample_size = @min(@as(usize, 256), @min(prev.len, curr.len));

    var diff_count: usize = 0;
    if (sample_size > 0) {
        const step = @max(@as(usize, 1), @min(prev.len, curr.len) / sample_size);
        var i: usize = 0;
        while (i < @min(prev.len, curr.len)) : (i += step) {
            if (prev[i] != curr[i]) diff_count += 1;
        }
    }

    const len_ratio = @as(f64, @floatFromInt(len_diff)) / @as(f64, @floatFromInt(max_len));
    const char_ratio = if (sample_size > 0)
        @as(f64, @floatFromInt(diff_count)) / @as(f64, @floatFromInt(sample_size))
    else
        0.0;
    return (len_ratio + char_ratio) / 2.0;
}

const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const profile_mod = @import("profile");
const client_mod = @import("client");
const core = @import("core_api");
const http_client = @import("http_client");
const intent_gate_mod = @import("intent_gate");
const lifecycle_hooks_mod = @import("lifecycle_hooks");
const guardian_mod = @import("guardian");
const compaction_mod = @import("compaction");
const context_budget_mod = @import("context_budget");
const project_memory_mod = @import("project_memory");
const usage_pricing_mod = @import("usage_pricing");
const usage_budget_mod = @import("usage_budget");
const file_watcher_mod = @import("file_watcher");
const graph_mod = @import("graph");
const cognition_mod = @import("cognition");
const mcp_bridge_mod = @import("mcp_bridge");
const agent_loop_mod = @import("agent_loop");
const moa_mod = @import("moa");
const tool_executors = @import("chat_tool_executors");
const tools_mod = @import("tools");
const tool_loader = @import("tool_loader");
const skills_loader_mod = @import("skills_loader");
const json_output_mod = @import("json_output");
const permission_mod = @import("permission_evaluate");
const audit_mod = @import("permission_audit");
const env_mod = @import("env");
const shell_state_mod = @import("shell_state");
const shell_history_mod = @import("shell_history");
const blocklist_mod = @import("permission_blocklist");
const safelist_mod = @import("permission_safelist");
const session_mod = @import("session");
const theme_mod = @import("theme");
const memory_mod = @import("memory");
const slash_commands_mod = @import("slash_commands");
const intensity_mod = @import("intensity");
const hotswap_mod = @import("model_hotswap");
const summarizer_mod = @import("session_summarizer");
const revision_loop_mod = @import("revision_loop");
const color_mod = @import("color");
const tiered_loader_mod = @import("tiered_loader");
const convergence_mod = @import("convergence");
const adversarial_mod = @import("adversarial_review");
const source_tracker_mod = @import("source_tracker");
const knowledge_lint_mod = @import("knowledge_lint");
const custom_commands_mod = @import("custom_commands.zig");
const structured_log_mod = @import("structured_log");
const spinner_mod = @import("spinner");
const markdown_mod = @import("markdown_renderer");
const error_display_mod = @import("error_display");
const file_tracker_mod = @import("file_tracker");
const autopilot_mod = @import("autopilot");
const phase_runner_mod = @import("phase_runner");
const orchestration_mod = @import("orchestration");

const Config = config_mod.Config;
const Profile = profile_mod.Profile;
const Theme = theme_mod.Theme;
const ColorMode = theme_mod.ColorMode;
const Style = color_mod.Style;
const HookContext = lifecycle_hooks_mod.HookContext;

/// Map a Zig error from the AI request path to a friendly boxed error message.
/// Uses error_display_mod.printBoxed() for consistent UX.
fn printRequestError(err: anyerror) void {
    const title: []const u8 = "Request Failed";
    const message: []const u8 = switch (err) {
        error.ServerError => "The AI provider returned a server error.\nPlease try again in a moment.",
        error.NetworkError => "Could not connect to the AI provider.\nCheck your internet connection.",
        error.AuthenticationError => "Authentication failed — check your API key.\nRun: crushcode connect <provider>",
        error.RateLimitError => "Rate limit exceeded — too many requests.\nWait a minute and try again.",
        error.TimeoutError => "The request timed out.\nThe provider may be slow or overloaded.",
        error.RetryExhausted => "Request failed after multiple retries.\nThe provider may be experiencing issues.",
        error.EmptyResponse => "The AI returned an empty response.\nTry rephrasing your message.",
        error.ConfigurationError => "Configuration error — check your settings.\nRun: crushcode connect <provider>",
        error.OutOfMemory => "Out of memory. Try a shorter message or restart.",
        else => "An unexpected error occurred.\nPlease try again.",
    };
    error_display_mod.printError(title, message);
}

/// Check if an error is transient (worth retrying with non-streaming fallback).
fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.ServerError,
        error.NetworkError,
        error.TimeoutError,
        => true,
        else => false,
    };
}
const IntentGate = intent_gate_mod.IntentGate;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;
const Guardian = guardian_mod.Guardian;
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

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;
    const json_out = json_output_mod.JsonOutput.init(args.json);

    http_client.initSharedClient(allocator);
    defer http_client.deinitSharedClient();

    if (args.interactive) {
        try handleInteractiveChat(args, config, allocator, json_out);
        return;
    }

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

    var profile_opt: ?Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    const provider_name = args.provider orelse
        if (profile_opt) |*p| (if (p.default_provider.len > 0) p.default_provider else config.default_provider) else config.default_provider;
    const model_name = args.model orelse
        if (profile_opt) |*p| (if (p.default_model.len > 0) p.default_model else config.default_model) else config.default_model;

    if (provider_name.len == 0) {
        out("Error: No provider configured. Set one with:\n", .{});
        out("  crushcode connect <provider>\n", .{});
        out("  Or edit ~/.crushcode/config.toml\n", .{});
        return error.ProviderNotFound;
    }

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        out("Error: Provider '{s}' not found\n", .{provider_name});
        out("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

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

        if (!provider.config.is_local) {
            return error.MissingApiKey;
        }
    }

    var ai_client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer ai_client.deinit();

    ai_client.max_tokens = config.max_tokens;
    ai_client.temperature = config.temperature;

    if (config.getProviderOverrideUrl(provider_name)) |override_url| {
        allocator.free(ai_client.provider.config.base_url);
        ai_client.provider.config.base_url = try allocator.dupe(u8, override_url);
    }

    var chat_sys_prompt: ?[]const u8 = null;
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) chat_sys_prompt = p.system_prompt;
    }
    if (chat_sys_prompt == null) {
        chat_sys_prompt = config.getSystemPrompt();
    }

    var skill_xml: ?[]const u8 = null;
    {
        var skill_loader = skills_loader_mod.SkillLoader.init(allocator);
        defer skill_loader.deinit();

        skill_loader.loadFromDirectory("skills") catch {};
        skill_loader.loadFromDirectory(".alloy") catch {};
        const skills = skill_loader.getSkills();
        if (skills.len > 0) {
            skill_xml = try skill_loader.toPromptXml(allocator);
        }
    }

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

    // Load tool schemas so AI knows about available tools
    const ss_default_tool_schemas = try tool_loader.loadDefaultToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, ss_default_tool_schemas);
    const ss_user_tool_schemas = try tool_loader.loadUserToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, ss_user_tool_schemas);
    const ss_merged_schemas = try tool_loader.mergeToolSchemas(allocator, ss_default_tool_schemas, ss_user_tool_schemas);
    defer tool_loader.freeToolSchemas(allocator, ss_merged_schemas);
    const ss_builtin_schemas = try tool_executors.collectSupportedToolSchemas(allocator, ss_merged_schemas);
    defer allocator.free(ss_builtin_schemas);
    ai_client.setTools(ss_builtin_schemas);

    out("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    json_out.emitSessionStart(provider_name, model_name);

    var response: core.ChatResponse = undefined;
    var content_slice: []const u8 = "";
    const stream_options = core.StreamOptions{
        .show_thinking = args.show_thinking,
    };

    if (args.stream) {
        var full_content = array_list_compat.ArrayList(u8).init(allocator);
        defer full_content.deinit();

        core.setStreamingThinkingEnabled(stream_options.show_thinking);
        defer core.setStreamingThinkingEnabled(false);

        response = ai_client.sendChatStreaming(&[_]core.ChatMessage{.{
            .role = try allocator.dupe(u8, "user"),
            .content = try allocator.dupe(u8, message),
        }}, struct {
            pub fn callback(token: []const u8, done: bool) void {
                _ = done;
                if (token.len > 0) {
                    const stdout = file_compat.File.stdout().writer();
                    stdout.print("{s}", .{token}) catch {};
                }
            }
        }.callback) catch |err| blk: {
            // Phase 47: Streaming fallback — retry transient errors non-streaming
            if (isTransientError(err)) {
                const warn_style = Style{ .fg = .yellow };
                out("\n{s}⚠ Streaming failed, retrying without streaming...{s}\n", .{ warn_style.start(), warn_style.reset() });
                break :blk ai_client.sendChat(message) catch |fallback_err| {
                    printRequestError(fallback_err);
                    json_out.emitError(@errorName(fallback_err));
                    return; // Error already displayed
                };
            } else {
                printRequestError(err);
                json_out.emitError(@errorName(err));
                return; // Error already displayed
            }
        };

        out("\n", .{});
        content_slice = "";
    } else {
        response = ai_client.sendChat(message) catch |err| {
            printRequestError(err);
            json_out.emitError(@errorName(err));
            return; // Error already displayed — don't propagate to avoid stack trace
        };

        if (response.choices.len == 0) {
            error_display_mod.printError("Empty Response", "The AI returned an empty response");
            return error.EmptyResponse;
        }

        const choice = response.choices[0];
        if (choice.message.content) |c| {
            content_slice = c;
        }
    }

    // Check if AI returned tool calls — if so, execute via AgentLoop
    const ss_tool_calls = ai_client.extractToolCalls(&response) catch &.{};
    if (ss_tool_calls.len > 0) {
        // AI wants to use tools — spin up AgentLoop to execute them
        var ss_agent_loop = agent_loop_mod.AgentLoop.init(allocator);
        defer ss_agent_loop.deinit();
        var ss_loop_config = agent_loop_mod.LoopConfig.init();
        ss_loop_config.show_intermediate = true;
        ss_loop_config.max_iterations = 10;
        ss_agent_loop.setConfig(ss_loop_config);
        try tool_executors.registerBuiltinAgentTools(&ss_agent_loop, ss_builtin_schemas);

        // Build conversation history with the initial exchange
        var ss_messages = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
        defer {
            for (ss_messages.items) |msg| {
                chat_helpers.freeChatMessage(msg, allocator);
            }
            ss_messages.deinit();
        }
        try ss_messages.append(.{
            .role = try allocator.dupe(u8, "user"),
            .content = try allocator.dupe(u8, message),
        });

        // Set up bridge context for the agent loop
        var ss_hooks = lifecycle_hooks_mod.LifecycleHooks.init(allocator);
        defer ss_hooks.deinit();
        var ss_total_input: u64 = 0;
        var ss_total_output: u64 = 0;
        var ss_request_count: u32 = 0;
        var ss_request_arena = std.heap.ArenaAllocator.init(allocator);
        defer ss_request_arena.deinit();

        var ss_bridge_ctx = chat_bridge.InteractiveBridgeContext{
            .allocator = allocator,
            .client = &ai_client,
            .messages = &ss_messages,
            .hooks = &ss_hooks,
            .provider_name = provider_name,
            .model_name = model_name,
            .turn_start_len = 0,
            .synced_loop_messages = 0,
            .turn_request_count = 0,
            .turn_failed = false,
            .total_input_tokens = &ss_total_input,
            .total_output_tokens = &ss_total_output,
            .request_count = &ss_request_count,
            .request_arena = ss_request_arena,
            .json_out = json_out,
        };

        chat_bridge.active_bridge_context = &ss_bridge_ctx;
        chat_bridge.active_streaming_enabled = args.stream;
        chat_bridge.active_show_thinking = stream_options.show_thinking;
        tool_executors.setJsonOutput(json_out);

        // Add the first AI response (with tool calls) to history so AgentLoop
        // can see it and execute the tools
        try ss_messages.append(.{
            .role = try allocator.dupe(u8, "assistant"),
            .content = if (content_slice.len > 0) try allocator.dupe(u8, content_slice) else null,
            .tool_calls = blk: {
                const copied_tc = allocator.alloc(ai_types.ToolCallInfo, ss_tool_calls.len) catch break :blk null;
                for (ss_tool_calls, 0..) |tc, i| {
                    copied_tc[i] = .{
                        .id = allocator.dupe(u8, tc.id) catch "",
                        .name = allocator.dupe(u8, tc.name) catch "",
                        .arguments = allocator.dupe(u8, tc.arguments) catch "",
                    };
                }
                break :blk copied_tc;
            },
        });

        // Add assistant message + tool calls to agent loop history manually
        try ss_agent_loop.addMessage("user", message);
        if (content_slice.len > 0) {
            try ss_agent_loop.addMessage("assistant", content_slice);
        }

        // Execute the tool calls and send results back to AI
        // We need to add tool results and then call AI again
        for (ss_tool_calls) |tc| {
            const tool_call_ptr = try allocator.create(agent_loop_mod.ToolCall);
            tool_call_ptr.* = try agent_loop_mod.ToolCall.init(allocator, tc.id, tc.name, tc.arguments);
            defer {
                tool_call_ptr.deinit();
                allocator.destroy(tool_call_ptr);
            }

            if (ss_agent_loop.executeTool(tool_call_ptr)) |opt_result| {
                if (opt_result) |result| {
                    out("🔧 {s} → {s}\n", .{ tc.name, if (result.success) "OK" else "FAILED" });
                    try ss_agent_loop.addToolResult(result.call_id, tc.name, result.output);
                    try ss_messages.append(.{
                        .role = try allocator.dupe(u8, "tool"),
                        .content = try allocator.dupe(u8, result.output),
                        .tool_call_id = try allocator.dupe(u8, result.call_id),
                    });
                    // result owns its strings via allocator — they get freed when allocator frees
                } else {
                    out("🔧 {s} → not found\n", .{tc.name});
                    const err_msg = try std.fmt.allocPrint(allocator, "Tool '{s}' not found", .{tc.name});
                    try ss_agent_loop.addToolResult(tc.id, tc.name, err_msg);
                    try ss_messages.append(.{
                        .role = try allocator.dupe(u8, "tool"),
                        .content = err_msg,
                        .tool_call_id = try allocator.dupe(u8, tc.id),
                    });
                }
            } else |err| {
                out("🔧 {s} → error: {}\n", .{ tc.name, err });
                const err_msg = try std.fmt.allocPrint(allocator, "Tool execution error: {}", .{err});
                try ss_agent_loop.addToolResult(tc.id, tc.name, err_msg);
                try ss_messages.append(.{
                    .role = try allocator.dupe(u8, "tool"),
                    .content = err_msg,
                    .tool_call_id = try allocator.dupe(u8, tc.id),
                });
            }
        }

        // Now ask AI for the final response with tool results
        out("\n", .{});

        var final_response: core.ChatResponse = undefined;
        if (args.stream) {
            final_response = ai_client.sendChatStreaming(ss_messages.items, struct {
                pub fn callback(token: []const u8, done: bool) void {
                    _ = done;
                    if (token.len > 0) {
                        const stdout = file_compat.File.stdout().writer();
                        stdout.print("{s}", .{token}) catch {};
                    }
                }
            }.callback) catch |err| blk: {
                // Streaming fallback for tool-result follow-up
                if (isTransientError(err)) {
                    const warn_style = Style{ .fg = .yellow };
                    out("\n{s}⚠ Streaming failed, retrying without streaming...{s}\n", .{ warn_style.start(), warn_style.reset() });
                    break :blk ai_client.sendChatWithHistory(ss_messages.items) catch |fb_err| {
                        printRequestError(fb_err);
                        chat_bridge.active_bridge_context = null;
                        return; // Error already displayed
                    };
                } else {
                    printRequestError(err);
                    chat_bridge.active_bridge_context = null;
                    return; // Error already displayed
                }
            };
        } else {
            final_response = ai_client.sendChatWithHistory(ss_messages.items) catch |err| {
                printRequestError(err);
                chat_bridge.active_bridge_context = null;
                return; // Error already displayed
            };
        }

        if (final_response.choices.len > 0) {
            if (final_response.choices[0].message.content) |c| {
                content_slice = c;
            }
        }
        chat_bridge.active_bridge_context = null;
        chat_bridge.active_streaming_enabled = false;
        chat_bridge.active_show_thinking = false;
        tool_executors.setJsonOutput(.{ .enabled = false });
    }
    markdown_mod.MarkdownRenderer.render(content_slice);
    out("\n", .{});
    out("{s}---{s}\n", .{ Style.dimmed.start(), Style.dimmed.reset() });
    out("{s}Provider:{s} {s}  {s}Model:{s} {s}\n", .{ Style.muted.start(), Style.muted.reset(), provider_name, Style.muted.start(), Style.muted.reset(), model_name });
    if (response.usage) |usage| {
        out("{s}Tokens:{s} {d} in + {d} out = {d} total\n", .{
            Style.muted.start(), Style.muted.reset(),
            usage.prompt_tokens, usage.completion_tokens,
            usage.total_tokens,
        });
        const ext = ai_client.extractExtendedUsage(&response);
        out("{s}({d} in / {d} out){s}\n", .{ Style.dimmed.start(), ext.input_tokens, ext.output_tokens, Style.dimmed.reset() });

        json_out.emitAssistant(content_slice);
        json_out.emitUsage(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    } else {
        json_out.emitAssistant(content_slice);
    }
    json_out.emitSessionEnd();
}

fn handleInteractiveChat(args: args_mod.Args, config: *Config, allocator: std.mem.Allocator, json_out: json_output_mod.JsonOutput) !void {
    var profile_opt: ?Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    var current_provider_name = args.provider orelse
        if (profile_opt) |*p| (if (p.default_provider.len > 0) p.default_provider else config.default_provider) else config.default_provider;
    var current_model_name = args.model orelse
        if (profile_opt) |*p| (if (p.default_model.len > 0) p.default_model else config.default_model) else config.default_model;

    if (current_provider_name.len == 0) {
        out("Error: No provider configured. Set one in ~/.crushcode/config.toml\n", .{});
        return error.ProviderNotFound;
    }

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(current_provider_name) orelse {
        const err_msg = std.fmt.allocPrint(allocator, "Provider '{s}' is not registered. Run 'crushcode list' to see available providers.", .{current_provider_name}) catch "Unknown provider";
        defer allocator.free(err_msg);
        error_display_mod.printError("Provider Not Found", err_msg);
        return error.ProviderNotFound;
    };

    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(current_provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(current_provider_name) orelse "";
    }

    if (api_key.len == 0 and !provider.config.is_local) {
        const key_msg = std.fmt.allocPrint(allocator, "No API key found for provider '{s}'. Add to ~/.crushcode/config.toml or profile.", .{current_provider_name}) catch "Missing API key";
        defer allocator.free(key_msg);
        error_display_mod.printError("Missing API Key", key_msg);
        return error.MissingApiKey;
    }

    var client = try core.AIClient.init(allocator, provider, current_model_name, api_key);
    defer client.deinit();

    client.max_tokens = config.max_tokens;
    client.temperature = config.temperature;

    if (config.getProviderOverrideUrl(current_provider_name)) |override_url| {
        allocator.free(client.provider.config.base_url);
        client.provider.config.base_url = try allocator.dupe(u8, override_url);
    }

    // ── Mixture-of-Agents engine ──────────────────────────────
    const MoaCtx = struct { client_ptr: *core.AIClient, allocator: std.mem.Allocator };
    var moa_ctx = MoaCtx{ .client_ptr = &client, .allocator = allocator };
    var moa_engine = moa_mod.MoAEngine.init(allocator, moa_mod.defaultConfig());
    defer moa_engine.deinit();
    var moa_enabled = false;

    // Adapter: MoA SendFn → AIClient.sendChatWithHistory
    // Converts SimpleMessage[] to ChatMessage[] and calls the real AI client.
    const moaSendAdapter = struct {
        fn send(ctx: *anyopaque, model: []const u8, messages: []const moa_mod.SimpleMessage, temperature: f64) anyerror!moa_mod.ModelResponse {
            const mctx: *MoaCtx = @ptrCast(@alignCast(ctx));
            _ = model; // Use the client's configured provider/model

            // Convert SimpleMessage → ChatMessage
            var chat_msgs = array_list_compat.ArrayList(core.ChatMessage).init(mctx.allocator);
            defer {
                for (chat_msgs.items) |*msg| {
                    mctx.allocator.free(msg.role);
                    if (msg.content) |c| mctx.allocator.free(c);
                }
                chat_msgs.deinit();
            }
            for (messages) |msg| {
                try chat_msgs.append(.{
                    .role = try mctx.allocator.dupe(u8, msg.role),
                    .content = try mctx.allocator.dupe(u8, msg.content),
                });
            }

            // Save and override temperature (client uses f32)
            const saved_temp = mctx.client_ptr.temperature;
            mctx.client_ptr.temperature = @floatCast(temperature);
            defer mctx.client_ptr.temperature = saved_temp;

            const response = mctx.client_ptr.sendChatWithHistory(chat_msgs.items) catch {
                return error.NetworkError;
            };

            const content = if (response.choices.len > 0) blk: {
                if (response.choices[0].message.content) |c| break :blk c;
                break :blk "";
            } else "";
            const tokens: u32 = if (response.usage) |u| @intCast(u.total_tokens) else 0;
            return moa_mod.ModelResponse{ .content = content, .tokens_used = tokens };
        }
    }.send;

    var hotswap = ModelHotSwap.init(allocator, current_provider_name, current_model_name) catch null;
    defer if (hotswap) |*hs| hs.deinit();

    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) {
            client.setSystemPrompt(p.system_prompt);
        }
    } else if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    const intensity_level = Intensity.parse(args.intensity orelse "normal") orelse .normal;
    if (intensity_level != .normal) {
        const current_prompt = client.system_prompt orelse config.getSystemPrompt() orelse "";
        const modifier = intensity_level.systemPromptMod();
        const enhanced = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ current_prompt, modifier }) catch current_prompt;
        client.setSystemPrompt(enhanced);
        out("{s}[intensity: {s}]{s}\n", .{ Style.dimmed.start(), intensity_level.label(), Style.dimmed.reset() });
    }

    // Load persistent permission config from disk, or fall back to defaults
    const config_dir = env_mod.getConfigDir(allocator) catch blk: {
        break :blk "/tmp/crushcode";
    };
    defer allocator.free(config_dir);

    var perm_config = PermissionConfig.loadFromFile(allocator, config_dir) catch |err| switch (err) {
        error.FileNotFound => permission_mod.createDefaultConfig(allocator) catch {
            active_evaluator = null;
            tool_executors.setPermissionEvaluator(null);
            return;
        },
        else => permission_mod.createDefaultConfig(allocator) catch {
            active_evaluator = null;
            tool_executors.setPermissionEvaluator(null);
            return;
        },
    };

    // Override mode if CLI flag provided (--yolo, --auto, --plan, --permission)
    if (args.permission) |perm_str| {
        const mode = PermissionMode.fromString(perm_str) orelse blk: {
            out("Warning: Unknown permission mode '{s}' — using default\n", .{perm_str});
            break :blk PermissionMode.default;
        };
        perm_config.mode = mode;
        out("{s}[Permission] mode: {s}{s}\n", .{ Style.dimmed.start(), mode.toString(), Style.dimmed.reset() });
    }

    active_evaluator = PermissionEvaluator.init(allocator, perm_config);
    tool_executors.setPermissionEvaluator(if (active_evaluator) |*ev| ev else null);

    // Initialize audit logger
    var audit_logger = audit_mod.PermissionAuditLogger.init(allocator, config_dir) catch null;
    defer {
        if (audit_logger != null) {
            audit_logger.?.deinit();
        }
    }
    tool_executors.setPermissionAuditLogger(if (audit_logger) |*al| al else null);

    // Initialize shell state (cwd, env tracking) and command history
    var shell_state = shell_state_mod.ShellState.init(allocator) catch null;
    defer {
        if (shell_state != null) {
            shell_state.?.deinit();
        }
    }
    tool_executors.setShellState(if (shell_state) |*ss| ss else null);

    var shell_history = shell_history_mod.ShellHistory.init(allocator, config_dir) catch null;
    defer {
        if (shell_history != null) {
            shell_history.?.deinit();
        }
    }

    // Initialize command blocklist and safelist for security (Phase 27)
    var command_blocklist = blocklist_mod.CommandBlocklist.init(allocator);
    command_blocklist.loadFromFile(config_dir) catch {};
    defer command_blocklist.deinit();
    tool_executors.setCommandBlocklist(&command_blocklist);

    // Initialize safelist - degrade gracefully if OOM occurs
    var safe_command_list = safelist_mod.SafeCommandList.init(allocator);
    defer {
        if (safe_command_list) |*scl| scl.deinit();
    }
    if (safe_command_list) |*scl| {
        scl.loadFromFile(config_dir) catch {};
    }
    tool_executors.setSafeCommandList(if (safe_command_list) |*scl| scl else null);

    // Initialize file tracker to avoid re-reading unchanged files (Phase 32)
    var file_tracker = file_tracker_mod.FileTracker.init(allocator);
    defer file_tracker.deinit();
    tool_executors.setFileTracker(&file_tracker);

    // Initialize structured logger for JSONL logging (Phase 34)
    var structured_logger = structured_log_mod.StructuredLogger.init(allocator) catch null;
    defer {
        if (structured_logger) |*sl| sl.deinit();
    }

    defer {
        tool_executors.setPermissionEvaluator(null);
        tool_executors.setPermissionAuditLogger(null);
        tool_executors.setShellState(null);
        tool_executors.setCommandBlocklist(null);
        tool_executors.setSafeCommandList(null);
        tool_executors.setFileTracker(null);
        if (active_evaluator) |*ev| {
            // Save permissions back to disk before cleanup
            ev.config.saveToFile(allocator, config_dir) catch {};
            ev.deinit();
            active_evaluator = null;
        }
    }

    const default_tool_schemas = try tool_loader.loadDefaultToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, default_tool_schemas);

    const user_tool_schemas = try tool_loader.loadUserToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, user_tool_schemas);

    const merged_tool_schemas = try tool_loader.mergeToolSchemas(allocator, default_tool_schemas, user_tool_schemas);
    defer tool_loader.freeToolSchemas(allocator, merged_tool_schemas);

    const builtin_tool_schemas = try tool_executors.collectSupportedToolSchemas(allocator, merged_tool_schemas);
    defer allocator.free(builtin_tool_schemas);

    client.setTools(builtin_tool_schemas);

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

    var pipeline: *cognition_mod.KnowledgePipeline = undefined;
    var pipeline_initialized = false;

    // Try with memory first (project dir "."), fall back without
    pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch blk: {
        const p = cognition_mod.KnowledgePipeline.init(allocator, null) catch {
            // Fall back to a bare knowledge graph if pipeline init fails
            var kg = KnowledgeGraph.init(allocator);
            const graph_ctx_fallback = kg.toCompressedContext(allocator) catch null;
            defer {
                if (graph_ctx_fallback) |ctx| allocator.free(ctx);
                kg.deinit();
            }
            return;
        };
        break :blk p;
    };
    pipeline_initialized = true;
    defer {
        if (pipeline_initialized) pipeline.deinit();
    }

    const context_tier = LoadTier.focused;
    const max_files = context_tier.maxPages();

    // Auto-scan src/ directory, index up to max_files code files
    pipeline.scanProject("src", max_files) catch {};
    pipeline.indexGraphToVault() catch {};

    // Bridge vault nodes into layered memory
    pipeline.syncVaultToMemory() catch {};

    // Convergence detector for agent loop iteration tracking (F14)
    var convergence_detector = ConvergenceDetector.init();

    if (pipeline_initialized and pipeline.pipeline_stats.files_indexed > 0) {
        // Use smart context builder that combines tiered loading + optimization + intensity
        const user_msg = if (args.remaining.len > 0) args.remaining[0] else "";
        const smart_ctx = pipeline.buildSmartContext(user_msg, intensity_level) catch null;
        if (smart_ctx) |ctx| {
            defer allocator.free(ctx);
            const base_prompt = client.system_prompt orelse "You are a helpful AI coding assistant with access to the user's codebase.";
            const enhanced = std.fmt.allocPrint(allocator,
                \\{s}
                \\
                \\## Codebase Context (Auto-Generated)
                \\The following is auto-generated context from your local codebase.
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
            const selected_tier = tiered_loader_mod.selectTier(if (user_msg.len > 0) user_msg else "focused");
            out("{s}[pipeline: {d} files indexed, {d} graph nodes, {d} vault nodes | tier: {s}]{s}\n", .{
                Style.dimmed.start(),
                pipeline.pipeline_stats.files_indexed,
                pipeline.pipeline_stats.graph_nodes,
                pipeline.pipeline_stats.vault_nodes,
                selected_tier.label(),
                Style.dimmed.reset(),
            });
        }
    }

    var slash_registry = SlashCommandRegistry.init(allocator);
    defer slash_registry.deinit();
    try slash_registry.registerDefaults();

    var custom_command_loader = custom_commands_mod.CustomCommandLoader.init(allocator);
    defer custom_command_loader.deinit();
    custom_command_loader.loadFromDirectory("commands") catch {};

    var hooks = LifecycleHooks.init(allocator);
    defer hooks.deinit();
    try registerCoreChatHooks(&hooks);

    var guardian: ?Guardian = Guardian.init(allocator) catch null;
    defer {
        if (guardian) |*g| {
            g.notifySessionEnd();
            g.deinit();
        }
    }
    if (guardian) |*g| {
        _ = g.discoverHooks() catch 0;
    }

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.registerBuiltinTools();
    const available_tools = try tool_registry.getAvailableTools(allocator);
    defer allocator.free(available_tools);
    std.debug.assert(available_tools.len > 0);

    // Initialize agent loop using agent_setup module
    var agent_loop = try agent_setup.createAgentLoop(allocator, builtin_tool_schemas);
    defer agent_setup.destroyAgentLoop(allocator, agent_loop);

    // Phase 52: Session budget tracking — set via /cost budget <amount>
    var session_budget: ?usage_budget_mod.BudgetManager = null;

    var current_agent_mode: agent_loop_mod.AgentMode = .execute;
    agent_setup.configureAgentMode(agent_loop, current_agent_mode);
    tool_executors.setAgentMode(current_agent_mode);

    var messages = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
    defer {
        for (messages.items) |msg| {
            chat_helpers.freeChatMessage(msg, allocator);
        }
        messages.deinit();
    }

    // ── Session continuation (--continue / --session <id>) ──────────
    const session_dir = session_mod.defaultSessionDir(allocator) catch null;
    defer {
        if (session_dir) |dir| allocator.free(dir);
    }

    var current_session_id = session_mod.generateSessionId(allocator) catch "unknown";
    defer allocator.free(current_session_id);

    if (session_dir) |dir| {
        var loaded_session: ?session_mod.Session = null;

        if (args.session_id) |requested_id| {
            // Load specific session by ID
            const path = session_mod.sessionFilePath(allocator, dir, requested_id) catch null;
            if (path) |p| {
                defer allocator.free(p);
                loaded_session = session_mod.loadSession(allocator, p) catch blk: {
                    out("{s}Warning: Could not load session '{s}'{s}\n", .{ Style.warning.start(), requested_id, Style.warning.reset() });
                    break :blk null;
                };
            }
        } else if (args.continue_session) {
            // Load most recent session
            const sessions = session_mod.listSessions(allocator, dir) catch null;
            if (sessions) |all_sessions| {
                defer {
                    for (all_sessions) |*s| session_mod.deinitSession(allocator, s);
                    allocator.free(all_sessions);
                }
                if (all_sessions.len > 0) {
                    const path = session_mod.sessionFilePath(allocator, dir, all_sessions[0].id) catch null;
                    if (path) |p| {
                        defer allocator.free(p);
                        loaded_session = session_mod.loadSession(allocator, p) catch null;
                    }
                }
            }
        }

        if (loaded_session) |*session| {
            // Replace generated ID with loaded session ID
            allocator.free(current_session_id);
            current_session_id = allocator.dupe(u8, session.id) catch "unknown";

            // Copy messages into the chat
            for (session.messages) |msg| {
                const copied_msg = core.ChatMessage{
                    .role = allocator.dupe(u8, msg.role) catch continue,
                    .content = if (msg.content) |c| allocator.dupe(u8, c) catch null else null,
                    .tool_call_id = if (msg.tool_call_id) |tc| allocator.dupe(u8, tc) catch null else null,
                    .tool_calls = null, // tool_calls from previous sessions are not replayed
                };
                messages.append(copied_msg) catch continue;
            }

            out("{s}[session: continued from {s} ({d} messages loaded)]{s}\n", .{
                Style.dimmed.start(),
                session.id,
                session.messages.len,
                Style.dimmed.reset(),
            });

            session_mod.deinitSession(allocator, session);
        }
    }

    const session_start_time = std.time.milliTimestamp();

    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var request_count: u32 = 0;
    var stream_options = core.StreamOptions{
        .show_thinking = args.show_thinking,
    };

    var compactor = ContextCompactor.init(allocator, 128_000);
    defer compactor.deinit();
    compactor.setRecentWindow(10); // Keep last 10 messages at full fidelity

    var project_memory = project_memory_mod.ProjectMemory.init(allocator);
    defer project_memory.deinit();
    project_memory.load() catch {};

    // Inject CLAUDE.md memory into system prompt
    if (project_memory.hasMemory()) {
        const base_prompt = config.getSystemPrompt() orelse "";
        const injected = project_memory.injectIntoSystemPrompt(base_prompt) catch base_prompt;
        if (injected.len > 0) {
            client.system_prompt = injected;
        }
        out("{s}[memory: {d} bytes loaded]{s}\n", .{ Style.dimmed.start(), project_memory.totalSize(), Style.dimmed.reset() });
    }

    out(Style.dimmed.start() ++ "── " ++ Style.heading.start() ++ "Crushcode" ++ Style.heading.reset() ++ " " ++ Style.muted.start(), .{});
    out("{s}/{s}" ++ Style.muted.reset() ++ " ", .{
        current_provider_name,
        current_model_name,
    });
    out(Style.dimmed.start() ++ "session:" ++ Style.dimmed.reset() ++ " " ++ Style.info.start(), .{});
    out("{s}" ++ Style.info.reset() ++ " " ++ Style.dimmed.start() ++ "──" ++ Style.dimmed.reset() ++ "\n", .{
        current_session_id,
    });

    // Context budget header bar
    {
        const budget = context_budget_mod.ContextBudget.forModel(current_model_name);
        out(Style.dimmed.start() ++ "ctx: " ++ Style.dimmed.reset() ++ "░░░░░░░░ 0% (0/{d})\n", .{
            budget.max_context_tokens,
        });
    }

    if (stream_options.show_thinking) {
        out(Style.dimmed.start() ++ "thinking:" ++ Style.dimmed.reset() ++ " " ++ Style.info.start() ++ "on" ++ Style.info.reset() ++ " " ++ Style.dimmed.start() ++ "mode:" ++ Style.dimmed.reset() ++ " " ++ Style.info.start() ++ "{s}" ++ Style.info.reset() ++ " · /help /clear /model /mode /compact /cost /memory /revise /lint /sources /guardian /cognition /insights /autopilot /phase-run /team /spawn /session /sessions /cost /exit" ++ Style.dimmed.reset() ++ "\n\n", .{current_agent_mode.toString()});
    } else {
        out(Style.dimmed.start() ++ "thinking:" ++ Style.dimmed.reset() ++ " " ++ Style.muted.start() ++ "off" ++ Style.muted.reset() ++ " " ++ Style.dimmed.start() ++ "mode:" ++ Style.dimmed.reset() ++ " " ++ Style.info.start() ++ "{s}" ++ Style.info.reset() ++ " · /help /clear /model /mode /compact /cost /memory /revise /lint /sources /guardian /cognition /insights /autopilot /phase-run /team /spawn /session /sessions /cost /exit" ++ Style.dimmed.reset() ++ "\n\n", .{current_agent_mode.toString()});
    }

    json_out.emitSessionStart(current_provider_name, current_model_name);

    // Log session start
    if (structured_logger) |*sl| {
        sl.log(.info, "session started provider={s} model={s} session={s}", .{ current_provider_name, current_model_name, current_session_id });
    }

    // Guardian: fire session_start lifecycle event
    if (guardian) |*g| {
        g.notifySessionStart(current_provider_name, current_model_name);
    }

    var gate_override: bool = false;
    var last_gate_verdict: []const u8 = "none";
    const current_phase_name: []const u8 = "discuss";

    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    // Phase 55: Watch context files for changes during session
    var context_watcher = file_watcher_mod.FileWatcher.init(allocator);
    defer context_watcher.deinit();
    context_watcher.addFile("CLAUDE.md");
    context_watcher.addFile("AGENTS.md");
    context_watcher.addFile(".cursorrules");
    context_watcher.addFile(".claude/CLAUDE.md");
    context_watcher.addFile("SKILL.md");
    context_watcher.addFile("Alloy.md");

    while (true) {
        // Phase 55: Check if context files changed — rebuild system prompt
        const changed = context_watcher.poll();
        if (changed.len > 0) {
            context_watcher.freeChanged();
            // Reload project memory and rebuild prompt
            project_memory.deinit();
            project_memory = project_memory_mod.ProjectMemory.init(allocator);
            project_memory.load() catch {};
            if (project_memory.hasMemory()) {
                const base_prompt = config.getSystemPrompt() orelse "";
                const injected = project_memory.injectIntoSystemPrompt(base_prompt) catch base_prompt;
                if (injected.len > 0) {
                    client.system_prompt = injected;
                }
            }
            const cyan_style = Style{ .fg = .cyan };
            out("{s}↻ Context updated ({d} file(s) changed){s}\n", .{ cyan_style.start(), changed.len, cyan_style.reset() });
        } else {
            context_watcher.freeChanged();
        }

        out("\n{s}❯ {s}", .{ Style.prompt_user.start(), Style.prompt_user.reset() });

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

        if (std.mem.eql(u8, user_message, "/guardian")) {
            if (guardian) |*g| {
                g.printStats();
            } else {
                out("\n  Guardian not initialized (init failed)\n", .{});
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/cognition")) {
            if (!pipeline_initialized) {
                out("\n  Pipeline not initialized\n", .{});
            } else {
                const s = pipeline.stats();
                out("\n=== Cognition Pipeline ===\n", .{});
                out("  Files indexed:   {d}\n", .{s.files_indexed});
                out("  Graph nodes:     {d}\n", .{s.graph_nodes});
                out("  Graph edges:     {d}\n", .{s.graph_edges});
                out("  Communities:     {d}\n", .{s.communities});
                out("  Vault nodes:     {d}\n", .{s.vault_nodes});
                out("  Memory entries:  {d}\n", .{s.memory_entries});
                out("  Insights:        {d}\n", .{s.insights_count});
                out("  Source tokens:   {d}\n", .{s.total_source_tokens});
                if (s.files_indexed > 0 and s.graph_nodes > 0) {
                    const ratio = @as(f64, @floatFromInt(s.total_source_tokens)) / @as(f64, @floatFromInt(s.graph_nodes));
                    out("  Compression:     {d:.1}x\n", .{ratio});
                }
                out("  [context injected into system prompt]\n", .{});
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/insights")) {
            if (!pipeline_initialized) {
                out("\n  Pipeline not initialized\n", .{});
            } else {
                pipeline.printInsights();
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/autopilot") or std.mem.startsWith(u8, user_message, "/autopilot ")) {
            const auto_sub = std.mem.trim(u8, user_message["/autopilot".len..], " ");
            if (auto_sub.len == 0) {
                out("\n=== Autopilot Engine ===\n", .{});
                out("  Usage:\n", .{});
                out("    /autopilot run <agent-id>  — run a specific agent\n", .{});
                out("    /autopilot status [agent]  — show agent status\n", .{});
                out("    /autopilot schedule        — run all scheduled agents\n", .{});
                out("    /autopilot list            — list all agents\n", .{});
            } else if (std.mem.startsWith(u8, auto_sub, "run ")) {
                const agent_id = std.mem.trim(u8, auto_sub["run ".len..], " ");
                if (agent_id.len == 0) {
                    out("  Usage: /autopilot run <agent-id>\n", .{});
                    continue;
                }
                if (!pipeline_initialized) {
                    out("  Pipeline not initialized — cannot run autopilot\n", .{});
                    continue;
                }
                const guardian_ptr: ?*Guardian = if (guardian) |*g| g else null;
                var engine = autopilot_mod.AutopilotEngine.init(allocator, pipeline, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                    out("  Failed to initialize autopilot engine\n", .{});
                    continue;
                };
                defer engine.deinit();
                const result = engine.runAgentWork(agent_id) catch |err| {
                    out("  Agent '{s}' failed: {}\n", .{ agent_id, err });
                    continue;
                };
                defer result.deinit(allocator);
                out("\n  Agent: {s} ({s})\n", .{ result.agent_id, @tagName(result.agent_kind) });
                out("  Status: {s}\n", .{@tagName(result.status)});
                out("  Summary: {s}\n", .{result.work_summary});
                if (result.error_message) |msg| {
                    out("  Error: {s}\n", .{msg});
                }
                out("  Files scanned: {d} | Indexed: {d} | Vault: {d} | Graph: {d}\n", .{
                    result.files_scanned, result.files_indexed, result.vault_nodes, result.graph_nodes,
                });
            } else if (std.mem.startsWith(u8, auto_sub, "status")) {
                const status_arg = std.mem.trim(u8, auto_sub["status".len..], " ");
                if (!pipeline_initialized) {
                    out("  Pipeline not initialized\n", .{});
                    continue;
                }
                const guardian_ptr: ?*Guardian = if (guardian) |*g| g else null;
                var engine = autopilot_mod.AutopilotEngine.init(allocator, pipeline, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                    out("  Failed to initialize autopilot engine\n", .{});
                    continue;
                };
                defer engine.deinit();
                if (status_arg.len > 0) {
                    const status_text = engine.getAgentStatus(status_arg);
                    if (status_text) |text| {
                        out("\n  {s}\n", .{text});
                        allocator.free(text);
                    } else {
                        out("  Agent '{s}' not found\n", .{status_arg});
                    }
                } else {
                    engine.printStats();
                }
            } else if (std.mem.eql(u8, auto_sub, "schedule")) {
                if (!pipeline_initialized) {
                    out("  Pipeline not initialized — cannot run schedule\n", .{});
                    continue;
                }
                const guardian_ptr: ?*Guardian = if (guardian) |*g| g else null;
                var engine = autopilot_mod.AutopilotEngine.init(allocator, pipeline, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                    out("  Failed to initialize autopilot engine\n", .{});
                    continue;
                };
                defer engine.deinit();
                out("\n  Running scheduled agents...\n", .{});
                engine.runScheduledWork() catch {};
                engine.printStats();
            } else if (std.mem.eql(u8, auto_sub, "list")) {
                if (!pipeline_initialized) {
                    out("  Pipeline not initialized\n", .{});
                    continue;
                }
                const guardian_ptr: ?*Guardian = if (guardian) |*g| g else null;
                var engine = autopilot_mod.AutopilotEngine.init(allocator, pipeline, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                    out("  Failed to initialize autopilot engine\n", .{});
                    continue;
                };
                defer engine.deinit();
                const listing = engine.listAgents(allocator) catch "  (failed to list agents)";
                defer allocator.free(listing);
                out("\n{s}\n", .{listing});
            } else {
                out("  Unknown autopilot subcommand: {s}\n", .{auto_sub});
                out("  Use: run, status, schedule, list\n", .{});
            }
            continue;
        }

        // ── /team — show orchestration engine stats ─────────────────────────
        if (std.mem.eql(u8, user_message, "/team")) {
            var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
                out("\n  Error: failed to initialize orchestration engine\n", .{});
                continue;
            };
            defer engine.deinit();
            engine.printStats();
            continue;
        }

        // ── /spawn <description> — spawn a 3-agent team and show the plan ────
        if (std.mem.startsWith(u8, user_message, "/spawn ")) {
            const spawn_desc = std.mem.trim(u8, user_message["/spawn ".len..], " ");
            if (spawn_desc.len == 0) {
                out("  Usage: /spawn <task description>\n", .{});
                continue;
            }
            var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
                out("  Error: failed to initialize orchestration engine\n", .{});
                continue;
            };
            defer engine.deinit();
            const result = engine.spawnTeam(spawn_desc, 3) catch {
                out("  Error: failed to spawn team\n", .{});
                continue;
            };
            defer result.deinit(allocator);
            out("\n=== Team Spawned ===\n", .{});
            out("  Team:   {s} ({s})\n", .{ result.team_name, result.team_id });
            out("  Agents: {d}\n", .{result.agent_count});
            out("  Cost:   ${d:.4}\n", .{result.total_estimated_cost});
            out("\n  Phases ({d}):\n", .{result.plan.total_phases});
            for (result.plan.phases, 0..) |phase, idx| {
                out("    {d}. {s} — {s} [{s}]\n", .{
                    idx + 1,
                    phase.phase_name,
                    phase.phase_description,
                    phase.recommended_model,
                });
            }
            out("\n  Agents:\n", .{});
            for (result.agents, 0..) |agent, idx| {
                out("    {d}. {s} [{s}] → {s}\n", .{ idx + 1, agent.agent_name, @tagName(agent.specialty), agent.model });
            }
            out("\n", .{});
            continue;
        }

        // ── /cost <description> — show cost estimate for a task ──────────────
        if (std.mem.startsWith(u8, user_message, "/cost ")) {
            const cost_desc = std.mem.trim(u8, user_message["/cost ".len..], " ");
            if (cost_desc.len == 0) {
                out("  Usage: /cost <task description>\n", .{});
                continue;
            }
            var engine = orchestration_mod.OrchestrationEngine.init(allocator) catch {
                out("  Error: failed to initialize orchestration engine\n", .{});
                continue;
            };
            defer engine.deinit();
            const estimate = engine.estimateCost(cost_desc) catch {
                out("  Error: failed to estimate cost\n", .{});
                continue;
            };
            defer estimate.deinit(allocator);
            out("\n=== Cost Estimate ===\n", .{});
            out("  Task:     {s}\n", .{cost_desc});
            out("  Category: {s}\n", .{@tagName(estimate.task_category)});
            out("  Model:    {s}\n", .{estimate.recommended_model});
            out("  Tokens:   {d}\n", .{estimate.estimated_tokens});
            out("  Cost:     ${d:.4}\n", .{estimate.estimated_cost});
            out("\n", .{});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/phase-run") or std.mem.startsWith(u8, user_message, "/phase-run ")) {
            const phase_arg = std.mem.trim(u8, user_message["/phase-run".len..], " ");
            if (phase_arg.len == 0) {
                out("\n=== Phase Runner ===\n", .{});
                out("  Usage:\n", .{});
                out("    /phase-run <name>  — run a simple 2-phase workflow\n", .{});
                out("    /phase-run status  — show phase runner info\n", .{});
            } else if (std.mem.eql(u8, phase_arg, "status")) {
                out("\n=== Phase Runner Status ===\n", .{});
                out("  Pipeline: {s}\n", .{if (pipeline_initialized) "initialized" else "not initialized"});
                out("  Guardian: {s}\n", .{if (guardian != null) "active" else "disabled"});
            } else {
                var runner = phase_runner_mod.PhaseRunner.init(allocator, .{
                    .name = phase_arg,
                    .use_adversarial_gates = false,
                    .verbose = false,
                }) catch {
                    out("  Failed to initialize phase runner\n", .{});
                    continue;
                };
                defer runner.deinit();

                const discuss_tasks = [_][]const u8{ "Gather requirements", "Clarify scope" };
                runner.addPhase(1, "discuss", "Gather requirements and clarify scope for the user goal objective", &discuss_tasks) catch {
                    out("  Failed to add discuss phase\n", .{});
                    continue;
                };
                const plan_tasks = [_][]const u8{ "Create implementation plan", "Define tasks and steps to build" };
                runner.addPhase(2, "plan", "Create implementation plan with tasks steps build create write add fix update", &plan_tasks) catch {
                    out("  Failed to add plan phase\n", .{});
                    continue;
                };

                var result = runner.run() catch {
                    out("  Phase run failed\n", .{});
                    continue;
                };
                defer result.deinit();
                phase_runner_mod.printResult(&result);
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/memory")) {
            out("\n=== Project Memory ===\n", .{});
            if (project_memory.user_path.len > 0) {
                out("  User: {s} ({d} bytes)\n", .{ project_memory.user_path, project_memory.user_memory.len });
            }
            if (project_memory.project_path.len > 0) {
                out("  Project: {s} ({d} bytes)\n", .{ project_memory.project_path, project_memory.project_memory.len });
            }
            out("  Total: {d} bytes\n", .{project_memory.totalSize()});
            out("  Status: {s}\n", .{if (project_memory.hasMemory()) "loaded" else "empty"});
            continue;
        }

        if (std.mem.startsWith(u8, user_message, "/memory ")) {
            const sub = user_message["/memory ".len..];
            if (std.mem.eql(u8, sub, "reload")) {
                project_memory.reload() catch {};
                out("Memory reloaded ({d} bytes)\n", .{project_memory.totalSize()});
                continue;
            }
            if (std.mem.eql(u8, sub, "clear")) {
                project_memory.clear();
                out("Memory cleared for this session\n", .{});
                continue;
            }
            out("Usage: /memory [reload|clear]\n", .{});
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
                        chat_helpers.freeChatMessage(msg, allocator);
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
            out("  Files indexed: {d}\n", .{pipeline.pipeline_stats.files_indexed});
            out("  Nodes: {d}\n", .{pipeline.kg.nodes.count()});
            out("  Edges: {d}\n", .{pipeline.kg.edges.items.len});
            out("  Communities: {d}\n", .{pipeline.kg.communities.items.len});
            out("  Vault nodes: {d}\n", .{pipeline.vault.count()});
            if (pipeline.kg.compressionRatio() > 0) {
                out("  Compression: {d:.1}x\n", .{pipeline.kg.compressionRatio()});
            }
            out("  [graph context already injected into system prompt]\n", .{});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/worktree")) {
            out("\n=== Git Worktrees ===\n", .{});
            const shell_mod = @import("shell");
            _ = shell_mod.executeShellCommand("git worktree list", null) catch {
                out("  Unable to list worktrees (not in a git repo?)\n", .{});
            };
            continue;
        }

        if (std.mem.eql(u8, user_message, "/wave")) {
            out("\n=== Wave Execution ===\n", .{});
            out("  Use --wave flag with agent commands for wave-based execution\n", .{});
            out("  Tasks with dependencies execute in correct order\n", .{});
            out("  Each completed task creates an atomic commit\n", .{});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/thinking")) {
            stream_options.show_thinking = !stream_options.show_thinking;
            out("Thinking: {s}\n", .{if (stream_options.show_thinking) "on" else "off"});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/mode") or std.mem.startsWith(u8, user_message, "/mode ")) {
            const mode_arg = std.mem.trim(u8, user_message["/mode".len..], " ");
            if (mode_arg.len == 0) {
                const loop_config = agent_setup.getLoopConfig(agent_loop);
                const mc = loop_config.activeModeConfig();
                const eff_iter = loop_config.effectiveMaxIterations();
                out("Current mode: {s} — {s}\n", .{ current_agent_mode.toString(), current_agent_mode.description() });
                if (mc.model) |m| {
                    out("  max_steps={d}  temperature={d:.1}  model={s}\n", .{ eff_iter, mc.temperature, m });
                } else {
                    out("  max_steps={d}  temperature={d:.1}  model=default\n", .{ eff_iter, mc.temperature });
                }
            } else {
                const new_mode = agent_loop_mod.AgentMode.fromString(mode_arg) orelse {
                    out("{s}Unknown mode '{s}'. Available: plan, build, execute{s}\n", .{ Style.err.start(), mode_arg, Style.err.reset() });
                    continue;
                };
                current_agent_mode = new_mode;
                agent_setup.configureAgentMode(agent_loop, new_mode);
                tool_executors.setAgentMode(new_mode);
                out("Switched to {s} — {s}\n", .{ new_mode.toString(), new_mode.description() });
            }
            continue;
        }

        // ── /moa — Toggle Mixture-of-Agents ────────────────────
        if (std.mem.eql(u8, user_message, "/moa") or std.mem.startsWith(u8, user_message, "/moa ")) {
            const moa_arg = std.mem.trim(u8, user_message["/moa".len..], " ");
            if (moa_arg.len == 0) {
                out("MoA: {s}  (queries={d}, syntheses={d})\n", .{
                    if (moa_enabled) "enabled" else "disabled",
                    moa_engine.total_queries,
                    moa_engine.total_syntheses,
                });
            } else if (std.mem.eql(u8, moa_arg, "on")) {
                moa_enabled = true;
                moa_engine.setEnabled(true);
                out("MoA enabled — queries will use multiple models\n", .{});
            } else if (std.mem.eql(u8, moa_arg, "off")) {
                moa_enabled = false;
                moa_engine.setEnabled(false);
                out("MoA disabled\n", .{});
            } else {
                out("{s}Usage: /moa [on|off]{s}\n", .{ Style.warning.start(), Style.warning.reset() });
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/commands")) {
            out("\n=== Custom Commands ===\n", .{});
            if (custom_command_loader.commands.items.len == 0) {
                out("  No custom commands loaded from ./commands\n", .{});
            } else {
                for (custom_command_loader.commands.items) |cmd| {
                    out("  /{s}", .{cmd.name});
                    if (cmd.arg_names.len > 0) {
                        out(" ", .{});
                        for (cmd.arg_names, 0..) |arg_name, i| {
                            if (i > 0) out(" ", .{});
                            out("<{s}>", .{arg_name});
                        }
                    }
                    if (cmd.description.len > 0) {
                        out(" - {s}", .{cmd.description});
                    }
                    out("\n", .{});
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/revise")) {
            const assistant_index = findLastAssistantMessageIndex(messages.items) orelse {
                out("{s}No response to revise{s}\n", .{ Style.warning.start(), Style.warning.reset() });
                continue;
            };

            const last_response = messages.items[assistant_index].content orelse {
                out("{s}No response to revise{s}\n", .{ Style.warning.start(), Style.warning.reset() });
                continue;
            };

            const revision_config = revision_loop_mod.RevisionConfig{};

            var current_output = allocator.dupe(u8, last_response) catch |err| {
                out("{s}Revision setup failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                continue;
            };
            defer allocator.free(current_output);

            var total_revisions: u32 = 1;
            var final_change_ratio: f64 = 1.0;
            var outcome: ?revision_loop_mod.RevisionOutcome = null;
            var zero_change_rounds: u32 = 0;
            var revise_failed = false;
            while (outcome == null and total_revisions < revision_config.max_revisions) {
                const prompt = std.fmt.allocPrint(allocator,
                    \\Revise the following assistant response. Improve clarity, accuracy, completeness, and concision without changing its intent. Preserve useful formatting. Return only the revised response.
                    \\
                    \\{s}
                , .{current_output}) catch |err| {
                    out("{s}Revision prompt failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    revise_failed = true;
                    break;
                };
                defer allocator.free(prompt);

                const response = client.sendChat(prompt) catch |err| {
                    out("{s}Revision request failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    revise_failed = true;
                    break;
                };

                if (response.choices.len == 0) {
                    out("{s}Revision request returned no choices{s}\n", .{ Style.err.start(), Style.err.reset() });
                    revise_failed = true;
                    break;
                }

                const revised_content = response.choices[0].message.content orelse "";
                if (revised_content.len == 0) {
                    out("{s}Revision request returned empty content{s}\n", .{ Style.err.start(), Style.err.reset() });
                    revise_failed = true;
                    break;
                }

                const next_output = allocator.dupe(u8, revised_content) catch |err| {
                    out("{s}Revision output copy failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    revise_failed = true;
                    break;
                };
                const previous_output = current_output;
                final_change_ratio = computeRevisionChangeRatio(previous_output, next_output);
                allocator.free(current_output);
                current_output = next_output;

                total_revisions += 1;
                if (final_change_ratio == 0.0) {
                    zero_change_rounds += 1;
                } else {
                    zero_change_rounds = 0;
                }

                if (zero_change_rounds >= revision_config.stall_rounds) {
                    outcome = .stalled;
                } else if (final_change_ratio < revision_config.convergence_threshold) {
                    outcome = .converged;
                }

                if (response.usage) |usage| {
                    total_input_tokens += usage.prompt_tokens;
                    total_output_tokens += usage.completion_tokens;
                }
                request_count += 1;
            }

            if (!revise_failed and outcome == null and total_revisions >= revision_config.max_revisions) {
                outcome = .max_revisions;
            }

            const best_output = current_output;
            if (messages.items[assistant_index].content) |content| {
                allocator.free(content);
            }
            messages.items[assistant_index].content = allocator.dupe(u8, best_output) catch |err| {
                out("{s}Failed to store revised response: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                continue;
            };

            out("\n{s}Assistant (revised):{s} ", .{ Style.prompt_assistant.start(), Style.prompt_assistant.reset() });
            markdown_mod.MarkdownRenderer.render(best_output);
            out("\n", .{});

            if (revise_failed and outcome == null) {
                out("{s}[revise: interrupted after {d} passes | final change: {d:.3}]{s}\n", .{
                    Style.warning.start(),
                    total_revisions,
                    final_change_ratio,
                    Style.warning.reset(),
                });
            } else if (outcome) |final_outcome| {
                out("{s}[revise: {d} passes | outcome: {s} | final change: {d:.3}]{s}\n", .{
                    Style.dimmed.start(),
                    total_revisions,
                    revisionOutcomeLabel(final_outcome),
                    final_change_ratio,
                    Style.dimmed.reset(),
                });
            } else {
                out("{s}[revise: {d} passes]{s}\n", .{ Style.dimmed.start(), total_revisions, Style.dimmed.reset() });
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/lint")) {
            if (messages.items.len == 0) {
                out("{s}Not available in this context{s}\n", .{ Style.warning.start(), Style.warning.reset() });
                continue;
            }

            var findings = array_list_compat.ArrayList(SessionLintFinding).init(allocator);
            defer {
                for (findings.items) |*finding| {
                    finding.deinit(allocator);
                }
                findings.deinit();
            }

            for (messages.items, 0..) |msg, i| {
                const content = msg.content orelse "";
                const location = std.fmt.allocPrint(allocator, "msg_{d}", .{i + 1}) catch |err| {
                    out("{s}Knowledge lint setup failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    findings.clearRetainingCapacity();
                    continue;
                };

                if (i + 1 == messages.items.len) {
                    findings.append(.{
                        .severity = .info,
                        .rule = .orphan,
                        .message = "Latest session entry is not referenced by a later turn",
                        .location = location,
                        .suggestion = null,
                    }) catch {
                        allocator.free(location);
                    };
                } else if (std.mem.eql(u8, msg.role, "assistant")) {
                    allocator.free(location);
                } else {
                    allocator.free(location);
                }

                if (std.mem.eql(u8, msg.role, "assistant") and content.len > 0) {
                    const unattributed_location = std.fmt.allocPrint(allocator, "msg_{d}", .{i + 1}) catch continue;
                    findings.append(.{
                        .severity = .warning,
                        .rule = .unattributed,
                        .message = "Assistant response lacks explicit source citations in session history",
                        .location = unattributed_location,
                        .suggestion = allocator.dupe(u8, "/sources") catch null,
                    }) catch {
                        allocator.free(unattributed_location);
                    };
                }

                if (i > 0) {
                    const prev_content = messages.items[i - 1].content orelse "";
                    if (content.len > 0 and std.mem.eql(u8, content, prev_content)) {
                        const duplicate_location = std.fmt.allocPrint(allocator, "msg_{d}", .{i + 1}) catch continue;
                        findings.append(.{
                            .severity = .info,
                            .rule = .duplicate,
                            .message = "Session entry duplicates the previous turn verbatim",
                            .location = duplicate_location,
                            .suggestion = null,
                        }) catch {
                            allocator.free(duplicate_location);
                        };
                    }
                }
            }

            var critical: u32 = 0;
            var warnings: u32 = 0;
            for (findings.items) |finding| {
                switch (finding.severity) {
                    .critical => critical += 1,
                    .warning => warnings += 1,
                    .info => {},
                }
            }
            const total_checked: u32 = @intCast(messages.items.len);
            const pass_rate = if (total_checked > 0)
                @max(0.0, (@as(f64, @floatFromInt(total_checked)) - @as(f64, @floatFromInt(critical)) * 2.0 - @as(f64, @floatFromInt(warnings)) * 0.5) / @as(f64, @floatFromInt(total_checked)) * 100.0)
            else
                100.0;

            out("\n=== Knowledge Lint ===\n", .{});
            out("  Checked: {d} | Findings: {d} | Pass rate: {d:.1}%\n", .{
                total_checked,
                findings.items.len,
                pass_rate,
            });

            if (findings.items.len == 0) {
                out("  {s}No issues found{s}\n", .{ Style.success.start(), Style.success.reset() });
                continue;
            }

            for (findings.items) |finding| {
                const style = switch (finding.severity) {
                    .critical => Style.err,
                    .warning => Style.warning,
                    .info => Style.dimmed,
                };
                out("  {s}[{s}/{s}]{s} {s}", .{
                    style.start(),
                    @tagName(finding.severity),
                    @tagName(finding.rule),
                    style.reset(),
                    finding.message,
                });
                if (finding.location) |location| {
                    out(" ({s})", .{location});
                }
                out("\n", .{});
                if (finding.suggestion) |suggestion| {
                    out("    suggestion: {s}\n", .{suggestion});
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/gate") or std.mem.startsWith(u8, user_message, "/gate ")) {
            const gate_arg = std.mem.trim(u8, user_message["/gate".len..], " ");
            if (std.mem.eql(u8, gate_arg, "override")) {
                gate_override = true;
                out("Gate override — proceeding to next phase\n", .{});
            } else if (std.mem.eql(u8, gate_arg, "reset")) {
                gate_override = false;
                last_gate_verdict = "none";
                out("Gate status reset\n", .{});
            } else {
                out("\n=== Phase Gate Status ===\n", .{});
                out("  Current phase: {s}\n", .{current_phase_name});
                out("  Gate status: {s}\n", .{last_gate_verdict});
                out("  Override: {s}\n", .{if (gate_override) "active (gates bypassed)" else "inactive"});
                out("\n  Commands:\n", .{});
                out("    /gate override — bypass blocked gates\n", .{});
                out("    /gate reset    — reset gate status\n", .{});
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/sources")) {
            if (messages.items.len == 0) {
                out("{s}Not available in this context{s}\n", .{ Style.warning.start(), Style.warning.reset() });
                continue;
            }

            var tracker = source_tracker_mod.SourceTracker.init(allocator);
            defer tracker.deinit();

            for (messages.items, 0..) |msg, i| {
                const content = msg.content orelse "";
                var provenance = source_tracker_mod.SourceProvenance.init(
                    allocator,
                    sourceTypeForRole(msg.role),
                    if (std.mem.eql(u8, msg.role, "assistant")) current_model_name else if (std.mem.eql(u8, msg.role, "user")) "interactive-session" else msg.role,
                ) catch |err| {
                    out("{s}Source tracking failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    continue;
                };
                _ = provenance.withConfidence(if (std.mem.eql(u8, msg.role, "assistant")) 0.85 else 1.0);

                const id = std.fmt.allocPrint(allocator, "msg_{d}", .{i + 1}) catch |err| {
                    provenance.deinit();
                    out("{s}Source tracking failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    continue;
                };
                defer allocator.free(id);

                tracker.record(id, content, provenance) catch |err| {
                    provenance.deinit();
                    out("{s}Source tracking failed: {}{s}\n", .{ Style.err.start(), err, Style.err.reset() });
                    continue;
                };
            }

            const report = tracker.provenanceReport();
            out("\n=== Source Tracking ===\n", .{});
            out("  Total entries: {d}\n", .{report.total_entries});
            out("  Sources: user={d} ai={d} tool={d} file={d} web={d} wiki={d} derived={d}\n", .{
                report.user_sources,
                report.ai_sources,
                report.tool_sources,
                report.file_sources,
                report.web_sources,
                report.wiki_sources,
                report.derived_sources,
            });
            out("  Average confidence: {d:.2}\n", .{report.avg_confidence});

            for (tracker.entries.items) |entry| {
                out("  - {s} [{s}] origin={s} confidence={d:.2}\n", .{
                    entry.id,
                    sourceTypeLabel(entry.provenance.source_type),
                    entry.provenance.origin,
                    entry.provenance.confidence,
                });
            }
            continue;
        }

        const is_model_cmd = std.mem.eql(u8, user_message, "/model") or std.mem.startsWith(u8, user_message, "/model ") or
            std.mem.eql(u8, user_message, "/m") or std.mem.startsWith(u8, user_message, "/m ");
        if (is_model_cmd) {
            const prefix_len: usize = if (std.mem.startsWith(u8, user_message, "/model")) "/model".len else "/m".len;
            const model_arg = std.mem.trim(u8, user_message[prefix_len..], " ");
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
            chat_helpers.printInteractiveSessionSummary(messages.items, allocator, total_input_tokens, total_output_tokens);
            out("Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, user_message, "/usage")) {
            out("\n=== Session Usage ===\n", .{});
            out("  Requests: {d}\n", .{request_count});
            out("  Tokens: {d} in / {d} out\n", .{ total_input_tokens, total_output_tokens });

            // Show cost if pricing available
            var pricing = usage_pricing_mod.PricingTable.init(allocator) catch null;
            if (pricing) |*pt| {
                defer pt.deinit();
                const cost = pt.estimateCostSimple(current_provider_name, current_model_name, @as(u32, @intCast(total_input_tokens)), @as(u32, @intCast(total_output_tokens)));
                if (cost > 0) {
                    out("  Estimated cost: ${d:.4}\n", .{cost});
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/cost")) {
            out("\n=== Session Cost ===\n", .{});
            out("  Turns: {d}\n", .{request_count});
            out("  Tokens: {d} in / {d} out\n", .{ total_input_tokens, total_output_tokens });

            var pricing = usage_pricing_mod.PricingTable.init(allocator) catch {
                out("  Cost: unable to calculate (pricing unavailable)\n", .{});
                continue;
            };
            defer pricing.deinit();

            const cost = pricing.estimateCostSimple(current_provider_name, current_model_name, @as(u32, @intCast(total_input_tokens)), @as(u32, @intCast(total_output_tokens)));
            out("  Cost: ${d:.4}\n", .{cost});
            out("  Model: {s}/{s}\n", .{ current_provider_name, current_model_name });

            // Phase 52: Show budget status if set
            if (session_budget) |*bm| {
                const status = bm.checkBudget();
                out("  Budget: ${d:.2} / ${d:.2} ({d:.0}%%)\n", .{
                    status.session_spent,
                    status.session_limit,
                    if (status.session_limit > 0) status.session_spent / status.session_limit * 100 else 0,
                });
                if (status.isOverBudget()) {
                    out("  ⚠ BUDGET EXCEEDED\n", .{});
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, user_message, "/cost budget ")) {
            const amount_str = user_message["/cost budget ".len..];
            const amount = std.fmt.parseFloat(f64, amount_str) catch {
                out("Usage: /cost budget <amount_usd>\n", .{});
                continue;
            };
            session_budget = usage_budget_mod.BudgetManager.init(allocator, .{
                .per_session_limit_usd = amount,
                .alert_threshold_pct = 0.8,
            });
            agent_loop.budget_manager = session_budget;
            out("Session budget set to ${d:.2} (warns at 80%%)\n", .{amount});
            continue;
        }

        // ── /session — show current session info ────────────────────────
        if (std.mem.eql(u8, user_message, "/session")) {
            out("\n=== Current Session ===\n", .{});
            out("  ID:       {s}\n", .{current_session_id});
            out("  Model:    {s}/{s}\n", .{ current_provider_name, current_model_name });
            out("  Turns:    {d}\n", .{request_count});
            out("  Messages: {d}\n", .{messages.items.len});
            out("  Tokens:   {d} in + {d} out = {d} total\n", .{
                total_input_tokens,
                total_output_tokens,
                total_input_tokens + total_output_tokens,
            });
            var pricing = usage_pricing_mod.PricingTable.init(allocator) catch null;
            if (pricing) |*pt| {
                defer pt.deinit();
                const cost = pt.estimateCostSimple(current_provider_name, current_model_name, @as(u32, @intCast(total_input_tokens)), @as(u32, @intCast(total_output_tokens)));
                if (cost > 0) {
                    out("  Cost:     ${d:.4}\n", .{cost});
                }
            }
            const elapsed_ms = std.time.milliTimestamp() - session_start_time;
            const elapsed_s: u32 = if (elapsed_ms >= 0) @intCast(@divTrunc(elapsed_ms, 1000)) else 0;
            out("  Duration: {d}s\n", .{elapsed_s});
            continue;
        }

        // ── /sessions — list all saved sessions ──────────────────────────
        if (std.mem.eql(u8, user_message, "/sessions")) {
            if (session_dir) |dir| {
                const all_sessions = session_mod.listSessions(allocator, dir) catch {
                    out("  Error listing sessions\n", .{});
                    continue;
                };
                defer {
                    for (all_sessions) |*s| session_mod.deinitSession(allocator, s);
                    allocator.free(all_sessions);
                }
                if (all_sessions.len == 0) {
                    out("  No saved sessions.\n", .{});
                } else {
                    out("\n  Saved Sessions ({d}):\n\n", .{all_sessions.len});
                    for (all_sessions, 0..) |session, i| {
                        const short_id = if (session.id.len > 30) session.id[0..30] else session.id;
                        out("  {d}. {s}  ({d} msgs, {d} turns, {d} tokens)\n", .{
                            i + 1,
                            short_id,
                            session.messages.len,
                            session.turn_count,
                            session.total_tokens,
                        });
                    }
                    out("\n  Resume with: crushcode --session <id>\n\n", .{});
                }
            } else {
                out("  Session directory not available.\n", .{});
            }
            continue;
        }

        if (SlashCommandRegistry.isSlashCommand(user_message)) {
            const maybe_result = slash_registry.execute(user_message) catch |err| {
                out("Command error: {}\n", .{err});
                continue;
            };

            if (maybe_result) |result_value| {
                var result = result_value;
                defer result.deinit();

                if (result.should_exit) {
                    chat_helpers.printInteractiveSessionSummary(messages.items, allocator, total_input_tokens, total_output_tokens);
                    out("Goodbye!\n", .{});
                    break;
                }

                out("{s}\n", .{result.output});
                if (result.should_clear) {
                    chat_helpers.clearInteractiveHistory(&messages, allocator, &total_input_tokens, &total_output_tokens, &request_count);
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

        // ── MoA path: when enabled, route through Mixture-of-Agents ──
        if (moa_enabled) {
            var moa_result_owned: ?moa_mod.MoAResult = moa_engine.querySimple(user_message, moaSendAdapter, &moa_ctx) catch |err| blk: {
                out("{s}MoA query failed: {s}. Falling back to single model.{s}\n", .{ Style.warning.start(), @errorName(err), Style.warning.reset() });
                break :blk null;
            };
            if (moa_result_owned) |*result| {
                defer result.deinit(allocator);
                out("\n{s}--- MoA Synthesized Response ({d} models, {d}ms) ---{s}\n", .{
                    Style.dimmed.start(),
                    result.successful_references,
                    result.total_duration_ms,
                    Style.dimmed.reset(),
                });
                markdown_mod.MarkdownRenderer.render(result.synthesized_response);
                out("\n", .{});
                // Show reference model details
                for (result.reference_results) |ref| {
                    if (ref.success) {
                        out("{s}  ✓ {s}{s} ({d}ms, {d} tokens)\n", .{
                            Style.muted.start(),
                            ref.model_name,
                            Style.muted.reset(),
                            ref.duration_ms,
                            ref.tokens_used,
                        });
                    } else {
                        out("{s}  ✗ {s}: {s}{s}\n", .{
                            Style.err.start(),
                            ref.model_name,
                            ref.error_message orelse "unknown error",
                            Style.err.reset(),
                        });
                    }
                }
                continue;
            }
        }

        var bridge_ctx = chat_bridge.InteractiveBridgeContext{
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

        chat_bridge.active_bridge_context = &bridge_ctx;
        tool_executors.setJsonOutput(json_out);
        chat_bridge.active_streaming_enabled = args.stream;
        chat_bridge.active_show_thinking = stream_options.show_thinking;

        // ── Auto-compaction check before API call ──────────────────
        {
            var estimated_tokens: u64 = 0;
            for (messages.items) |msg| {
                if (msg.content) |content| {
                    estimated_tokens += ContextCompactor.estimateTokens(content);
                }
            }
            const budget = context_budget_mod.ContextBudget.forModel(current_model_name);
            if (budget.needsCompaction(estimated_tokens) and messages.items.len > 12) {
                out("{s}[auto-compacting: {d:.0}% context used]{s}\n", .{
                    Style.warning.start(),
                    budget.usagePercent(estimated_tokens) * 100.0,
                    Style.warning.reset(),
                });

                doAutoCompact: {
                    var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch break :doAutoCompact;
                    defer compact_msgs.deinit();
                    for (messages.items) |msg| {
                        compact_msgs.appendAssumeCapacity(.{
                            .role = msg.role,
                            .content = msg.content orelse "",
                            .timestamp = null,
                        });
                    }
                    const result = compactor.compact(compact_msgs.items) catch break :doAutoCompact;
                    if (result.messages_summarized > 0) {
                        for (messages.items) |msg| {
                            chat_helpers.freeChatMessage(msg, allocator);
                        }
                        messages.clearRetainingCapacity();
                        const summary_content = std.fmt.allocPrint(allocator, "{s}", .{result.summary}) catch break :doAutoCompact;
                        messages.append(.{
                            .role = allocator.dupe(u8, "system") catch break :doAutoCompact,
                            .content = summary_content,
                            .tool_call_id = null,
                            .tool_calls = null,
                        }) catch break :doAutoCompact;
                        for (result.messages) |compact_msg| {
                            messages.append(.{
                                .role = allocator.dupe(u8, compact_msg.role) catch break :doAutoCompact,
                                .content = if (compact_msg.content.len > 0) allocator.dupe(u8, compact_msg.content) catch break :doAutoCompact else null,
                                .tool_call_id = null,
                                .tool_calls = null,
                            }) catch break :doAutoCompact;
                        }
                        allocator.free(result.summary);
                        out("  Compacted {d} messages, saved ~{d} tokens.\n", .{
                            result.messages_summarized,
                            result.tokens_saved,
                        });
                    }
                }
            }
        }

        var loop_result = try agent_loop.run(chat_bridge.sendInteractiveLoopMessages, user_message);
        chat_bridge.active_bridge_context = null;
        tool_executors.setJsonOutput(.{ .enabled = false });
        chat_bridge.active_streaming_enabled = false;
        chat_bridge.active_show_thinking = false;
        defer loop_result.deinit();

        const loop_config = agent_setup.getLoopConfig(agent_loop);
        const hit_max_iterations = loop_result.steps.items.len > 0 and
            loop_result.total_iterations >= loop_config.max_iterations and
            loop_result.steps.items[loop_result.steps.items.len - 1].has_tool_calls;

        if (bridge_ctx.turn_failed) {
            chat_helpers.rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

        if (hit_max_iterations) {
            out("\nError: Agent loop hit max iterations ({d})\n", .{loop_config.max_iterations});
            chat_helpers.rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

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

        const session_tokens = total_input_tokens + total_output_tokens;
        const tier = compactor.compactionTier(session_tokens);
        if (tier != .none and messages.items.len > 12) {
            out("\n{s}⚡ Context approaching limit ({d} tokens). Compacting...{s}\n", .{ Style.warning.start(), session_tokens, Style.warning.reset() });

            var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch continue;
            defer compact_msgs.deinit();
            for (messages.items) |msg| {
                compact_msgs.appendAssumeCapacity(.{
                    .role = msg.role,
                    .content = msg.content orelse "",
                    .timestamp = null,
                });
            }

            switch (tier) {
                .light => {
                    var result = compactor.compactLight(compact_msgs.items) catch continue;
                    defer result.deinit();

                    if (result.tokens_saved > 0) {
                        replaceMessagesFromCompaction(allocator, &messages, null, result.messages) catch continue;
                        out("{s}  Light compaction truncated tool output. Saved ~{d} tokens.{s}\n", .{
                            Style.warning.start(),
                            result.tokens_saved,
                            Style.warning.reset(),
                        });
                    }
                },
                .heavy => {
                    var result = (if (compactor.previous_summary.len > 0)
                        compactor.compactWithSummary(compact_msgs.items, compactor.previous_summary)
                    else
                        compactor.compact(compact_msgs.items)) catch continue;
                    defer result.deinit();

                    if (result.messages_summarized > 0) {
                        replaceMessagesFromCompaction(allocator, &messages, result.summary, result.messages) catch continue;
                        out("{s}  Compacted {d} messages. Saved ~{d} tokens.{s}\n", .{
                            Style.warning.start(),
                            result.messages_summarized,
                            result.tokens_saved,
                            Style.warning.reset(),
                        });
                    }
                },
                .full => {
                    const summarize_prompt = compactor.buildSummarizationPrompt(compact_msgs.items, compactor.previous_summary) catch continue;
                    defer allocator.free(summarize_prompt);

                    const recent_split = if (compact_msgs.items.len > compactor.recent_window)
                        compact_msgs.items.len - compactor.recent_window
                    else
                        0;
                    const recent_messages = compact_msgs.items[recent_split..];
                    const total_tokens_before = estimateCompactTokens(compact_msgs.items);

                    const summary_response = client.sendChat(summarize_prompt) catch {
                        var fallback_result = (if (compactor.previous_summary.len > 0)
                            compactor.compactWithSummary(compact_msgs.items, compactor.previous_summary)
                        else
                            compactor.compact(compact_msgs.items)) catch continue;
                        defer fallback_result.deinit();

                        if (fallback_result.messages_summarized > 0) {
                            replaceMessagesFromCompaction(allocator, &messages, fallback_result.summary, fallback_result.messages) catch continue;
                            out("{s}  Compacted {d} messages. Saved ~{d} tokens.{s}\n", .{
                                Style.warning.start(),
                                fallback_result.messages_summarized,
                                fallback_result.tokens_saved,
                                Style.warning.reset(),
                            });
                        }
                        continue;
                    };

                    if (summary_response.choices.len == 0) {
                        var fallback_result = (if (compactor.previous_summary.len > 0)
                            compactor.compactWithSummary(compact_msgs.items, compactor.previous_summary)
                        else
                            compactor.compact(compact_msgs.items)) catch continue;
                        defer fallback_result.deinit();

                        if (fallback_result.messages_summarized > 0) {
                            replaceMessagesFromCompaction(allocator, &messages, fallback_result.summary, fallback_result.messages) catch continue;
                            out("{s}  Compacted {d} messages. Saved ~{d} tokens.{s}\n", .{
                                Style.warning.start(),
                                fallback_result.messages_summarized,
                                fallback_result.tokens_saved,
                                Style.warning.reset(),
                            });
                        }
                        continue;
                    }

                    const llm_summary = summary_response.choices[0].message.content orelse "";
                    if (llm_summary.len == 0) {
                        var fallback_result = (if (compactor.previous_summary.len > 0)
                            compactor.compactWithSummary(compact_msgs.items, compactor.previous_summary)
                        else
                            compactor.compact(compact_msgs.items)) catch continue;
                        defer fallback_result.deinit();

                        if (fallback_result.messages_summarized > 0) {
                            replaceMessagesFromCompaction(allocator, &messages, fallback_result.summary, fallback_result.messages) catch continue;
                            out("{s}  Compacted {d} messages. Saved ~{d} tokens.{s}\n", .{
                                Style.warning.start(),
                                fallback_result.messages_summarized,
                                fallback_result.tokens_saved,
                                Style.warning.reset(),
                            });
                        }
                        continue;
                    }

                    compactor.setPreviousSummary(llm_summary) catch continue;
                    const tokens_after = ContextCompactor.estimateTokens(llm_summary) + estimateCompactTokens(recent_messages);
                    const llm_result = compaction_mod.CompactResult{
                        .messages = recent_messages,
                        .tokens_saved = total_tokens_before -| tokens_after,
                        .messages_summarized = @intCast(recent_split),
                        .summary = llm_summary,
                        .agent_metadata = std.StringHashMap([]const u8).init(allocator),
                    };

                    replaceMessagesFromCompaction(allocator, &messages, llm_result.summary, llm_result.messages) catch continue;
                    out("{s}  Used LLM to compress context. Saved ~{d} tokens.{s}\n", .{
                        Style.warning.start(),
                        llm_result.tokens_saved,
                        Style.warning.reset(),
                    });
                },
                .none => {},
            }
        }

        // ── Auto-save session after each turn ──────────────────────
        if (session_dir) |dir| {
            var auto_msgs = array_list_compat.ArrayList(session_mod.Message).init(allocator);
            defer {
                for (auto_msgs.items) |*msg| {
                    allocator.free(msg.role);
                    if (msg.content) |c| allocator.free(c);
                    if (msg.tool_call_id) |tc| allocator.free(tc);
                    if (msg.tool_calls) |calls| {
                        for (calls) |*tc| {
                            allocator.free(tc.id);
                            allocator.free(tc.name);
                            allocator.free(tc.arguments);
                        }
                        allocator.free(calls);
                    }
                }
                auto_msgs.deinit();
            }

            for (messages.items) |chat_msg| {
                const session_msg = session_mod.Message{
                    .role = allocator.dupe(u8, chat_msg.role) catch continue,
                    .content = if (chat_msg.content) |c| allocator.dupe(u8, c) catch null else null,
                    .tool_call_id = if (chat_msg.tool_call_id) |tc| allocator.dupe(u8, tc) catch null else null,
                    .tool_calls = null,
                };
                auto_msgs.append(session_msg) catch continue;
            }

            const auto_now = std.time.timestamp();
            const auto_elapsed_ms = std.time.milliTimestamp() - session_start_time;
            const auto_elapsed_s: u32 = if (auto_elapsed_ms >= 0) @intCast(@divTrunc(auto_elapsed_ms, 1000)) else 0;
            const auto_session = session_mod.Session{
                .id = current_session_id,
                .created_at = auto_now,
                .updated_at = auto_now,
                .title = "",
                .messages = auto_msgs.items,
                .model = current_model_name,
                .provider = current_provider_name,
                .total_tokens = total_input_tokens + total_output_tokens,
                .total_cost = 0.0,
                .turn_count = request_count,
                .duration_seconds = auto_elapsed_s,
            };

            session_mod.saveSession(allocator, dir, &auto_session) catch {};
        }
    }

    // ── Save session on exit ────────────────────────────────────────
    if (session_dir) |dir| {
        var session_messages = array_list_compat.ArrayList(session_mod.Message).init(allocator);
        defer {
            for (session_messages.items) |*msg| {
                allocator.free(msg.role);
                if (msg.content) |c| allocator.free(c);
                if (msg.tool_call_id) |tc| allocator.free(tc);
                if (msg.tool_calls) |calls| {
                    for (calls) |*tc| {
                        allocator.free(tc.id);
                        allocator.free(tc.name);
                        allocator.free(tc.arguments);
                    }
                    allocator.free(calls);
                }
            }
            session_messages.deinit();
        }

        for (messages.items) |chat_msg| {
            const session_msg = session_mod.Message{
                .role = allocator.dupe(u8, chat_msg.role) catch continue,
                .content = if (chat_msg.content) |c| allocator.dupe(u8, c) catch null else null,
                .tool_call_id = if (chat_msg.tool_call_id) |tc| allocator.dupe(u8, tc) catch null else null,
                .tool_calls = null,
            };
            session_messages.append(session_msg) catch continue;
        }

        const now = std.time.timestamp();
        const final_elapsed_ms = std.time.milliTimestamp() - session_start_time;
        const final_elapsed_s: u32 = if (final_elapsed_ms >= 0) @intCast(@divTrunc(final_elapsed_ms, 1000)) else 0;
        const session = session_mod.Session{
            .id = current_session_id,
            .created_at = now,
            .updated_at = now,
            .title = "",
            .messages = session_messages.items,
            .model = current_model_name,
            .provider = current_provider_name,
            .total_tokens = total_input_tokens + total_output_tokens,
            .total_cost = 0.0,
            .turn_count = request_count,
            .duration_seconds = final_elapsed_s,
        };

        // Log session end
        if (structured_logger) |*sl| {
            sl.log(.info, "session ending requests={d} tokens_in={d} tokens_out={d}", .{ request_count, total_input_tokens, total_output_tokens });
        }

        session_mod.saveSession(allocator, dir, &session) catch {};
        out("{s}[session saved: {s}]{s}\n", .{ Style.dimmed.start(), current_session_id, Style.dimmed.reset() });
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
