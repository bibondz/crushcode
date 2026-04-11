const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const chat_mod = @import("chat");
const read_mod = @import("read");
const shell_mod = @import("shell");

const Config = config_mod.Config;

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    try chat_mod.handleChat(args, config);
}

pub fn handleRead(args: args_mod.Args) !void {
    try read_mod.handleRead(args.remaining);
}

pub fn handleShell(args: args_mod.Args) !void {
    try shell_mod.handleShell(args.remaining);
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
        \\  chat           Start interactive chat session
        \\  read <file>   Read file content
        \\  shell <cmd>   Execute shell command
        \\  list           List providers or models
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Options:
        \\  --provider <id>    Use specific AI provider
        \\  --model <id>       Use specific model
        \\  --config <path>    Use custom config file
        \\
        \\Examples:
        \\  crushcode chat
        \\  crushcode chat --provider openai --model gpt-4o
        \\  crushcode read src/main.zig
        \\  crushcode shell "ls -la"
        \\  crushcode list --provider openai
        \\
    , .{});
}

pub fn printVersion() !void {
    std.debug.print("Crushcode v0.1.0\n", .{});
}
