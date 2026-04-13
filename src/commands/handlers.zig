const std = @import("std");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const chat_mod = @import("chat");
const read_mod = @import("read");
const shell_mod = @import("shell");
const write_mod = @import("write");
const git_mod = @import("git");
const skills_mod = @import("skills");
const tui_mod = @import("tui");
const install_mod = @import("install");
const jobs_mod = @import("jobs");
const plugin_command = @import("plugin_command");
const fallback_mod = @import("fallback");
const parallel_mod = @import("parallel");
const skills_loader_mod = @import("skills_loader");
const skill_import_mod = @import("skill_import");
const tools_mod = @import("tools");
const core_api = @import("core_api");
const worktree_mod = @import("worktree");
const agent_loop_mod = @import("agent_loop");
const connect_mod = @import("connect");
const profile_mod = @import("profile");

const Config = config_mod.Config;

pub fn tryHandlePluginCommand(command: []const u8) !bool {
    const allocator = std.heap.page_allocator;

    // Check plugin commands (config-driven)
    const plugin_cmds = plugin_command.loadDefaultCommands(allocator) catch &[_]plugin_command.PluginCommand{};
    defer plugin_command.freeCommands(allocator, plugin_cmds);

    // Also try user commands
    const user_cmds = plugin_command.loadUserCommands(allocator) catch &[_]plugin_command.PluginCommand{};
    defer plugin_command.freeCommands(allocator, user_cmds);

    // Check default commands first
    if (plugin_command.findCommand(plugin_cmds, command)) |cmd| {
        plugin_command.executeCommand(allocator, cmd) catch |err| {
            std.debug.print("Error executing plugin command '{s}': {}\n", .{ command, err });
        };
        return true;
    }

    // Then check user commands (can override defaults)
    if (plugin_command.findCommand(user_cmds, command)) |cmd| {
        plugin_command.executeCommand(allocator, cmd) catch |err| {
            std.debug.print("Error executing plugin command '{s}': {}\n", .{ command, err });
        };
        return true;
    }

    return false;
}

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    try chat_mod.handleChat(args, config);
}

pub fn handleRead(args: args_mod.Args) !void {
    try read_mod.handleRead(args.remaining);
}

pub fn handleShell(args: args_mod.Args) !void {
    try shell_mod.handleShell(args.remaining);
}

pub fn handleWrite(args: args_mod.Args) !void {
    try write_mod.handleWrite(args.remaining);
}

pub fn handleEdit(args: args_mod.Args) !void {
    try write_mod.handleEdit(args.remaining);
}

pub fn handleGit(args: args_mod.Args) !void {
    try git_mod.handleGit(args.remaining);
}

pub fn handleSkill(args: args_mod.Args) !void {
    try skills_mod.handleSkill(args.remaining);
}

pub fn handleTUI(args: args_mod.Args, config: *config_mod.Config) !void {
    // Import TUI module
    const tui = @import("tui");

    // Get allocator
    const allocator = std.heap.page_allocator;

    // Load profile - use --profile flag if provided, otherwise load current
    var profile_opt: ?profile_mod.Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    // Get provider and model from profile or config
    const provider_name = if (profile_opt) |*p| p.default_provider else config.default_provider;
    const model_name = if (profile_opt) |*p| p.default_model else config.default_model;

    // Initialize registry
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
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
        std.debug.print("Error: No API key for provider '{s}'. Add to ~/.crushcode/config.toml or profile\n", .{provider_name});
        return error.MissingApiKey;
    }

    // Initialize AI client
    var client = try core_api.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    // Set system prompt from profile or config if available
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) {
            client.setSystemPrompt(p.system_prompt);
        }
    } else if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    // Run TUI with real AI client
    try tui.runTUIWithClient(allocator, &client);
}

pub fn handleInstall(args: args_mod.Args) !void {
    try install_mod.handleInstall(args.remaining);
}

pub fn handleJobs(args: args_mod.Args) !void {
    try jobs_mod.handleJobs(args.remaining);
}

fn isRemoteSkillSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "clawhub:") or
        std.mem.startsWith(u8, source, "skills.sh:") or
        std.mem.startsWith(u8, source, "https://github.com/");
}

pub fn handleFallback(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var chain = fallback_mod.FallbackChain.init(allocator);
    defer chain.deinit();

    try chain.addEntry("openrouter", "openai/gpt-5.4");
    try chain.addEntry("anthropic", "claude-3.5-sonnet");
    try chain.addEntry("ollama", "llama3");
    chain.printChain();

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    std.debug.print("\nConnectivity check:\n", .{});
    for (chain.getEntries(), 1..) |entry, index| {
        const status = if (registry.getProvider(entry.provider) != null) "available" else "missing";
        std.debug.print("  {d}. {s}/{s}: {s}\n", .{ index, entry.provider, entry.model, status });
    }
}

pub fn handleParallel(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var executor = parallel_mod.ParallelExecutor.init(allocator, 3);
    defer executor.deinit();

    const task_one = try executor.submit("Summarize repository status", "openrouter", "openai/gpt-5.4");
    defer allocator.free(task_one);

    const task_two = try executor.submit("Review modified files", "anthropic", "claude-3.5-sonnet");
    defer allocator.free(task_two);

    const task_three = try executor.submit("Prepare follow-up notes", "ollama", "llama3");
    defer allocator.free(task_three);

    if (executor.getTask(task_one)) |task| {
        task.status = .running;
    }
    try executor.recordResult(task_one, "Repository status collected", true);
    _ = executor.cancel(task_two);

    executor.printStatus();
    std.debug.print("\nCan accept more tasks: {s}\n", .{if (executor.canAcceptMore()) "yes" else "no"});
    std.debug.print("Recorded results: {d}\n", .{executor.getResults().len});
}

pub fn handleWorktree(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var manager = worktree_mod.WorktreeManager.init(allocator, ".crushcode-worktrees");
    defer manager.deinit();

    std.debug.print("Worktree base directory: {s}\n", .{manager.base_dir});
    manager.printActive();
}

pub fn handleSkillsLoad(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Default skills directory
    const source = if (args.remaining.len > 0)
        args.remaining[0]
    else
        "skills";

    if (isRemoteSkillSource(source)) {
        var importer = skill_import_mod.SkillImporter.init(allocator, "skills");
        defer importer.deinit();

        const result = try importer.importSkill(source);
        defer {
            allocator.free(result.name);
            allocator.free(result.install_path);
        }

        skill_import_mod.SkillImporter.printResult(&result);
        return;
    }

    const skills_dir = source;

    var loader = skills_loader_mod.SkillLoader.init(allocator);
    defer loader.deinit();

    loader.loadFromDirectory(skills_dir) catch |err| {
        std.debug.print("Error loading skills from '{s}': {}\n", .{ skills_dir, err });
        return;
    };

    const skills = loader.getSkills();

    if (skills.len == 0) {
        std.debug.print("No skills found in '{s}'\n", .{skills_dir});
        std.debug.print("Create SKILL.md files in subdirectories.\n", .{});
        return;
    }

    std.debug.print("Loaded {} skills from '{s}':\n\n", .{ skills.len, skills_dir });

    for (skills) |skill| {
        std.debug.print("  {s}", .{skill.name});
        if (skill.description.len > 0) {
            std.debug.print(" - {s}", .{skill.description});
        }
        std.debug.print("\n", .{});

        if (skill.triggers.len > 0) {
            std.debug.print("    Triggers: ", .{});
            for (skill.triggers, 0..) |trigger, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{trigger});
            }
            std.debug.print("\n", .{});
        }

        if (skill.tools.len > 0) {
            std.debug.print("    Tools: ", .{});
            for (skill.tools, 0..) |tool, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{tool});
            }
            std.debug.print("\n", .{});
        }
    }

    // Show XML preview
    std.debug.print("\n--- AI Prompt XML Preview ---\n", .{});
    const xml = loader.toPromptXml(allocator) catch |err| {
        std.debug.print("Error generating XML: {}\n", .{err});
        return;
    };
    defer allocator.free(xml);
    std.debug.print("{s}\n", .{xml});
}

pub fn handleTools(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var registry = tools_mod.ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerBuiltinTools();

    // Handle subcommands
    if (args.remaining.len > 0) {
        const subcmd = args.remaining[0];

        if (std.mem.eql(u8, subcmd, "enable") and args.remaining.len > 1) {
            registry.enable(args.remaining[1]);
            std.debug.print("Enabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "disable") and args.remaining.len > 1) {
            registry.disable(args.remaining[1]);
            std.debug.print("Disabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "check") and args.remaining.len > 1) {
            const tool_name = args.remaining[1];
            if (registry.isAvailable(tool_name)) {
                std.debug.print("Tool '{s}' is available ✓\n", .{tool_name});
            } else if (registry.get(tool_name) != null) {
                std.debug.print("Tool '{s}' is registered but disabled ✗\n", .{tool_name});
            } else {
                std.debug.print("Tool '{s}' not found\n", .{tool_name});
            }
            return;
        } else if (std.mem.eql(u8, subcmd, "category") and args.remaining.len > 1) {
            const cat_name = args.remaining[1];
            const category = parseCategory(cat_name) orelse {
                std.debug.print("Unknown category: {s}\n", .{cat_name});
                std.debug.print("Categories: file_ops, shell, git, network, ai, mcp, system, custom\n", .{});
                return;
            };
            const tools_in_cat = registry.getByCategory(allocator, category) catch return;
            defer allocator.free(tools_in_cat);
            std.debug.print("Tools in {s}:\n", .{cat_name});
            for (tools_in_cat) |t| {
                std.debug.print("  - {s}\n", .{t});
            }
            return;
        }
    }

    // Default: list all tools
    registry.printTools();
}

fn parseCategory(name: []const u8) ?tools_mod.Tool.ToolCategory {
    if (std.mem.eql(u8, name, "file_ops")) return .file_ops;
    if (std.mem.eql(u8, name, "shell")) return .shell;
    if (std.mem.eql(u8, name, "git")) return .git;
    if (std.mem.eql(u8, name, "network")) return .network;
    if (std.mem.eql(u8, name, "ai")) return .ai;
    if (std.mem.eql(u8, name, "mcp")) return .mcp;
    if (std.mem.eql(u8, name, "system")) return .system;
    if (std.mem.eql(u8, name, "custom")) return .custom;
    return null;
}

pub fn handleList(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerAllProviders();

    if (args.remaining.len > 0) {
        const provider_name = args.remaining[0];
        if (std.mem.eql(u8, provider_name, "--providers") or std.mem.eql(u8, provider_name, "-p")) {
            try registry.printProviders();
        } else if (std.mem.eql(u8, provider_name, "--refresh") or std.mem.eql(u8, provider_name, "-r")) {
            // Refresh models from OpenRouter (no auth required)
            try registry.printOpenRouterModelsLive();
        } else if (std.mem.eql(u8, provider_name, "--models") or std.mem.eql(u8, provider_name, "-m")) {
            if (args.remaining.len < 2) {
                std.debug.print("Error: Provider name required for --models\n\n", .{});
                try printHelp();
                return;
            }
            const provider = args.remaining[1];
            try registry.printModels(provider);
        } else {
            try registry.printModels(provider_name);
        }
    } else {
        try registry.printProviders();
        std.debug.print("\nTo see models for a provider:\n", .{});
        std.debug.print("  crushcode list <provider-name>\n", .{});
        std.debug.print("  crushcode list --models <provider-name>\n", .{});
        std.debug.print("\nTo fetch live models from OpenRouter:\n", .{});
        std.debug.print("  crushcode list --refresh\n", .{});
    }
}

pub fn printHelp() !void {
    std.debug.print(
        \\Crushcode - AI Coding Assistant
        \\
        \\Usage:
        \\  crushcode [command] [options]
        \\
        \\Commands:
        \\  chat           Start interactive chat session (streaming)
        \\  read <file>   Read file content
        \\  shell <cmd>   Execute shell command
        \\  write <path> <content>  Write content to file
        \\  edit <file>   Edit/create a file
        \\  git <subcmd>  Git operations (status, add, commit, push, pull, branch)
        \\  skill <name>  Run a skill command (echo, date, whoami, etc.)
        \\  skills-load [dir]  Load and list SKILL.md files (default: skills/)
        \\  parallel      Show parallel executor status
        \\  tools         List, enable, disable, check tools
        \\  tui          Launch interactive terminal UI
        \\  install      Show installation instructions
        \\  jobs         Job control (background jobs)
        \\  worktree      Show worktree manager status
        \\  graph          Analyze codebase with knowledge graph
        \\  agent-loop     Show agent loop engine status
        \\  workflow       Show phase workflow progress
        \\  compact        Show context compaction status
        \\  scaffold       Generate project scaffolding
        \\  list           List providers or models
        \\  usage         Show token usage and cost tracking
        \\  connect        Add API credentials for providers
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Chat Commands (in interactive mode):
        \\  /usage         Show session token usage
        \\  /clear         Clear conversation history
        \\  /hooks         Show registered lifecycle hooks
        \\  /exit          Exit chat
        \\
        \\Options:
        \\  --provider <id>    Use specific AI provider
        \\  --model <id>       Use specific model
        \\  --profile <name>   Use specific profile
        \\  --config <path>    Use custom config file
        \\  --json, -j         Output JSON Lines (machine-readable)
        \\  --color <mode>     Color output: auto, always, never
        \\  --interactive, -i  Start interactive chat
        \\  --tui, -t          Launch terminal UI
        \\
        \\Examples:
        \\  crushcode chat
        \\  crushcode chat --provider openai --model gpt-4o
        \\  crushcode chat --profile work
        \\  crushcode read src/main.zig
        \\  crushcode shell "ls -la"
        \\  crushcode write test.txt "Hello World"
        \\  crushcode parallel
        \\  crushcode usage
        \\  crushcode worktree
        \\  crushcode list --provider openai
        \\
    , .{});
}

pub fn handleUsage(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Initialize usage tracker and pricing
    var tracker = @import("usage_tracker").UsageTracker.init(allocator, "~/.crushcode/usage");
    defer tracker.deinit();

    var pricing = @import("usage_pricing").PricingTable.init(allocator) catch {
        std.debug.print("Error initializing pricing table\n", .{});
        return;
    };
    defer pricing.deinit();

    const session = tracker.getSessionUsage();

    std.debug.print("\n=== Crushcode Usage Report ===\n", .{});
    std.debug.print("\nSession (current):\n", .{});
    std.debug.print("  Requests: {d}\n", .{session.request_count});
    std.debug.print("  Tokens: {d} in / {d} out", .{ session.input_tokens, session.output_tokens });
    if (session.cache_read_tokens > 0) {
        std.debug.print(" / {d} cache read", .{session.cache_read_tokens});
    }
    std.debug.print("\n", .{});

    if (session.estimated_cost_usd > 0) {
        std.debug.print("  Cost: ${d:.4}\n", .{session.estimated_cost_usd});
    }

    if (session.by_provider.count() > 0) {
        std.debug.print("\n  By provider:\n", .{});
        var iter = session.by_provider.iterator();
        while (iter.next()) |entry| {
            const pu = entry.value_ptr;
            std.debug.print("    {s} ({s}): {d} req | ${d:.4}\n", .{
                pu.provider,
                pu.model,
                pu.request_count,
                pu.cost_usd,
            });
        }
    }

    std.debug.print("\nTip: Set budget limits in ~/.crushcode/config.toml:\n", .{});
    std.debug.print("  [budget]\n", .{});
    std.debug.print("  daily_limit_usd = 1.0\n", .{});
    std.debug.print("  monthly_limit_usd = 50.0\n", .{});
}

pub fn handleConnect(args: args_mod.Args) !void {
    try connect_mod.handleConnect(args.remaining);
}

pub fn handleProfile(args: args_mod.Args) !void {
    try profile_mod.handleProfile(args.remaining);
}

pub fn printVersion() !void {
    std.debug.print("Crushcode v0.1.0\n", .{});
}

/// Phase 23: Codebase Knowledge Graph (Graphify-inspired)
pub fn handleGraph(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    const graph_mod = @import("graph");

    var kg = graph_mod.KnowledgeGraph.init(allocator);
    defer kg.deinit();

    if (args.remaining.len > 0) {
        // Index specific files
        for (args.remaining) |file_path| {
            std.debug.print("Indexing: {s}\n", .{file_path});
            kg.indexFile(file_path) catch |err| {
                std.debug.print("  Error indexing {s}: {}\n", .{ file_path, err });
            };
        }
    } else {
        // Default: index common source files
        const default_files = [_][]const u8{
            "src/main.zig",
            "src/ai/client.zig",
            "src/ai/registry.zig",
            "src/commands/handlers.zig",
            "src/commands/chat.zig",
            "src/config/config.zig",
            "src/cli/args.zig",
        };
        std.debug.print("Indexing default source files...\n\n", .{});
        for (&default_files) |file_path| {
            kg.indexFile(file_path) catch continue;
        }
    }

    // Detect communities
    kg.detectCommunities() catch {};

    // Print stats
    kg.printStats();

    // Show compressed context preview
    if (kg.nodes.count() > 0) {
        const ctx = kg.toCompressedContext(allocator) catch return;
        defer allocator.free(ctx);
        std.debug.print("\n--- Compressed Context Preview ---\n", .{});
        std.debug.print("{s}\n", .{ctx});
    }
}

/// Phase 24: Agent Loop Engine (OpenHarness-inspired)
pub fn handleAgentLoop(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    const loop_mod = @import("agent_loop");

    var agent = loop_mod.AgentLoop.init(allocator);
    defer agent.deinit();

    // Configure: suppress intermediate output for clean demo, low iterations
    var config = loop_mod.LoopConfig.init();
    config.max_iterations = 10;
    config.show_intermediate = false;
    agent.setConfig(config);

    // Register demo tools
    agent.registerTool("read_file", demoReadFileTool) catch {};
    agent.registerTool("search", demoSearchTool) catch {};

    agent.printStatus();

    // Run a demo loop with a mock AI callback
    std.debug.print("\n--- Running demo agent loop ---\n", .{});
    var result = agent.run(demoAISend, "Find information about Zig programming language") catch {
        std.debug.print("Error: agent loop failed\n", .{});
        return;
    };
    defer result.deinit();

    std.debug.print("\n--- Agent Loop Result ---\n", .{});
    std.debug.print("  Final response: {s}\n", .{result.final_response});
    std.debug.print("  Iterations: {d}\n", .{result.total_iterations});
    std.debug.print("  Tool calls: {d}\n", .{result.total_tool_calls});
    std.debug.print("  Retries: {d}\n", .{result.total_retries});
    std.debug.print("  Steps: {d}\n", .{result.steps.items.len});

    for (result.steps.items, 0..) |step, i| {
        std.debug.print("\n  Step {d}:\n", .{i + 1});
        std.debug.print("    AI: {s}\n", .{step.ai_response});
        std.debug.print("    Finish: {s}\n", .{step.finish_reason});
        if (step.has_tool_calls) {
            for (step.tool_calls.items) |tc| {
                std.debug.print("    Tool call: {s}({s})\n", .{ tc.name, tc.arguments });
            }
            for (step.tool_results.items) |tr| {
                const status = if (tr.success) "OK" else "FAIL";
                std.debug.print("    Tool result [{s}]: {s}\n", .{ status, tr.output });
            }
        }
    }
}

// Demo tool: read_file
fn demoReadFileTool(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    _ = call_id;
    _ = arguments;
    return agent_loop_mod.ToolResult.init(allocator, "demo-read", "File content: Zig is a systems programming language...", true);
}

// Demo tool: search
fn demoSearchTool(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    _ = call_id;
    _ = arguments;
    return agent_loop_mod.ToolResult.init(allocator, "demo-search", "Search results: Zig homepage, Zig learn, Zig standard library docs", true);
}

// Demo AI send: returns tool calls on first 2 calls, then stops
var demo_ai_call_count: u32 = 0;
fn demoAISend(allocator: std.mem.Allocator, messages: []const agent_loop_mod.LoopMessage) anyerror!agent_loop_mod.AIResponse {
    _ = allocator;
    _ = messages;
    demo_ai_call_count += 1;
    if (demo_ai_call_count == 1) {
        return agent_loop_mod.AIResponse{
            .content = "Let me search for information.",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]ai_types.ToolCallInfo{
                .{ .id = "call-1", .name = "search", .arguments = "Zig programming language" },
            },
        };
    }
    if (demo_ai_call_count == 2) {
        return agent_loop_mod.AIResponse{
            .content = "Let me read more details.",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]ai_types.ToolCallInfo{
                .{ .id = "call-2", .name = "read_file", .arguments = "zig_intro.md" },
            },
        };
    }
    return agent_loop_mod.AIResponse{
        .content = "Based on my research: Zig is a modern systems programming language designed to be a better alternative to C. It offers compile-time code execution, no hidden control flow, and optional types.",
        .finish_reason = .stop,
        .tool_calls = &.{},
    };
}

/// Phase 25: Phase Workflow System (GSD-inspired)
pub fn handleWorkflow(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    const wf_mod = @import("workflow");

    var workflow = wf_mod.PhaseWorkflow.init(allocator, "crushcode") catch return;
    defer workflow.deinit();

    // Build a demo workflow with actual phases
    const phase_names = [_][]const u8{ "Core Infrastructure", "Shell Execution", "AI File Ops", "Skills System", "Terminal UI", "MCP Integration" };
    for (&phase_names, 1..) |name, i| {
        const phase = allocator.create(wf_mod.WorkflowPhase) catch continue;
        phase.* = wf_mod.WorkflowPhase.init(allocator, @intCast(i), name, "Phase goal") catch continue;
        if (i > 1) phase.addDependency(@intCast(i - 1)) catch {};
        workflow.addPhase(phase) catch {};
    }

    // Mark completed phases
    workflow.completePhase(1) catch {};
    workflow.completePhase(2) catch {};
    workflow.completePhase(3) catch {};
    workflow.completePhase(4) catch {};
    workflow.completePhase(5) catch {};
    workflow.completePhase(6) catch {};

    if (args.remaining.len > 0 and std.mem.eql(u8, args.remaining[0], "--xml")) {
        const xml = workflow.toXml(allocator) catch return;
        defer allocator.free(xml);
        std.debug.print("{s}\n", .{xml});
    } else {
        workflow.printProgress();
    }
}

/// Phase 26: Auto-Context Compaction (OpenHarness-inspired)
pub fn handleCompact(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    const compact_mod = @import("compaction");

    var compactor = compact_mod.ContextCompactor.init(allocator, 128000);
    defer compactor.deinit();

    compactor.preserveTopic("architecture") catch {};
    compactor.preserveTopic("decisions") catch {};

    // Demo: show compaction with sample messages
    const sample_messages = [_]compact_mod.CompactMessage{
        .{ .role = "user", .content = "I want to implement a new authentication system using OAuth 2.0", .timestamp = null },
        .{ .role = "assistant", .content = "I'll help you implement OAuth 2.0 authentication. We decided to use the authorization code flow with PKCE for security. This approach supports both web and mobile clients.", .timestamp = null },
        .{ .role = "user", .content = "What about token refresh?", .timestamp = null },
        .{ .role = "assistant", .content = "We should implement automatic token refresh using a background timer. The refresh token will be stored securely in an httpOnly cookie.", .timestamp = null },
        .{ .role = "user", .content = "Great, let's implement it", .timestamp = null },
        .{ .role = "assistant", .content = "Here's the implementation plan for the OAuth 2.0 system with PKCE and token refresh...", .timestamp = null },
        .{ .role = "user", .content = "How do we test this?", .timestamp = null },
        .{ .role = "assistant", .content = "We chose to use integration tests with a mock OAuth server. This will let us test the full flow without external dependencies.", .timestamp = null },
        .{ .role = "user", .content = "What about the latest changes?", .timestamp = null },
        .{ .role = "assistant", .content = "Based on our recent discussion, we approved the token rotation strategy and will use short-lived access tokens (15 min) with longer refresh tokens (7 days).", .timestamp = null },
        .{ .role = "user", .content = "Show me the current implementation status", .timestamp = null },
        .{ .role = "assistant", .content = "Current status: OAuth flow implemented, token refresh working, PKCE challenge generation done. Remaining: CSRF state validation and error handling.", .timestamp = null },
    };

    var estimated_tokens: u64 = 0;
    for (&sample_messages) |msg| {
        estimated_tokens += compact_mod.ContextCompactor.estimateTokens(msg.content);
    }

    compactor.printStatus(estimated_tokens);

    // Run compaction demo
    var result = compactor.compact(&sample_messages) catch return;
    defer result.deinit();
    std.debug.print("\nCompaction Result:\n", .{});
    std.debug.print("  Messages summarized: {d}\n", .{result.messages_summarized});
    std.debug.print("  Tokens saved: {d}\n", .{result.tokens_saved});
    std.debug.print("  Recent messages preserved: {d}\n", .{result.messages.len});
    if (result.summary.len > 0) {
        std.debug.print("\n--- Generated Summary ---\n{s}\n", .{result.summary});
    }
}

/// Phase 27: Project Scaffolding (GSD-inspired)
pub fn handleScaffold(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;
    const scaffold_mod = @import("scaffold");

    const name = if (args.remaining.len > 0) args.remaining[0] else "my-project";
    const desc = if (args.remaining.len > 1) args.remaining[1] else "A new project scaffolded by Crushcode";

    var scaffolder = scaffold_mod.ProjectScaffolder.init(allocator, name, desc) catch return;
    defer scaffolder.deinit();

    scaffolder.addTech("Zig") catch {};
    scaffolder.addTech("Zig stdlib") catch {};

    // Add sample requirements
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

    // Add phases
    const ph1 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph1.* = scaffold_mod.ScaffoldPhase.init(allocator, 1, "Core Setup") catch return;
    ph1.addRequirement("REQ-01") catch {};
    ph1.addRequirement("REQ-03") catch {};
    scaffolder.addPhase(ph1) catch {};

    const ph2 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph2.* = scaffold_mod.ScaffoldPhase.init(allocator, 2, "AI Integration") catch return;
    ph2.addRequirement("REQ-02") catch {};
    scaffolder.addPhase(ph2) catch {};

    // Print summary
    scaffolder.printSummary();

    // Generate artifacts
    std.debug.print("\n--- Generated PROJECT.md ---\n", .{});
    const project_md = scaffolder.generateProjectMd() catch return;
    defer allocator.free(project_md);
    std.debug.print("{s}\n", .{project_md});

    std.debug.print("\n--- Generated REQUIREMENTS.md ---\n", .{});
    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);
    std.debug.print("{s}\n", .{reqs_md});

    std.debug.print("\n--- Generated ROADMAP.md ---\n", .{});
    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);
    std.debug.print("{s}\n", .{roadmap_md});
}
