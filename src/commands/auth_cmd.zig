const std = @import("std");
const file_compat = @import("file_compat");
const auth_mod = @import("auth");
const provider_oauth = @import("provider_oauth");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Handle `crushcode auth` command from CLI.
pub fn handleAuth(args: []const []const u8) !void {
    if (args.len == 0) {
        printAuthHelp();
        return;
    }

    const subcommand = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcommand, "login")) {
        if (sub_args.len == 0) {
            out("Error: provider name required\n", .{});
            out("Usage: crushcode auth login <provider>\n\n", .{});
            out("OAuth-capable providers: openrouter\n", .{});
            return;
        }
        try handleLogin(sub_args[0]);
    } else if (std.mem.eql(u8, subcommand, "status")) {
        try handleStatus();
    } else if (std.mem.eql(u8, subcommand, "logout")) {
        if (sub_args.len == 0) {
            out("Error: provider name required\n", .{});
            out("Usage: crushcode auth logout <provider>\n", .{});
            return;
        }
        try handleLogout(sub_args[0]);
    } else {
        out("Unknown auth subcommand: {s}\n", .{subcommand});
        printAuthHelp();
    }
}

fn handleLogin(provider_name: []const u8) !void {
    const allocator = std.heap.page_allocator;

    const config = provider_oauth.getConfigForProvider(provider_name) orelse {
        out("Provider '{s}' does not support OAuth.\n", .{provider_name});
        out("Use `crushcode connect` to add an API key instead.\n", .{});
        return;
    };

    out("Opening browser for {s} login...\n", .{provider_name});
    out("If the browser doesn't open, copy the URL printed below.\n\n", .{});

    var oauth = provider_oauth.ProviderOAuth.init(allocator, config);

    const result = oauth.authenticate() catch |err| {
        out("Authentication failed: {}\n", .{err});
        return;
    };

    out("\n✓ Successfully authenticated with {s}!\n", .{provider_name});
    if (result.expires_at) |ea| {
        const now = std.time.timestamp();
        const remaining = ea - now;
        if (remaining > 0) {
            const remaining_min = @divTrunc(remaining, 60);
            out("  Token expires in {d} minutes\n", .{remaining_min});
        }
    }
    out("  Token type: {s}\n", .{result.token_type});
}

fn handleStatus() !void {
    const allocator = std.heap.page_allocator;

    out("Authentication Status\n", .{});
    out("=====================\n\n", .{});

    // Show API key credentials
    var auth = auth_mod.Auth.init(allocator);
    auth.load() catch {};

    out("API Key Credentials:\n", .{});
    const providers = &[_][]const u8{ "openrouter", "anthropic", "openai", "groq", "ollama", "google", "mistral" };
    var found_any = false;
    for (providers) |prov| {
        if (auth.getKey(prov)) |key| {
            const masked = if (key.len > 8)
                try std.fmt.allocPrint(allocator, "{s}...{s}", .{ key[0..4], key[key.len - 4 ..] })
            else
                "(set)";
            defer if (key.len > 8) allocator.free(masked);
            out("  {s}:  API Key  ✓ ({s})\n", .{ prov, masked });
            found_any = true;
        }
    }
    if (!found_any) {
        out("  (none configured)\n", .{});
    }

    // Show OAuth credentials
    out("\nOAuth Credentials:\n", .{});
    var found_oauth = false;
    for (providers) |prov| {
        if (provider_oauth.getConfigForProvider(prov)) |config| {
            var oauth = provider_oauth.ProviderOAuth.init(allocator, config);
            if (oauth.getStoredTokens()) |tokens| {
                if (provider_oauth.isTokenExpired(&tokens)) {
                    out("  {s}:  OAuth    ✗ (expired)\n", .{prov});
                } else {
                    const remaining = if (tokens.expires_at) |ea| blk: {
                        const now = std.time.timestamp();
                        break :blk ea - now;
                    } else @as(i64, -1);
                    if (remaining > 0) {
                        const remaining_min = @divTrunc(remaining, 60);
                        out("  {s}:  OAuth    ✓ (expires in {d}min)\n", .{ prov, remaining_min });
                    } else {
                        out("  {s}:  OAuth    ✓\n", .{prov});
                    }
                }
                found_oauth = true;
            } else |_| {}
        }
    }
    if (!found_oauth) {
        out("  (none configured)\n", .{});
    }

    out("\nTip: Use 'crushcode auth login <provider>' for OAuth\n", .{});
    out("     Use 'crushcode connect' for API key authentication\n", .{});
}

fn handleLogout(provider_name: []const u8) !void {
    const allocator = std.heap.page_allocator;

    const config = provider_oauth.getConfigForProvider(provider_name) orelse {
        out("Provider '{s}' does not support OAuth.\n", .{provider_name});
        return;
    };

    var oauth = provider_oauth.ProviderOAuth.init(allocator, config);
    oauth.revokeTokens() catch |err| {
        out("Failed to revoke tokens: {}\n", .{err});
        return;
    };

    out("✓ Logged out from {s}\n", .{provider_name});
}

fn printAuthHelp() void {
    out(
        \\Crushcode Auth Command
        \\
        \\Usage:
        \\  crushcode auth <subcommand> [options]
        \\
        \\Subcommands:
        \\  login <provider>   Authenticate via OAuth browser flow
        \\  status             Show authentication status for all providers
        \\  logout <provider>  Remove stored OAuth tokens
        \\
        \\OAuth-capable providers:
        \\  openrouter         OpenRouter AI gateway
        \\
        \\Examples:
        \\  crushcode auth login openrouter
        \\  crushcode auth status
        \\  crushcode auth logout openrouter
        \\
        \\For API key authentication, use:
        \\  crushcode connect
        \\
    , .{});
}
