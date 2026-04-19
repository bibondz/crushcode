const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const args_mod = @import("args");
const config_mod = @import("config");
const registry_mod = @import("registry");
const profile_mod = @import("profile");
const core = @import("core_api");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Parse `--output-dir <dir>` from the remaining args slice.
/// Returns the directory path or null if not found.
/// Skips the prompts file argument (first non-flag token before any flags).
fn findOutputDir(remaining: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < remaining.len) : (i += 1) {
        if (std.mem.eql(u8, remaining[i], "--output-dir")) {
            if (i + 1 < remaining.len) {
                return remaining[i + 1];
            }
        }
    }
    return null;
}

/// Parse `--stop-on-error` flag from the remaining args slice.
fn hasStopOnError(remaining: []const []const u8) bool {
    for (remaining) |arg| {
        if (std.mem.eql(u8, arg, "--stop-on-error")) {
            return true;
        }
    }
    return false;
}

/// Find the prompts file path from remaining args.
/// It's the first arg that doesn't start with `--` and isn't a value for a flag.
fn findPromptsFile(remaining: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < remaining.len) : (i += 1) {
        if (std.mem.eql(u8, remaining[i], "--output-dir")) {
            // Skip the next arg (the dir value)
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, remaining[i], "--")) {
            continue;
        }
        return remaining[i];
    }
    return null;
}

/// Read prompts from a file. Returns an allocated slice of prompt strings.
/// Caller owns the returned slice and each string — free with freePrompts.
fn readPromptsFromFile(allocator: std.mem.Allocator, file_path: []const u8) ![][]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        out("Error: Cannot open prompts file '{s}': {}\n", .{ file_path, err });
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const content = buffer[0..bytes_read];

    var prompts = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (prompts.items) |p| allocator.free(p);
        prompts.deinit();
    }

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        const prompt_copy = try allocator.dupe(u8, trimmed);
        try prompts.append(prompt_copy);
    }

    return prompts.toOwnedSlice();
}

/// Free prompts array and each prompt string.
fn freePrompts(allocator: std.mem.Allocator, prompts: [][]const u8) void {
    for (prompts) |p| {
        allocator.free(p);
    }
    allocator.free(prompts);
}

pub fn handleBatch(args: args_mod.Args, config: *config_mod.Config) !void {
    const allocator = std.heap.page_allocator;

    // Find prompts file from remaining args
    const prompts_file = findPromptsFile(args.remaining) orelse {
        out("Usage: crushcode batch <prompts_file> [--output-dir <dir>] [--stop-on-error]\n", .{});
        return;
    };

    const output_dir = findOutputDir(args.remaining);
    const stop_on_error = hasStopOnError(args.remaining);

    // Read prompts from file
    const prompts = readPromptsFromFile(allocator, prompts_file) catch |err| {
        out("Error: Failed to read prompts file: {}\n", .{err});
        return err;
    };
    defer freePrompts(allocator, prompts);

    if (prompts.len == 0) {
        out("Error: No prompts found in '{s}'\n", .{prompts_file});
        return;
    }

    // Load profile
    var profile_opt: ?profile_mod.Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    // Resolve provider and model
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

    // Initialize provider registry
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        out("Error: Provider '{s}' not found\n", .{provider_name});
        out("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // Resolve API key
    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(provider_name) orelse "";
    }

    if (api_key.len == 0 and !provider.config.is_local) {
        out("Error: No API key found for provider '{s}'. Add to ~/.crushcode/config.toml\n", .{provider_name});
        return error.MissingApiKey;
    }

    // Initialize AI client
    var client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    client.max_tokens = config.max_tokens;
    client.temperature = config.temperature;

    // Apply provider override URL if configured
    if (config.getProviderOverrideUrl(provider_name)) |override_url| {
        allocator.free(client.provider.config.base_url);
        client.provider.config.base_url = try allocator.dupe(u8, override_url);
    }

    // Set system prompt
    var batch_sys_prompt: ?[]const u8 = null;
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) batch_sys_prompt = p.system_prompt;
    }
    if (batch_sys_prompt == null) {
        batch_sys_prompt = config.getSystemPrompt();
    }
    if (batch_sys_prompt) |sp| {
        client.setSystemPrompt(sp);
    }

    // Create output directory if specified
    if (output_dir) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            out("Error: Cannot create output directory '{s}': {}\n", .{ dir, err });
            return err;
        };
    }

    // Process each prompt
    out("Batch processing {d} prompts via {s} ({s})\n\n", .{ prompts.len, provider_name, model_name });

    var success_count: usize = 0;
    var error_count: usize = 0;

    for (prompts, 0..) |prompt, idx| {
        const prompt_num = idx + 1;

        // Print delimiter
        out("\n=== Prompt {d}/{d} ===\n{s}\n---\n", .{ prompt_num, prompts.len, prompt });

        // Send to AI
        const response = client.sendChat(prompt) catch |err| {
            out("Error processing prompt {d}: {}\n", .{ prompt_num, err });
            error_count += 1;
            if (stop_on_error) {
                out("\nStopping due to error (--stop-on-error)\n", .{});
                break;
            }
            continue;
        };

        if (response.choices.len == 0) {
            out("Error: Empty response for prompt {d}\n", .{prompt_num});
            error_count += 1;
            if (stop_on_error) {
                out("\nStopping due to error (--stop-on-error)\n", .{});
                break;
            }
            continue;
        }

        const content = response.choices[0].message.content orelse "";
        out("{s}\n", .{content});
        success_count += 1;

        // Write to file if output dir specified
        if (output_dir) |dir| {
            const file_path = std.fmt.allocPrint(allocator, "{s}/prompt_{d}.txt", .{ dir, prompt_num }) catch |err| {
                out("Warning: Cannot create file path for prompt {d}: {}\n", .{ prompt_num, err });
                continue;
            };
            defer allocator.free(file_path);

            const outfile = std.fs.cwd().createFile(file_path, .{}) catch |err| {
                out("Warning: Cannot create file '{s}': {}\n", .{ file_path, err });
                continue;
            };
            outfile.writeAll(content) catch |err| {
                out("Warning: Cannot write to file '{s}': {}\n", .{ file_path, err });
            };
            outfile.close();
        }
    }

    // Print summary
    out("\n=== Summary ===\n", .{});
    out("Processed {d}/{d} prompts ({d} errors)\n", .{ success_count + error_count, prompts.len, error_count });
}
