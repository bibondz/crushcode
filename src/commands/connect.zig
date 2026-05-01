const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}
const Auth = @import("auth").Auth;
const config_mod = @import("config");

/// Provider info for interactive selection
const ProviderInfo = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

/// List of providers available for connection
const PROVIDERS = &[_]ProviderInfo{
    .{ .id = "openai", .name = "OpenAI", .description = "GPT-4, GPT-4o, GPT-3.5 models" },
    .{ .id = "anthropic", .name = "Anthropic", .description = "Claude 3.5 Sonnet, Claude 3 Opus" },
    .{ .id = "openrouter", .name = "OpenRouter", .description = "Access to 100+ models" },
    .{ .id = "groq", .name = "Groq", .description = "Fast inference with Llama, Mixtral" },
    .{ .id = "deepseek", .name = "DeepSeek", .description = "DeepSeek Coder, DeepSeek Chat" },
    .{ .id = "ollama", .name = "Ollama", .description = "Local models (llama2, mistral, etc.)" },
    .{ .id = "opencode-go", .name = "OpenCode Go", .description = "Low-cost subscription models" },
    .{ .id = "opencode-zen", .name = "OpenCode Zen", .description = "Tested and verified models" },
    .{ .id = "gemini", .name = "Google Gemini", .description = "Gemini Pro, Gemini Flash" },
    .{ .id = "xai", .name = "xAI", .description = "Grok models" },
    .{ .id = "mistral", .name = "Mistral", .description = "Mistral Large, Mistral Small" },
    .{ .id = "together", .name = "Together AI", .description = "Llama, Mistral, Qwen models" },
    .{ .id = "zai", .name = "Z.AI", .description = "GLM models from Z.AI" },
};

/// Print provider list for selection
fn printProviders() void {
    out("\nAvailable Providers:\n\n", .{});
    for (PROVIDERS, 0..) |p, i| {
        out("  {d}. {s} - {s}\n", .{ i + 1, p.name, p.description });
    }
    out("\n", .{});
}

/// Get provider by index
fn getProviderByIndex(idx: usize) ?ProviderInfo {
    if (idx == 0 or idx > PROVIDERS.len) return null;
    return PROVIDERS[idx - 1];
}

/// Read line from stdin
fn readLine(allocator: std.mem.Allocator) ![]const u8 {
    const stdin = file_compat.File.stdin();
    const reader = stdin.reader();

    var line = array_list_compat.ArrayList(u8).init(allocator);
    errdefer line.deinit();

    while (true) {
        const byte = reader.readByte() catch break;
        if (byte == '\n') break;
        if (byte != '\r') try line.append(byte);
    }

    return line.toOwnedSlice();
}

/// Prompt for selection
fn promptSelection() !usize {
    const stdin = file_compat.File.stdin();
    const reader = stdin.reader();

    out("Enter provider number (1-{}): ", .{PROVIDERS.len});

    var num_str = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    defer num_str.deinit();

    while (true) {
        const byte = reader.readByte() catch break;
        if (byte == '\n') break;
        if (byte != '\r') try num_str.append(byte);
    }

    if (num_str.items.len == 0) return error.NoInput;

    return std.fmt.parseInt(usize, num_str.items, 10);
}

/// Prompt for API key
fn promptApiKey() ![]const u8 {
    const stdin = file_compat.File.stdin();
    const reader = stdin.reader();

    out("Enter API key: ", .{});

    var key = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    errdefer key.deinit();

    while (true) {
        const byte = reader.readByte() catch break;
        if (byte == '\n') break;
        if (byte != '\r') try key.append(byte);
    }

    if (key.items.len == 0) return error.NoInput;

    return key.toOwnedSlice();
}

/// Prompt to set as default
fn promptSetDefault() !bool {
    const stdin = file_compat.File.stdin();
    const reader = stdin.reader();

    out("Set as default provider? (y/N): ", .{});

    var response = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    defer response.deinit();

    while (true) {
        const byte = reader.readByte() catch break;
        if (byte == '\n') break;
        if (byte != '\r') try response.append(byte);
    }

    if (response.items.len == 0) return false;
    const trimmed = std.mem.trim(u8, response.items, " \t");
    return std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y");
}

/// Handle connect command
pub fn handleConnect(args: []const []const u8) !void {
    _ = args;

    const allocator = std.heap.page_allocator;

    out("\n=== Crushcode Connect ===\n", .{});
    out("Add API credentials for AI providers\n\n", .{});

    // Load existing auth if any
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.load() catch {};

    // Show existing credentials
    const existing = auth.listProviders();
    if (existing.len > 0) {
        out("Existing credentials:\n", .{});
        for (existing) |p| {
            out("  - {s}\n", .{p});
        }
        out("\n", .{});
    }

    // Show provider list
    printProviders();

    // Get selection
    const idx = promptSelection() catch {
        out("Invalid input\n", .{});
        return;
    };

    const provider = getProviderByIndex(idx) orelse {
        out("Invalid selection\n", .{});
        return;
    };

    out("\nSelected: {s}\n", .{provider.name});

    // Check if already has credential
    if (auth.getKey(provider.id)) |existing_key| {
        out("Provider '{s}' already has credentials\n", .{provider.name});
        out("Replace with new key? (y/N): ", .{});

        const stdin = file_compat.File.stdin();
        const reader = stdin.reader();
        var response = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
        defer response.deinit();

        while (true) {
            const byte = reader.readByte() catch break;
            if (byte == '\n') break;
            if (byte != '\r') try response.append(byte);
        }

        const trimmed = std.mem.trim(u8, response.items, " \t");
        if (!std.mem.eql(u8, trimmed, "y") and !std.mem.eql(u8, trimmed, "Y")) {
            out("Cancelled\n", .{});
            return;
        }
        _ = existing_key;
    }

    // Prompt for API key
    const api_key = promptApiKey() catch {
        out("Error reading API key\n", .{});
        return;
    };

    // Save credential
    try auth.setKey(provider.id, api_key);
    try auth.save();

    out("\nCredential saved for {s}\n", .{provider.name});

    // Optionally set as default
    const set_default = promptSetDefault() catch false;
    if (set_default) {
        try setDefaultProvider(provider.id);
        out("Set '{s}' as default provider\n", .{provider.name});
    }

    out("\nDone! Run 'crushcode list --models {s}' to see available models\n", .{provider.id});
}

// ---------------------------------------------------------------------------
// Tests: Provider list and access helpers (pure logic)
// ---------------------------------------------------------------------------
test "Providers list length" {
    const testing = @import("std").testing;
    try testing.expect(PROVIDERS.len == 13);
}

test "Provider index 1: openai" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(1);
    if (p) |pp| {
        try testing.expect(std.mem.eql(u8, pp.id, "openai"));
    } else {
        try testing.expect(false);
    }
}

test "Provider index 3: groq" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(3);
    if (p) |pp| {
        try testing.expect(std.mem.eql(u8, pp.id, "groq"));
        try testing.expect(std.mem.eql(u8, pp.name, "Groq"));
    } else {
        try testing.expect(false);
    }
}

test "Provider index 13: zai" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(13);
    if (p) |pp| {
        try testing.expect(std.mem.eql(u8, pp.id, "zai"));
        try testing.expect(std.mem.eql(u8, pp.name, "Z.AI"));
    } else {
        try testing.expect(false);
    }
}

test "Provider index 0: null" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(0);
    try testing.expect(p == null);
}

test "Provider index out of range: null" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(14);
    try testing.expect(p == null);
}

test "Provider index 4: deepseek" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(4);
    if (p) |pp| {
        try testing.expect(std.mem.eql(u8, pp.id, "deepseek"));
        try testing.expect(std.mem.eql(u8, pp.name, "DeepSeek"));
    } else {
        try testing.expect(false);
    }
}

test "Provider index 2: openrouter" {
    const testing = @import("std").testing;
    const p = getProviderByIndex(2);
    if (p) |pp| {
        try testing.expect(std.mem.eql(u8, pp.id, "openrouter"));
        try testing.expect(std.mem.eql(u8, pp.name, "OpenRouter"));
    } else {
        try testing.expect(false);
    }
}

/// Set default provider in config
fn setDefaultProvider(provider_id: []const u8) !void {
    const allocator = std.heap.page_allocator;

    // Load config
    const config_path = try @import("config").getConfigPath(allocator);
    defer allocator.free(config_path);

    // Read existing config
    var config_content = array_list_compat.ArrayList(u8).init(allocator);
    defer config_content.deinit();

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Create new config with default provider
            try createConfigWithDefault(provider_id);
            return;
        }
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);
    _ = try file.readAll(buffer);

    // Parse and update config
    try updateConfigDefault(buffer, provider_id);
}

/// Create new config file with default provider
fn createConfigWithDefault(provider_id: []const u8) !void {
    const allocator = std.heap.page_allocator;

    const config_path = try @import("config").getConfigPath(allocator);
    defer allocator.free(config_path);

    // Ensure directory exists
    const dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();

    const content = try std.fmt.allocPrint(allocator,
        \\# Crushcode Configuration File
        \\
        \\default_provider = "{s}"
        \\default_model = ""
        \\
        \\# API Keys (add your keys below or use crushcode connect)
        \\[api_keys]
        \\
    , .{provider_id});

    defer allocator.free(content);
    _ = try file.writeAll(content);
}

/// Update existing config to set default provider
fn updateConfigDefault(content: []const u8, provider_id: []const u8) !void {
    const allocator = std.heap.page_allocator;

    // Find if default_provider already exists
    var has_default = false;
    var new_content = array_list_compat.ArrayList(u8).init(allocator);
    defer new_content.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "default_provider")) {
            has_default = true;
            // Replace the line
            try new_content.appendSlice("default_provider = \"");
            try new_content.appendSlice(provider_id);
            try new_content.appendSlice("\"\n");
        } else {
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }
    }

    if (!has_default) {
        // Insert at beginning after any comments
        // For simplicity, just append at start after first empty line
    }

    // Write back
    const config_path = try @import("config").getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    _ = try file.writeAll(new_content.items);
}

/// Print help message
pub fn printConnectHelp() void {
    out(
        \\
        \\Usage: crushcode connect
        \\
        \\Connect command walks you through adding API credentials for AI providers.
        \\
        \\Examples:
        \\  crushcode connect
        \\
    , .{});
}
