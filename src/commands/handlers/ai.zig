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

    const provider_name = blk: {
        if (profile_opt) |*p| {
            if (p.default_provider.len > 0) break :blk p.default_provider;
        }
        break :blk config.default_provider;
    };
    const model_name = blk: {
        if (profile_opt) |*p| {
            if (p.default_model.len > 0) break :blk p.default_model;
        }
        break :blk config.default_model;
    };

    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(provider_name) orelse "";
    }

    const system_prompt = blk: {
        if (profile_opt) |*p| {
            if (p.system_prompt.len > 0) break :blk p.system_prompt;
        }
        break :blk config.getSystemPrompt();
    };

    tui_mod.chat_tui_app.runWithOptions(allocator, .{
        .provider_name = provider_name,
        .model_name = model_name,
        .api_key = api_key,
        .system_prompt = system_prompt,
        .max_tokens = config.max_tokens,
        .temperature = config.temperature,
        .override_url = config.getProviderOverrideUrl(provider_name),
    }) catch |err| switch (err) {
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

    const task_one = try executor.submit("Summarize repository status", "openrouter", "openai/gpt-5.4", "", .research);
    defer allocator.free(task_one);

    const task_two = try executor.submit("Review modified files", "anthropic", "claude-3.5-sonnet", "", .review);
    defer allocator.free(task_two);

    const task_three = try executor.submit("Prepare follow-up notes", "ollama", "llama3", "", .quick);
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

        const task_id = try executor.submit(task_desc, default_provider, default_model, "", cat);
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

fn runFirstTimeSetup(allocator: std.mem.Allocator, config: *config_mod.Config) !void {
    const stdout = file_compat.File.stdout().writer();
    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    stdout.print(
        \\
        \\╔══════════════════════════════════════════╗
        \\║       Crushcode v0.7.0 — First Setup     ║
        \\╚══════════════════════════════════════════╝
        \\
        \\Welcome! Let's configure your default AI provider.
        \\
    , .{}) catch {};

    const popular = [_][]const u8{ "zai", "openrouter", "openai", "anthropic", "deepseek", "gemini", "xai", "mistral", "groq", "ollama" };
    const needs_key = [_]bool{ true, true, true, true, true, true, true, true, true, false };

    stdout.print("Providers:\n\n", .{}) catch {};
    for (popular, 1..) |name, i| {
        const key_note: []const u8 = if (needs_key[i - 1]) "" else "(local)";
        stdout_print("  {d:2}. {s} {s}\n", .{ i, name, key_note });
    }
    stdout_print("\n  Or type any provider name (together, azure, vertexai, bedrock, etc.)\n", .{});

    stdout.print("\nChoose provider [1-10 or name]: ", .{}) catch {};
    const line = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256) catch {
        stdout_print("\nSetup cancelled.\n", .{});
        return;
    };
    if (line) |input| {
        defer allocator.free(input);
        const choice = std.mem.trim(u8, input, " \t\r\n");
        if (choice.len == 0 or std.mem.eql(u8, choice, "q") or std.mem.eql(u8, choice, "quit") or std.mem.eql(u8, choice, "exit")) {
            stdout_print("Setup cancelled.\n", .{});
            return;
        }

        var provider_name: []const u8 = choice;
        inline for (popular, 1..) |name, idx| {
            if (idx == std.fmt.parseInt(u8, choice, 10) catch 0) {
                provider_name = name;
            }
        }

        var registry = registry_mod.ProviderRegistry.init(allocator);
        defer registry.deinit();
        try registry.registerAllProviders();

        if (registry.getProvider(provider_name) == null) {
            stdout_print("\nUnknown provider '{s}'.\nRun 'crushcode list --providers' to see available providers.\n", .{provider_name});
            return;
        }

        var api_key_buf: [512]u8 = undefined;
        var api_key: []const u8 = "";

        const is_local = std.mem.eql(u8, provider_name, "ollama") or
            std.mem.eql(u8, provider_name, "lm_studio") or
            std.mem.eql(u8, provider_name, "llama_cpp");

        if (!is_local) {
            const existing = config.getApiKey(provider_name) orelse "";
            const has_real_key = existing.len > 0 and !std.mem.startsWith(u8, existing, "sk-your") and !std.mem.startsWith(u8, existing, "xai-your") and !std.mem.startsWith(u8, existing, "gsk_your") and !std.mem.startsWith(u8, existing, "AIzaSy") and !std.mem.startsWith(u8, existing, "your-");

            api_key = blk: {
                if (has_real_key) {
                    stdout_print("\nAPI key for {s} already configured.\n", .{provider_name});
                    stdout_print("Press Enter to keep it, or type a new key: ", .{});
                    const key_input = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 512) catch {
                        break :blk existing;
                    };
                    if (key_input) |ki| {
                        defer allocator.free(ki);
                        const trimmed = std.mem.trim(u8, ki, " \t\r\n");
                        if (trimmed.len > 0) {
                            @memcpy(api_key_buf[0..trimmed.len], trimmed);
                            break :blk api_key_buf[0..trimmed.len];
                        } else {
                            break :blk existing;
                        }
                    } else {
                        break :blk existing;
                    }
                } else {
                    stdout_print("\nEnter API key for {s}: ", .{provider_name});
                    const key_input = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 512) catch {
                        break :blk "";
                    };
                    if (key_input) |ki| {
                        defer allocator.free(ki);
                        const trimmed = std.mem.trim(u8, ki, " \t\r\n");
                        if (trimmed.len > 0) {
                            @memcpy(api_key_buf[0..trimmed.len], trimmed);
                            break :blk api_key_buf[0..trimmed.len];
                        } else {
                            break :blk "";
                        }
                    } else {
                        break :blk "";
                    }
                }
            };
        }

        if (!is_local and api_key.len == 0) {
            stdout_print("\nNo API key provided. Setup cancelled.\n", .{});
            return;
        }

        if (api_key.len > 0) {
            try config.setApiKey(provider_name, api_key);
        }

        var default_model_buf: [256]u8 = undefined;
        var default_model_len: usize = 0;
        default_model_len = blk: {
            stdout_print("\nFetching models from {s}...\n", .{provider_name});
            const models = registry.fetchModels(provider_name, api_key) catch {
                stdout_print("Could not fetch models — skipping model selection.\n", .{});
                break :blk 0;
            };
            defer {
                for (models) |m| allocator.free(m);
                allocator.free(models);
            }
            if (models.len > 0) {
                stdout_print("\nAvailable models:\n\n", .{});
                for (models, 1..) |m, i| {
                    stdout_print("  {d}. {s}\n", .{ i, m });
                }
                stdout_print("\nChoose model [1-{d}] or press Enter for first: ", .{models.len});
                const model_input = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256) catch {
                    @memcpy(default_model_buf[0..models[0].len], models[0]);
                    break :blk models[0].len;
                };
                if (model_input) |mi| {
                    defer allocator.free(mi);
                    const trimmed = std.mem.trim(u8, mi, " \t\r\n");
                    if (trimmed.len == 0) {
                        @memcpy(default_model_buf[0..models[0].len], models[0]);
                        break :blk models[0].len;
                    }
                    const num = std.fmt.parseInt(usize, trimmed, 10) catch 0;
                    const chosen = if (num >= 1 and num <= models.len) models[num - 1] else models[0];
                    @memcpy(default_model_buf[0..chosen.len], chosen);
                    break :blk chosen.len;
                } else {
                    @memcpy(default_model_buf[0..models[0].len], models[0]);
                    break :blk models[0].len;
                }
            }
            break :blk 0;
        };

        config.default_provider = try allocator.dupe(u8, provider_name);
        if (default_model_len > 0) {
            config.default_model = try allocator.dupe(u8, default_model_buf[0..default_model_len]);
        } else {
            config.default_model = try allocator.dupe(u8, "");
        }

        const config_path = config_mod.getConfigPath(allocator) catch {
            stdout_print("\nConfigured {s} as default provider.\n", .{provider_name});
            return;
        };
        defer allocator.free(config_path);

        var config_content = array_list_compat.ArrayList(u8).init(allocator);
        defer config_content.deinit();
        const w = config_content.writer();

        try w.print("# Crushcode Configuration\n\n", .{});
        try w.print("default_provider = \"{s}\"\n", .{provider_name});
        if (config.default_model.len > 0) {
            try w.print("default_model = \"{s}\"\n", .{config.default_model});
        }
        try w.print("\n[api_keys]\n", .{});

        var key_iter = config.api_keys.iterator();
        while (key_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len == 0) continue;
            var is_valid = true;
            for (key) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') {
                    is_valid = false;
                    break;
                }
            }
            if (!is_valid) continue;
            try w.print("{s} = \"{s}\"\n", .{ key, entry.value_ptr.* });
        }

        const config_dir = std.fs.path.dirname(config_path) orelse "";
        std.fs.cwd().makePath(config_dir) catch {};
        const file = std.fs.cwd().createFile(config_path, .{}) catch {
            stdout_print("\nConfigured {s} as default provider.\n", .{provider_name});
            return;
        };
        defer file.close();
        file.writeAll(config_content.items) catch {};

        stdout_print(
            \\
            \\✓ Setup complete!
            \\
            \\  Provider: {s}
            \\  Config:   {s}
            \\
            \\Quick start:
            \\  crushcode chat "hello"           — send a message
            \\  crushcode chat                    — interactive mode
            \\  crushcode fetch-models {s}        — list available models
            \\
        , .{ provider_name, config_path, provider_name });
    } else {
        stdout_print("Setup cancelled.\n", .{});
    }
}
