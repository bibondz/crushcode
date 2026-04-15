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
    }) catch {
        // Any TUI initialization failure (no /dev/tty, no TTY, vaxis error, etc.)
        // falls back to interactive chat mode. This handles WSL and headless environments.
        stdout_print("Terminal UI not available. Falling back to interactive chat.\n\n", .{});
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
    };
}

pub fn handleFallback(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Load config to get real API keys
    var config = config_mod.loadOrCreateConfig(allocator) catch {
        stdout_print("Error: Could not load configuration.\n", .{});
        return;
    };
    defer config.deinit();

    var reg = registry_mod.ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerAllProviders();

    // Build fallback chain from providers that have API keys configured
    var chain = fallback_mod.FallbackChain.init(allocator);
    defer chain.deinit();

    const provider_names = try reg.listProviders();
    defer allocator.free(provider_names);

    for (provider_names) |name| {
        const api_key = config.getApiKey(name) orelse "";
        const is_local = if (reg.getProvider(name)) |p| p.config.is_local else false;
        // Only add providers that have a real API key or are local
        if (api_key.len > 0 or is_local) {
            const provider = reg.getProvider(name) orelse continue;
            const model = if (provider.config.models.len > 0) provider.config.models[0] else "default";
            try chain.addEntry(name, model);
        }
    }

    if (chain.isEmpty()) {
        stdout_print("No configured providers found. Run 'crushcode connect' to set up a provider.\n", .{});
        return;
    }

    stdout_print("\n=== Fallback Chain Connectivity Test ===\n\n", .{});
    chain.printChain();
    stdout_print("\nTesting connectivity:\n", .{});
    stdout_print("  PROVIDER             MODEL                             STATUS       DETAILS\n", .{});
    stdout_print("  --------             -----                             ------       -------\n", .{});

    const entries = chain.getEntries();
    for (entries, 1..) |entry, index| {
        const provider = reg.getProvider(entry.provider);
        if (provider == null) {
            stdout_print("  {d}. {s} / {s}: unknown — Provider not registered\n", .{ index, entry.provider, entry.model });
            continue;
        }

        const prov = provider.?;
        const api_key = config.getApiKey(entry.provider) orelse "";

        // Attempt real connectivity test — send a tiny prompt
        const test_result: struct { status: []const u8, detail: []const u8 } = blk: {
            if (api_key.len == 0 and !prov.config.is_local) {
                break :blk .{ .status = "no key", .detail = "No API key configured" };
            }

            var client = core_api.AIClient.init(allocator, prov, entry.model, api_key) catch |err| {
                const detail = std.fmt.allocPrint(allocator, "Init failed: {any}", .{err}) catch "Init failed";
                break :blk .{ .status = "error", .detail = detail };
            };
            defer client.deinit();

            // Send a minimal test message
            const response = client.sendChat("Reply with exactly: ok") catch |err| {
                const detail = std.fmt.allocPrint(allocator, "{any}", .{err}) catch "Connection failed";
                break :blk .{ .status = "failed", .detail = detail };
            };

            const has_content = response.choices.len > 0;
            const detail: []const u8 = if (has_content) "Connected successfully" else "Empty response";
            break :blk .{ .status = "ok", .detail = detail };
        };

        stdout_print("  {d}. {s}/{s}: {s} — {s}\n", .{ index, entry.provider, entry.model, test_result.status, test_result.detail });
    }

    stdout_print("\n  Chain entries: {d} | Primary: ", .{chain.count()});
    if (chain.getPrimary()) |primary| {
        stdout_print("{s}/{s}\n", .{ primary.provider, primary.model });
    } else {
        stdout_print("(none)\n", .{});
    }
}

pub fn handleParallel(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Load config for real API keys
    var config = config_mod.loadOrCreateConfig(allocator) catch {
        stdout_print("Error: Could not load configuration.\n", .{});
        return;
    };
    defer config.deinit();

    var reg = registry_mod.ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerAllProviders();

    // Collect providers that have API keys configured
    var configured = array_list_compat.ArrayList(struct { name: []const u8, model: []const u8, api_key: []const u8 }).init(allocator);
    defer configured.deinit();

    const provider_names = try reg.listProviders();
    defer allocator.free(provider_names);

    for (provider_names) |name| {
        const api_key = config.getApiKey(name) orelse "";
        const is_local = if (reg.getProvider(name)) |p| p.config.is_local else false;
        if (api_key.len > 0 or is_local) {
            const provider = reg.getProvider(name) orelse continue;
            const model = if (provider.config.models.len > 0) provider.config.models[0] else "default";
            try configured.append(.{ .name = name, .model = model, .api_key = api_key });
        }
    }

    if (configured.items.len == 0) {
        stdout_print("No configured providers found. Run 'crushcode connect' to set up.\n", .{});
        return;
    }

    const max_concurrent: u32 = if (configured.items.len > 3) 3 else @intCast(configured.items.len);
    var executor = parallel_mod.ParallelExecutor.init(allocator, max_concurrent);
    defer executor.deinit();

    // Submit real tasks to each configured provider
    const prompts = [_][]const u8{
        "In one sentence, describe the purpose of AI coding assistants.",
        "In one sentence, explain what makes a good programming language.",
        "In one sentence, describe the benefits of open source software.",
    };

    stdout_print("\n=== Parallel Execution Demo ===\n", .{});
    stdout_print("Submitting {d} tasks across {d} providers (max {d} concurrent)...\n\n", .{ configured.items.len, configured.items.len, max_concurrent });

    var submitted: usize = 0;
    for (configured.items, 0..) |prov, i| {
        const prompt = prompts[i % prompts.len];
        const task_id = executor.submit(prompt, prov.name, prov.model, prov.api_key, .general) catch |err| {
            stdout_print("  Failed to submit to {s}/{s}: {}\n", .{ prov.name, prov.model, err });
            continue;
        };
        defer allocator.free(task_id);
        stdout_print("  Submitted: {s} ({s}/{s})\n", .{ prompt[0..@min(prompt.len, 50)], prov.name, prov.model });
        submitted += 1;
    }

    if (submitted == 0) {
        stdout_print("No tasks were submitted.\n", .{});
        return;
    }

    stdout_print("\nWaiting for tasks to complete...\n", .{});
    executor.waitForAll();
    executor.reapCompleted();

    // Print real executor status
    executor.printStatus();
    executor.printSummary();

    stdout_print("\n  Can accept more tasks: {s}\n", .{if (executor.canAcceptMore()) "yes" else "no"});
    stdout_print("  Completed results: {d}\n", .{executor.getResults().len});
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

    // Load config for real API keys
    var config = config_mod.loadOrCreateConfig(allocator) catch {
        stdout_print("Error: Could not load configuration.\n", .{});
        return;
    };
    defer config.deinit();

    var reg = registry_mod.ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerAllProviders();

    // Determine provider/model/api_key from config
    const provider_name = blk: {
        if (config.default_provider.len > 0) break :blk config.default_provider;
        // Fallback to first provider with an API key
        const names = try reg.listProviders();
        defer allocator.free(names);
        for (names) |name| {
            const key = config.getApiKey(name) orelse "";
            if (key.len > 0) break :blk name;
        }
        break :blk "";
    };

    if (provider_name.len == 0) {
        stdout_print("Error: No provider configured. Run 'crushcode connect' to set up.\n", .{});
        return;
    }

    const api_key = config.getApiKey(provider_name) orelse "";
    const is_local = if (reg.getProvider(provider_name)) |p| p.config.is_local else false;
    if (api_key.len == 0 and !is_local) {
        stdout_print("Error: No API key for '{s}'. Run 'crushcode connect {s}' to configure.\n", .{ provider_name, provider_name });
        return;
    }

    const model_name = blk: {
        if (config.default_model.len > 0) break :blk config.default_model;
        const provider = reg.getProvider(provider_name) orelse break :blk "default";
        if (provider.config.models.len > 0) break :blk provider.config.models[0];
        break :blk "default";
    };

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

    stdout_print("\n=== Multi-Agent Spawner ===\n", .{});
    stdout_print("Provider: {s} | Model: {s} | Max concurrent: {d}\n\n", .{ provider_name, model_name, max_concurrent });

    for (categories.items) |cat| {
        const task_desc = switch (cat) {
            .visual_engineering => "Review and improve UI components",
            .ultrabrain => "Analyze complex architecture decisions",
            .deep => "Research and implement feature end-to-end",
            .quick => "Fix simple issues and typos",
            .general => "Handle general purpose tasks",
            .review => "Perform code review and QA",
            .research => "Research patterns and documentation",
        };

        const task_id = executor.submit(task_desc, provider_name, model_name, api_key, cat) catch |err| {
            stdout_print("  Failed to spawn {s} agent: {}\n", .{ @tagName(cat), err });
            continue;
        };
        defer allocator.free(task_id);
        stdout_print("  Spawned: {s} — {s} ({s}/{s})\n", .{ @tagName(cat), task_desc, provider_name, model_name });
    }

    stdout_print("\nTotal agents spawned: {d}\n", .{categories.items.len});
    stdout_print("Max concurrent: {d}\n", .{max_concurrent});
    stdout_print("\nWaiting for all agents to complete...\n", .{});

    executor.waitForAll();
    executor.reapCompleted();

    executor.printStatus();
    executor.printSummary();
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
