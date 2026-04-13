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
const checkpoint_mod = @import("checkpoint");
const ast_grep_mod = @import("ast_grep");
const lsp_handler = @import("lsp_handler");
const mcp_bridge_mod = @import("mcp_bridge");
const mcp_handler = @import("mcp_handler");
const plugin_manager_mod = @import("plugin_manager");
const capability_catalog = @import("capability_catalog");
const usage_budget = @import("usage_budget");
const usage_report = @import("usage_report");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

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
            stdout_print("Error executing plugin command '{s}': {}\n", .{ command, err });
        };
        return true;
    }

    // Then check user commands (can override defaults)
    if (plugin_command.findCommand(user_cmds, command)) |cmd| {
        plugin_command.executeCommand(allocator, cmd) catch |err| {
            stdout_print("Error executing plugin command '{s}': {}\n", .{ command, err });
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
        stdout_print("Error: Provider '{s}' not found\n", .{provider_name});
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
        stdout_print("Error: No API key for provider '{s}'. Add to ~/.crushcode/config.toml or profile\n", .{provider_name});
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

fn capabilityKindLabel(kind: capability_catalog.CapabilityKind) []const u8 {
    return switch (kind) {
        .tool => "Tools",
        .plugin => "Plugins",
        .skill => "Skills",
        .mcp_tool => "MCP Tools",
        .builtin => "Built-ins",
    };
}

pub fn handleCapabilities(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var catalog = capability_catalog.CapabilityCatalog.init(allocator);
    defer catalog.deinit();

    var tool_registry = tools_mod.ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.registerBuiltinTools();

    const available_tools = try tool_registry.getAvailableTools(allocator);
    defer allocator.free(available_tools);
    for (available_tools) |tool_name| {
        if (tool_registry.get(tool_name)) |tool| {
            try catalog.register(.{
                .name = tool.name,
                .kind = .tool,
                .enabled = tool.enabled,
                .description = tool.description,
            });
        }
    }

    var plugin_manager = plugin_manager_mod.PluginManager.init(allocator);
    defer plugin_manager.deinit();
    try plugin_manager.initializeBuiltIns();

    const plugins = try plugin_manager.listPlugins();
    defer allocator.free(plugins);
    for (plugins) |plugin| {
        const status = plugin_manager.getPluginStatus(plugin.name) catch continue;
        try catalog.register(.{
            .name = status.name,
            .kind = if (status.type == .builtin) .builtin else .plugin,
            .enabled = status.enabled,
            .description = status.description,
        });
    }

    var skill_loader = skills_loader_mod.SkillLoader.init(allocator);
    defer skill_loader.deinit();
    skill_loader.loadFromDirectory("skills") catch {};
    for (skill_loader.getSkills()) |skill| {
        try catalog.register(.{
            .name = skill.name,
            .kind = .skill,
            .enabled = true,
            .description = skill.description,
            .source = skill.file_path,
        });
    }

    const kinds = [_]capability_catalog.CapabilityKind{ .tool, .plugin, .builtin, .skill, .mcp_tool };
    catalog.printSummary();
    stdout_print("\n", .{});
    for (kinds) |kind| {
        const entries = try catalog.listByKind(allocator, kind);
        defer allocator.free(entries);

        if (entries.len == 0) continue;

        stdout_print("{s}:\n", .{capabilityKindLabel(kind)});
        for (entries) |entry| {
            const status = if (entry.enabled) "enabled" else "disabled";
            if (entry.source) |source| {
                stdout_print("  - {s} [{s}] — {s} ({s})\n", .{ entry.name, status, entry.description, source });
            } else {
                stdout_print("  - {s} [{s}] — {s}\n", .{ entry.name, status, entry.description });
            }
        }
        stdout_print("\n", .{});
    }
}

pub fn handleJobs(args: args_mod.Args) !void {
    try jobs_mod.handleJobs(args.remaining);
}

fn loadBudgetConfig(allocator: std.mem.Allocator) ?usage_budget.BudgetConfig {
    const config_path = config_mod.getConfigPath(allocator) catch return null;
    defer allocator.free(config_path);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var budget_cfg = usage_budget.BudgetConfig{};
    var in_budget_section = false;
    var found_limit = false;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[') {
            in_budget_section = std.mem.eql(u8, trimmed, "[budget]");
            continue;
        }

        if (!in_budget_section) continue;
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const value_text = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
        const value = std.fmt.parseFloat(f64, value_text) catch continue;

        if (std.mem.eql(u8, key, "daily_limit_usd")) {
            budget_cfg.daily_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "monthly_limit_usd")) {
            budget_cfg.monthly_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "per_session_limit_usd")) {
            budget_cfg.per_session_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "alert_threshold_pct")) {
            budget_cfg.alert_threshold_pct = value;
        }
    }

    if (!found_limit or !budget_cfg.isSet()) return null;
    return budget_cfg;
}

pub fn handlePlugin(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var manager = plugin_manager_mod.PluginManager.init(allocator);
    defer manager.deinit();

    try manager.initializeBuiltIns();

    const stdout = file_compat.File.stdout().writer();

    if (args.remaining.len == 0) {
        try stdout.print("Usage: crushcode plugin <list|enable|disable|status> [name]\n", .{});
        return;
    }

    const subcmd = args.remaining[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const plugins = try manager.listPlugins();
        defer allocator.free(plugins);

        if (plugins.len == 0) {
            try stdout.writeAll("No plugins registered\n");
            return;
        }

        for (plugins) |plugin| {
            try stdout.print("{s} - {s} ({s})\n", .{ plugin.name, plugin.description, @tagName(plugin.type) });
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "enable") or std.mem.eql(u8, subcmd, "disable")) {
        if (args.remaining.len < 2) {
            try stdout.print("Usage: crushcode plugin {s} <name>\n", .{subcmd});
            return;
        }

        const enabled = std.mem.eql(u8, subcmd, "enable");
        const plugin_name = args.remaining[1];
        try manager.setPluginEnabled(plugin_name, enabled);
        try stdout.print("{s} plugin: {s}\n", .{ if (enabled) "Enabled" else "Disabled", plugin_name });
        return;
    }

    if (std.mem.eql(u8, subcmd, "status")) {
        if (args.remaining.len > 1) {
            const plugin_name = args.remaining[1];
            const status = try manager.getPluginStatus(plugin_name);
            try stdout.print("{s}: {s} ({s}) - {s}\n", .{
                status.name,
                if (status.enabled) "enabled" else "disabled",
                @tagName(status.type),
                status.description,
            });
            return;
        }

        const plugins = try manager.listPlugins();
        defer allocator.free(plugins);
        for (plugins) |plugin| {
            const status = try manager.getPluginStatus(plugin.name);
            try stdout.print("{s}: {s}\n", .{ status.name, if (status.enabled) "enabled" else "disabled" });
        }
        return;
    }

    try stdout.print("Unknown plugin subcommand: {s}\n", .{subcmd});
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

    stdout_print("\nConnectivity check:\n", .{});
    for (chain.getEntries(), 1..) |entry, index| {
        const status = if (registry.getProvider(entry.provider) != null) "available" else "missing";
        stdout_print("  {d}. {s}/{s}: {s}\n", .{ index, entry.provider, entry.model, status });
    }
}

pub fn handleParallel(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var executor = parallel_mod.ParallelExecutor.init(allocator, 3);
    defer executor.deinit();

    // Submit tasks with categories - agents will pick appropriate models
    const task_one = try executor.submit("Summarize repository status", "openrouter", "openai/gpt-5.4", .research);
    defer allocator.free(task_one);

    const task_two = try executor.submit("Review modified files", "anthropic", "claude-3.5-sonnet", .review);
    defer allocator.free(task_two);

    const task_three = try executor.submit("Prepare follow-up notes", "ollama", "llama3", .quick);
    defer allocator.free(task_three);

    if (executor.getTask(task_one)) |task| {
        task.status = .running;
    }
    try executor.recordResult(task_one, "Repository status collected", true);
    _ = executor.cancel(task_two);

    executor.printStatus();
    stdout_print("\nCan accept more tasks: {s}\n", .{if (executor.canAcceptMore()) "yes" else "no"});
    stdout_print("Recorded results: {d}\n", .{executor.getResults().len});
}

/// Handle multi-agent spawning with category delegation
pub fn handleAgents(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse agent categories from --agents flag
    const agents_str = args.agents orelse {
        stdout_print("Usage: crushcode agents --agents <categories>\n", .{});
        stdout_print("Categories: visual-engineering, ultrabrain, deep, quick, review, research, general\n", .{});
        stdout_print("Example: crushcode agents --agents visual,deep,quick\n", .{});
        return;
    };

    // Parse max concurrent agents
    const max_concurrent = args.max_agents;

    var executor = parallel_mod.ParallelExecutor.init(allocator, max_concurrent);
    defer executor.deinit();

    // Parse and validate categories - manual split approach
    var categories = array_list_compat.ArrayList(parallel_mod.AgentCategory).init(allocator);
    defer categories.deinit();

    // Parse comma-separated categories manually
    var start: usize = 0;
    while (start < agents_str.len) {
        var end = start;
        while (end < agents_str.len and agents_str[end] != ',') {
            end += 1;
        }
        const cat_str = std.mem.trim(u8, agents_str[start..end], " ");

        if (parallel_mod.parseCategory(cat_str)) |cat| {
            try categories.append(cat);
        } else {
            stdout_print("Warning: Unknown category '{s}' - skipping\n", .{cat_str});
        }

        if (end < agents_str.len and agents_str[end] == ',') {
            start = end + 1;
        } else {
            break;
        }
    }

    if (categories.items.len == 0) {
        stdout_print("Error: No valid categories provided\n", .{});
        return;
    }

    // Submit tasks for each category
    for (categories.items) |cat| {
        const default_provider = parallel_mod.getDefaultProviderForCategory(cat);
        const default_model = parallel_mod.getDefaultModelForCategory(cat);

        const task_desc = switch (cat) {
            .visual_engineering => "Review and improve UI components",
            .ultrabrain => "Analyze complex architecture decisions",
            .deep => "Research and implement feature end-to-end",
            .quick => "Fix simple issues and typos",
            .general => "Handle general purpose tasks",
            .review => "Perform code review and QA",
            .research => "Research patterns and documentation",
        };

        const task_id = try executor.submit(task_desc, default_provider, default_model, cat);
        stdout_print("Spawned agent: {s} ({s}/{s})\n", .{
            @tagName(cat), default_provider, default_model,
        });
        allocator.free(task_id);
    }

    stdout_print("\nTotal agents spawned: {d}\n", .{categories.items.len});
    stdout_print("Max concurrent: {d}\n", .{max_concurrent});
    stdout_print("\nUse 'crushcode parallel' to see status\n", .{});
}

pub fn handleWorktree(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var manager = worktree_mod.WorktreeManager.init(allocator, ".crushcode-worktrees");
    defer manager.deinit();

    stdout_print("Worktree base directory: {s}\n", .{manager.base_dir});
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
        stdout_print("Error loading skills from '{s}': {}\n", .{ skills_dir, err });
        return;
    };

    const skills = loader.getSkills();

    if (skills.len == 0) {
        stdout_print("No skills found in '{s}'\n", .{skills_dir});
        stdout_print("Create SKILL.md files in subdirectories.\n", .{});
        return;
    }

    stdout_print("Loaded {} skills from '{s}':\n\n", .{ skills.len, skills_dir });

    for (skills) |skill| {
        stdout_print("  {s}", .{skill.name});
        if (skill.description.len > 0) {
            stdout_print(" - {s}", .{skill.description});
        }
        stdout_print("\n", .{});

        if (skill.triggers.len > 0) {
            stdout_print("    Triggers: ", .{});
            for (skill.triggers, 0..) |trigger, i| {
                if (i > 0) stdout_print(", ", .{});
                stdout_print("{s}", .{trigger});
            }
            stdout_print("\n", .{});
        }

        if (skill.tools.len > 0) {
            stdout_print("    Tools: ", .{});
            for (skill.tools, 0..) |tool, i| {
                if (i > 0) stdout_print(", ", .{});
                stdout_print("{s}", .{tool});
            }
            stdout_print("\n", .{});
        }
    }

    // Show XML preview
    stdout_print("\n--- AI Prompt XML Preview ---\n", .{});
    const xml = loader.toPromptXml(allocator) catch |err| {
        stdout_print("Error generating XML: {}\n", .{err});
        return;
    };
    defer allocator.free(xml);
    stdout_print("{s}\n", .{xml});
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
            stdout_print("Enabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "disable") and args.remaining.len > 1) {
            registry.disable(args.remaining[1]);
            stdout_print("Disabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "check") and args.remaining.len > 1) {
            const tool_name = args.remaining[1];
            if (registry.isAvailable(tool_name)) {
                stdout_print("Tool '{s}' is available ✓\n", .{tool_name});
            } else if (registry.get(tool_name) != null) {
                stdout_print("Tool '{s}' is registered but disabled ✗\n", .{tool_name});
            } else {
                stdout_print("Tool '{s}' not found\n", .{tool_name});
            }
            return;
        } else if (std.mem.eql(u8, subcmd, "category") and args.remaining.len > 1) {
            const cat_name = args.remaining[1];
            const category = parseCategory(cat_name) orelse {
                stdout_print("Unknown category: {s}\n", .{cat_name});
                stdout_print("Categories: file_ops, shell, git, network, ai, mcp, system, custom\n", .{});
                return;
            };
            const tools_in_cat = registry.getByCategory(allocator, category) catch return;
            defer allocator.free(tools_in_cat);
            stdout_print("Tools in {s}:\n", .{cat_name});
            for (tools_in_cat) |t| {
                stdout_print("  - {s}\n", .{t});
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

/// Handle ast-grep pattern search
pub fn handleGrep(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len < 2) {
        stdout_print("Usage: crushcode grep <pattern> <file-or-dir> [--lang <language>]\n", .{});
        stdout_print("\nAST-grep pattern examples:\n", .{});
        stdout_print("  crushcode grep 'console.log($MSG)' src/\n", .{});
        stdout_print("  crushcode grep 'function $NAME(...) {{ ... }}' --lang javascript\n", .{});
        stdout_print("  crushcode grep 'await $FETCH(...)' --lang ts\n", .{});
        return;
    }

    const pattern = args.remaining[0];
    const target = args.remaining[1];

    // Parse language from --lang flag
    var language = ast_grep_mod.AstGrep.Language.unknown;
    for (args.remaining, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.remaining.len) {
                language = ast_grep_mod.parseLanguage(args.remaining[i + 1]);
            }
        }
    }

    var grep = ast_grep_mod.AstGrep.init(allocator, pattern, language);

    // Check if target is a file - use stat instead of access
    const file_exists = std.fs.cwd().statFile(target) catch null;

    if (file_exists != null) {
        // It's a file - search directly
        const matches = grep.search(target) catch |err| {
            stdout_print("Error searching '{s}': {}\n", .{ target, err });
            return;
        };
        defer {
            for (matches) |m| {
                allocator.free(m.file);
                allocator.free(m.matched_text);
                allocator.free(m.context);
            }
            allocator.free(matches);
        }
        ast_grep_mod.AstGrep.printMatches(matches);
    } else {
        // It's a directory - search all matching files
        stdout_print("Searching in directory: {s}\n", .{target});
        const matches = grep.searchGlob(target, pattern) catch |err| {
            stdout_print("Error searching directory '{s}': {}\n", .{ target, err });
            return;
        };
        defer {
            for (matches) |m| {
                allocator.free(m.file);
                allocator.free(m.matched_text);
                allocator.free(m.context);
            }
            allocator.free(matches);
        }
        ast_grep_mod.AstGrep.printMatches(matches);
    }
}

/// Handle LSP (Language Server Protocol) commands
pub fn handleLSP(args: args_mod.Args) !void {
    try lsp_handler.handleLSP(args);
}

/// Handle MCP tool listing and execution
pub fn handleMCP(args: args_mod.Args) !void {
    try mcp_handler.handleMCP(args);
}

/// Handle diff visualization
pub fn handleDiff(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len < 2) {
        stdout_print("Usage: crushcode diff <old> <new>\n", .{});
        stdout_print("       crushcode diff --unified <old> <new>\n", .{});
        stdout_print("\nOptions:\n", .{});
        stdout_print("  --inline      Show inline diff format (default)\n", .{});
        return;
    }

    const old_path = args.remaining[0];
    const new_path = args.remaining[1];

    const visualizer_mod = @import("diff");

    var visualizer = visualizer_mod.DiffVisualizer.init(allocator);
    defer visualizer.deinit();

    try visualizer.compareFiles(old_path, new_path);
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
                stdout_print("Error: Provider name required for --models\n\n", .{});
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
        stdout_print("\nTo see models for a provider:\n", .{});
        stdout_print("  crushcode list <provider-name>\n", .{});
        stdout_print("  crushcode list --models <provider-name>\n", .{});
        stdout_print("\nTo fetch live models from OpenRouter:\n", .{});
        stdout_print("  crushcode list --refresh\n", .{});
    }
}

/// Handle checkpoint list/save/restore commands
pub fn handleCheckpoint(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Default checkpoint directory
    const checkpoint_dir = ".crushcode/checkpoints";
    var mgr = checkpoint_mod.CheckpointManager.init(allocator, checkpoint_dir);

    if (args.remaining.len == 0) {
        // List checkpoints
        const checkpoints = try mgr.list();
        defer {
            for (checkpoints) |cp| allocator.free(cp);
            allocator.free(checkpoints);
        }

        if (checkpoints.len == 0) {
            stdout_print("No checkpoints found.\n", .{});
            stdout_print("Run with --checkpoint during chat to save snapshots.\n", .{});
            return;
        }

        stdout_print("Available checkpoints:\n", .{});
        for (checkpoints) |cp| {
            // Try to load checkpoint for timestamp info
            var cp_data = mgr.load(cp) catch continue;
            defer cp_data.deinit();

            stdout_print("  {s}  (timestamp: {d}, {d} messages)\n", .{
                cp,
                cp_data.timestamp,
                cp_data.messages.len,
            });
        }
    } else {
        const action = args.remaining[0];

        if (std.mem.eql(u8, action, "save")) {
            // Manual save (not typically used - auto-save happens)
            stdout_print("Checkpoints are saved automatically.\n", .{});
            stdout_print("Use --checkpoint flag during chat to enable.\n", .{});
        } else if (std.mem.eql(u8, action, "restore") or std.mem.eql(u8, action, "load")) {
            if (args.remaining.len < 2) {
                stdout_print("Error:checkpoint ID required\n", .{});
                stdout_print("Usage: crushcode checkpoint restore <id>\n", .{});
                return;
            }
            const cp_id = args.remaining[1];
            var cp = mgr.load(cp_id) catch |err| {
                stdout_print("Error loading checkpoint '{s}': {}\n", .{ cp_id, err });
                return;
            };
            defer cp.deinit();

            stdout_print("Restored checkpoint '{s}'\n", .{cp_id});
            stdout_print("  Messages: {d}\n", .{cp.messages.len});
            stdout_print("  Tool calls: {d}\n", .{cp.tool_calls});
            stdout_print("  Tokens used: {d}\n", .{cp.tokens_used});
        } else if (std.mem.eql(u8, action, "delete")) {
            if (args.remaining.len < 2) {
                stdout_print("Error: checkpoint ID required\n", .{});
                stdout_print("Usage: crushcode checkpoint delete <id>\n", .{});
                return;
            }
            const cp_id = args.remaining[1];
            mgr.delete(cp_id) catch |err| {
                stdout_print("Error deleting checkpoint '{s}': {}\n", .{ cp_id, err });
                return;
            };
            stdout_print("Deleted checkpoint '{s}'\n", .{cp_id});
        } else {
            stdout_print("Unknown checkpoint action: {s}\n", .{action});
            stdout_print("\nUsage:\n", .{});
            stdout_print("  crushcode checkpoint           List all checkpoints\n", .{});
            stdout_print("  crushcode checkpoint restore <id>  Restore a checkpoint\n", .{});
            stdout_print("  crushcode checkpoint delete <id>   Delete a checkpoint\n", .{});
        }
    }
}

pub fn printHelp() !void {
    stdout_print(
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
        \\  agents       Spawn multiple AI agents in parallel
        \\  tools         List, enable, disable, check tools
        \\  tui          Launch interactive terminal UI
        \\  install      Show installation instructions
        \\  jobs         Job control (background jobs)
        \\  capabilities   List registered tools, plugins, and skills
        \\  worktree      Show worktree manager status
        \\  graph          Analyze codebase with knowledge graph
        \\  agent-loop     Show agent loop engine status
        \\  workflow       Show phase workflow progress
        \\  compact        Show context compaction status
        \\  scaffold       Generate project scaffolding
        \\  list           List providers or models
        \\  usage         Show token usage and cost tracking
        \\  connect        Add API credentials for providers
        \\  checkpoint    List, restore, or delete checkpoints
        \\  grep           AST-grep pattern search
        \\  lsp            Language Server Protocol client
        \\  mcp            MCP tools management
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Chat Commands (in interactive mode):
        \\  /usage         Show session token usage
        \\  /clear         Clear conversation history
        \\  /hooks         Show registered lifecycle hooks
        \\  /checkpoint    Save checkpoint manually
        \\  /agents        Spawn agents for task
        \\  /exit          Exit chat
        \\
        \\Agent Categories (--agents):
        \\  visual-engineering  UI/UX, frontend, design
        \\  ultrabrain         Hard logic, architecture
        \\  deep              Autonomous research + execution
        \\  quick             Single-file changes, typos
        \\  review            Code review and QA
        \\  research          Research and exploration
        \\  general           Default category
        \\Options:
        \\  --provider <id>    Use specific AI provider
        \\  --model <id>       Use specific model
        \\  --profile <name>   Use specific profile
        \\  --config <path>    Use custom config file
        \\  --json, -j         Output JSON Lines (machine-readable)
        \\  --color <mode>     Color output: auto, always, never
        \\  --checkpoint <id>  Restore from checkpoint
        \\  --restore <id>     Restore from checkpoint (alias)
        \\  --agents <cats>    Spawn agents with categories (comma-separated)
        \\  --max-agents <n>   Max concurrent agents (default: 5)
        \\  --memory <path>   Session memory/history file
        \\  --memory-limit <n>  Max messages to remember (default: 100)
        \\  --interactive, -i  Start interactive chat
        \\  --tui, -t          Launch terminal UI
        \\  --stream, -s       Enable streaming output
        \\  --permission <mode> Permission mode: default, auto, plan, acceptEdits, dontAsk, bypassPermissions
        \\
        \\Examples:
        \\  crushcode chat
        \\  crushcode chat --provider openai --model gpt-4o
        \\  crushcode chat --profile work
        \\  crushcode chat --memory --memory-limit 50
        \\  crushcode agents --agents visual,deep,quick
        \\  crushcode agents --agents research,review --max-agents 3
        \\  crushcode read src/main.zig
        \\  crushcode shell "ls -la"
        \\  crushcode write test.txt "Hello World"
        \\  crushcode parallel
        \\  crushcode usage
        \\  crushcode worktree
        \\  crushcode list --provider openai
        \\  crushcode plugin list
        \\
    , .{});
}

pub fn handleUsage(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Initialize usage tracker and pricing
    var tracker = @import("usage_tracker").UsageTracker.init(allocator, "~/.crushcode/usage");
    defer tracker.deinit();

    var pricing = @import("usage_pricing").PricingTable.init(allocator) catch {
        stdout_print("Error initializing pricing table\n", .{});
        return;
    };
    defer pricing.deinit();

    const session = tracker.getSessionUsage();

    stdout_print("\n=== Crushcode Usage Report ===\n", .{});
    stdout_print("\nSession (current):\n", .{});
    stdout_print("  Requests: {d}\n", .{session.request_count});
    stdout_print("  Tokens: {d} in / {d} out", .{ session.input_tokens, session.output_tokens });
    if (session.cache_read_tokens > 0) {
        stdout_print(" / {d} cache read", .{session.cache_read_tokens});
    }
    stdout_print("\n", .{});

    if (session.estimated_cost_usd > 0) {
        stdout_print("  Cost: ${d:.4}\n", .{session.estimated_cost_usd});
    }

    if (session.by_provider.count() > 0) {
        stdout_print("\n  By provider:\n", .{});
        var iter = session.by_provider.iterator();
        while (iter.next()) |entry| {
            const pu = entry.value_ptr;
            stdout_print("    {s} ({s}): {d} req | ${d:.4}\n", .{
                pu.provider,
                pu.model,
                pu.request_count,
                pu.cost_usd,
            });
        }
    }

    const daily = tracker.getDailyUsage();
    var report = usage_report.UsageReport.init(allocator);
    defer report.deinit();

    var budget_status: ?usage_budget.BudgetStatus = null;
    if (loadBudgetConfig(allocator)) |budget_cfg| {
        var budget_manager = usage_budget.BudgetManager.init(allocator, budget_cfg);
        defer budget_manager.deinit();

        budget_manager.recordCost(session.estimated_cost_usd);
        budget_manager.daily_spent = daily.estimated_cost_usd;
        budget_manager.monthly_spent = daily.estimated_cost_usd;
        budget_status = budget_manager.checkBudget();

        if (budget_status) |status| {
            const state = if (status.isOverBudget())
                "over budget"
            else if (status.shouldAlert(budget_cfg.alert_threshold_pct))
                "alert"
            else
                "ok";
            stdout_print("\nBudget status: {s} ({d:.0}% used)\n", .{ state, status.percent_used * 100.0 });
        }
    }

    report.printFullReport(session, daily, budget_status);

    stdout_print("\nTip: Set budget limits in ~/.crushcode/config.toml:\n", .{});
    stdout_print("  [budget]\n", .{});
    stdout_print("  daily_limit_usd = 1.0\n", .{});
    stdout_print("  monthly_limit_usd = 50.0\n", .{});
}

pub fn handleConnect(args: args_mod.Args) !void {
    try connect_mod.handleConnect(args.remaining);
}

pub fn handleProfile(args: args_mod.Args) !void {
    try profile_mod.handleProfile(args.remaining);
}

pub fn printVersion() !void {
    stdout_print("Crushcode v0.1.0\n", .{});
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
            stdout_print("Indexing: {s}\n", .{file_path});
            kg.indexFile(file_path) catch |err| {
                stdout_print("  Error indexing {s}: {}\n", .{ file_path, err });
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
        stdout_print("Indexing default source files...\n\n", .{});
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
        stdout_print("\n--- Compressed Context Preview ---\n", .{});
        stdout_print("{s}\n", .{ctx});
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
    stdout_print("\n--- Running demo agent loop ---\n", .{});
    var result = agent.run(demoAISend, "Find information about Zig programming language") catch {
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
        phase.* = wf_mod.WorkflowPhase.init(allocator, @floatFromInt(i), name, "Phase goal") catch continue;
        if (i > 1) phase.addDependency(@floatFromInt(i - 1)) catch {};
        workflow.addPhase(phase) catch {};
    }

    // Mark completed phases
    workflow.completePhase(1.0) catch {};
    workflow.completePhase(2.0) catch {};
    workflow.completePhase(3.0) catch {};
    workflow.completePhase(4.0) catch {};
    workflow.completePhase(5.0) catch {};
    workflow.completePhase(6.0) catch {};

    if (args.remaining.len > 0 and std.mem.eql(u8, args.remaining[0], "--xml")) {
        const xml = workflow.toXml(allocator) catch return;
        defer allocator.free(xml);
        stdout_print("{s}\n", .{xml});
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
    stdout_print("\nCompaction Result:\n", .{});
    stdout_print("  Messages summarized: {d}\n", .{result.messages_summarized});
    stdout_print("  Tokens saved: {d}\n", .{result.tokens_saved});
    stdout_print("  Recent messages preserved: {d}\n", .{result.messages.len});
    if (result.summary.len > 0) {
        stdout_print("\n--- Generated Summary ---\n{s}\n", .{result.summary});
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
