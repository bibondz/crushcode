const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const chat_mod = @import("chat");
const tui_mod = @import("tui");
const fallback_mod = @import("fallback");
const parallel_mod = @import("parallel");
const core_api = @import("core_api");
const connect_mod = @import("connect");
const profile_mod = @import("profile");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleTUI(args: args_mod.Args, config: *config_mod.Config) !void {
    const allocator = std.heap.page_allocator;

    var profile_opt: ?profile_mod.Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    const provider_name = if (profile_opt) |*p| p.default_provider else config.default_provider;
    const model_name = if (profile_opt) |*p| p.default_model else config.default_model;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        stdout_print("Error: Provider '{s}' not found\n", .{provider_name});
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
        stdout_print("Error: No API key for provider '{s}'. Add to ~/.crushcode/config.toml or profile\n", .{provider_name});
        return error.MissingApiKey;
    }

    var client = try core_api.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) {
            client.setSystemPrompt(p.system_prompt);
        }
    } else if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    tui_mod.runTUIWithClient(allocator, &client) catch |err| switch (err) {
        error.NotATerminal => {
            stdout_print("Terminal UI not available (no TTY). Falling back to interactive chat.\n\n", .{});
            const fallback_args = args_mod.Args{
                .command = "",
                .provider = args.provider,
                .model = args.model,
                .profile = args.profile,
                .config_file = args.config_file,
                .interactive = true,
                .tui = false,
                .json = false,
                .color = null,
                .checkpoint = null,
                .restore = null,
                .agents = null,
                .max_agents = 5,
                .memory = null,
                .memory_limit = 100,
                .stream = false,
                .show_thinking = false,
                .permission = null,
                .intensity = null,
                .remaining = &.{},
                .has_command = true,
            };
            try chat_mod.handleChat(fallback_args, config);
        },
        else => return err,
    };
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

pub fn handleAgents(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const agents_str = args.agents orelse {
        stdout_print("Usage: crushcode agents --agents <categories>\n", .{});
        stdout_print("Categories: visual-engineering, ultrabrain, deep, quick, review, research, general\n", .{});
        stdout_print("Example: crushcode agents --agents visual,deep,quick\n", .{});
        return;
    };

    const max_concurrent = args.max_agents;

    var executor = parallel_mod.ParallelExecutor.init(allocator, max_concurrent);
    defer executor.deinit();

    var categories = array_list_compat.ArrayList(parallel_mod.AgentCategory).init(allocator);
    defer categories.deinit();

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
        stdout_print("Spawned agent: {s} ({s}/{s})\n", .{ @tagName(cat), default_provider, default_model });
        allocator.free(task_id);
    }

    stdout_print("\nTotal agents spawned: {d}\n", .{categories.items.len});
    stdout_print("Max concurrent: {d}\n", .{max_concurrent});
    stdout_print("\nUse 'crushcode parallel' to see status\n", .{});
}

pub fn handleConnect(args: args_mod.Args) !void {
    try connect_mod.handleConnect(args.remaining);
}

pub fn handleFetchModels(args: args_mod.Args, config: *config_mod.Config) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode fetch-models <provider>\n\n", .{});
        stdout_print("Fetch live model list from a provider's API.\n", .{});
        stdout_print("Requires API key in config.toml or profile.\n\n", .{});
        stdout_print("Examples:\n", .{});
        stdout_print("  crushcode fetch-models zai\n", .{});
        stdout_print("  crushcode fetch-models openrouter\n", .{});
        stdout_print("  crushcode fetch-models groq\n", .{});
        return;
    }

    const provider_name = args.remaining[0];

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        stdout_print("Error: Provider '{s}' not found. Run 'crushcode list' to see available providers.\n", .{provider_name});
        return;
    };

    var api_key: []const u8 = "";
    var profile_opt: ?profile_mod.Profile = profile_mod.loadCurrentProfile(allocator) catch null;
    defer if (profile_opt) |*p| p.deinit();
    if (profile_opt) |*p| {
        api_key = p.getApiKey(provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(provider_name) orelse "";
    }

    if (api_key.len == 0 and !provider.config.is_local) {
        stdout_print("Error: No API key for '{s}'. Add to ~/.crushcode/config.toml or run 'crushcode connect {s}'\n", .{ provider_name, provider_name });
        return;
    }

    stdout_print("Fetching models from {s}...\n\n", .{provider_name});

    const models = registry.fetchModels(provider_name, api_key) catch |err| {
        stdout_print("Error fetching models: {}\n", .{err});
        return;
    };
    defer {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }

    if (models.len == 0) {
        stdout_print("No models found.\n", .{});
        return;
    }

    stdout_print("Live Models for {s} ({d} total):\n\n", .{ provider_name, models.len });
    for (models, 0..) |model, i| {
        stdout_print("  {d}. {s}\n", .{ i + 1, model });
    }
}
