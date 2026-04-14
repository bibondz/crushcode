const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const chat_helpers = @import("chat_helpers");
const chat_bridge = @import("chat_bridge");

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

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;
    const json_out = json_output_mod.JsonOutput.init(args.json);

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

    out("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    json_out.emitSessionStart(provider_name, model_name);

    var response: core.ChatResponse = undefined;
    var content_slice: []const u8 = "";

    if (args.stream) {
        var full_content = array_list_compat.ArrayList(u8).init(allocator);
        defer full_content.deinit();

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
        }.callback) catch |err| {
            out("\nError sending streaming request: {}\n", .{err});
            json_out.emitError(@errorName(err));
            return err;
        };

        out("\n", .{});
        content_slice = "";
    } else {
        response = ai_client.sendChat(message) catch |err| {
            out("\nError sending request: {}\n", .{err});
            json_out.emitError(@errorName(err));
            return err;
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

    var kg = KnowledgeGraph.init(allocator);
    defer kg.deinit();

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

    var messages = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
    defer {
        for (messages.items) |msg| {
            chat_helpers.freeChatMessage(msg, allocator);
        }
        messages.deinit();
    }

    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var request_count: u32 = 0;

    var compactor = ContextCompactor.init(allocator, 128_000);
    defer compactor.deinit();
    compactor.setRecentWindow(10); // Keep last 10 messages at full fidelity

    out("=== Interactive Chat Mode (Streaming) ===\n", .{});
    out("Provider: {s} | Model: {s}\n", .{ current_provider_name, current_model_name });
    out("Type your message and press Enter. Press Ctrl+C to exit.\n", .{});
    out("Commands: /help /clear /model /cost /compact /exit\n", .{});
    out("Shortcuts: /h /c /m /q\n", .{});
    out("--------------------------------------------\n\n", .{});

    json_out.emitSessionStart(current_provider_name, current_model_name);

    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    while (true) {
        out("\n{s}You:{s} ", .{ Style.prompt_user.start(), Style.prompt_user.reset() });

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
        var loop_result = try agent_loop.run(chat_bridge.sendInteractiveLoopMessages, user_message);
        chat_bridge.active_bridge_context = null;
        tool_executors.setJsonOutput(.{ .enabled = false });
        chat_bridge.active_streaming_enabled = false;
        defer loop_result.deinit();

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
        if (compactor.needsCompaction(session_tokens) and messages.items.len > 12) {
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

            const result = compactor.compact(compact_msgs.items) catch |err| {
                out("Compaction failed: {}\n", .{err});
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
