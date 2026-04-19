/// run.zig — Non-interactive single-shot command for crushcode.
///
/// Usage:
///   crushcode run "prompt" [--provider <name>] [--model <name>]
///   cat file.txt | crushcode run "summarize"
///
/// Sends a single prompt to the AI provider and outputs the raw response
/// text to stdout — suitable for piping to other commands.
const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const args_mod = @import("args");
const config_mod = @import("config");
const registry_mod = @import("registry");
const profile_mod = @import("profile");
const core = @import("core_api");
const json_output_mod = @import("json_output");
const env_mod = @import("env");

/// Maximum bytes to read from piped stdin (10 MB).
const max_stdin_size: usize = 10 * 1024 * 1024;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Detect whether stdin is a pipe (not a terminal).
fn isStdinPiped() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO) == false;
}

/// Read all content from piped stdin. Caller owns returned slice.
fn readStdin(allocator: std.mem.Allocator) !?[]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    // Read in chunks until EOF or max_stdin_size reached
    var remaining = max_stdin_size;
    while (remaining > 0) {
        const chunk = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, 0, @min(remaining, 64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                // Hit chunk limit but not EOF — keep going
                continue;
            },
            else => return err,
        };
        if (chunk) |data| {
            remaining -= data.len;
            try buf.appendSlice(data);
            allocator.free(data);
        } else {
            // EOF
            break;
        }
    }

    if (buf.items.len == 0) {
        buf.deinit();
        return null;
    }

    return @as([]const u8, try buf.toOwnedSlice());
}

/// Handle the `run` command — non-interactive single-shot AI prompt.
///
/// Reads piped stdin if available, constructs prompt, sends to AI,
/// outputs raw response to stdout.
pub fn handleRun(args: args_mod.Args, config: *config_mod.Config) !void {
    const allocator = std.heap.page_allocator;
    const json_out = json_output_mod.JsonOutput.init(args.json);

    // Validate: must have at least one remaining arg as the prompt
    if (args.remaining.len == 0) {
        out("Usage: crushcode run \"<prompt>\" [--provider <name>] [--model <name>]\n", .{});
        return;
    }

    const user_prompt = args.remaining[0];

    // ── Load profile ──────────────────────────────────────────────
    var profile_opt: ?profile_mod.Profile = null;
    if (args.profile) |profile_name| {
        profile_opt = profile_mod.loadProfileByName(allocator, profile_name) catch null;
    } else {
        profile_opt = profile_mod.loadCurrentProfile(allocator) catch null;
    }
    defer if (profile_opt) |*p| p.deinit();

    // ── Resolve provider and model ────────────────────────────────
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

    // ── Build registry and get provider ───────────────────────────
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        out("Error: Provider '{s}' not found\n", .{provider_name});
        out("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // ── Resolve API key ───────────────────────────────────────────
    var api_key: []const u8 = "";
    if (profile_opt) |*p| {
        api_key = p.getApiKey(provider_name) orelse "";
    }
    if (api_key.len == 0) {
        api_key = config.getApiKey(provider_name) orelse "";
    }

    if (api_key.len == 0) {
        if (!provider.config.is_local) {
            out("Error: No API key found for provider '{s}'. Add to ~/.crushcode/config.toml\nExample: {s} = \"your-api-key\"\n", .{ provider_name, provider_name });
            return error.MissingApiKey;
        }
    }

    // ── Read piped stdin (if any) ─────────────────────────────────
    var stdin_content: ?[]const u8 = null;
    defer {
        if (stdin_content) |c| allocator.free(c);
    }

    if (isStdinPiped()) {
        stdin_content = readStdin(allocator) catch |err| blk: {
            out("Warning: Failed to read stdin: {}\n", .{err});
            break :blk null;
        };
    }

    // ── Construct full prompt ─────────────────────────────────────
    var full_prompt: []const u8 = undefined;
    var owned_prompt: bool = false;
    defer {
        if (owned_prompt) allocator.free(full_prompt);
    }

    if (stdin_content) |content| {
        full_prompt = try std.fmt.allocPrint(allocator, "Context from stdin:\n{s}\n\nUser prompt: {s}", .{ content, user_prompt });
        owned_prompt = true;
    } else {
        full_prompt = user_prompt;
        owned_prompt = false;
    }

    // ── Initialize AI client ──────────────────────────────────────
    var ai_client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer ai_client.deinit();

    ai_client.max_tokens = config.max_tokens;
    ai_client.temperature = config.temperature;

    // ── Provider URL override ─────────────────────────────────────
    if (config.getProviderOverrideUrl(provider_name)) |override_url| {
        allocator.free(ai_client.provider.config.base_url);
        ai_client.provider.config.base_url = try allocator.dupe(u8, override_url);
    }

    // ── System prompt from config or profile ──────────────────────
    var run_sys_prompt: ?[]const u8 = null;
    if (profile_opt) |*p| {
        if (p.system_prompt.len > 0) run_sys_prompt = p.system_prompt;
    }
    if (run_sys_prompt == null) {
        run_sys_prompt = config.getSystemPrompt();
    }
    if (run_sys_prompt) |sp| {
        ai_client.setSystemPrompt(sp);
    }

    // ── Send request ──────────────────────────────────────────────
    json_out.emitSessionStart(provider_name, model_name);

    const response = ai_client.sendChat(full_prompt) catch |err| {
        out("Error sending request: {}\n", .{err});
        json_out.emitError(@errorName(err));
        return err;
    };

    if (response.choices.len == 0) {
        out("Error: Empty response from AI\n", .{});
        json_out.emitError("EmptyResponse");
        return error.EmptyResponse;
    }

    // ── Output raw response to stdout ─────────────────────────────
    const content = response.choices[0].message.content orelse "";
    const stdout = file_compat.File.stdout().writer();
    stdout.print("{s}\n", .{content}) catch {};

    json_out.emitAssistant(content);

    if (response.usage) |usage| {
        json_out.emitUsage(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    }

    json_out.emitSessionEnd();
}
