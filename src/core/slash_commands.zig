const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Result of executing a slash command
pub const CommandResult = struct {
    allocator: Allocator,
    output: []const u8,
    should_exit: bool = false,
    should_clear: bool = false,

    pub fn init(allocator: Allocator, output: []const u8) !CommandResult {
        return CommandResult{
            .allocator = allocator,
            .output = try allocator.dupe(u8, output),
        };
    }

    pub fn initWithFlags(allocator: Allocator, output: []const u8, should_exit: bool, should_clear: bool) !CommandResult {
        return CommandResult{
            .allocator = allocator,
            .output = try allocator.dupe(u8, output),
            .should_exit = should_exit,
            .should_clear = should_clear,
        };
    }

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.output);
    }
};

/// A slash command definition with name, description, and handler
pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn (allocator: Allocator, args: []const u8) anyerror!CommandResult,
};

/// Session context passed to commands that need session state
pub const SessionContext = struct {
    model: []const u8,
    turn_count: u32,
    input_tokens: u64,
    output_tokens: u64,
};

/// Interactive Slash Command Registry.
/// Provides type-safe slash commands for the REPL, inspired by
/// OpenCode's COMMANDS dispatch pattern.
///
/// Usage:
///   const registry = SlashCommandRegistry.init(allocator);
///   if (registry.find("/help")) |cmd| {
///       var result = try cmd.handler(allocator, "");
///       defer result.deinit();
///       print("{s}", .{result.output});
///   }
///
/// Reference: OpenCode slash commands (F16)
pub const SlashCommandRegistry = struct {
    allocator: Allocator,
    commands: array_list_compat.ArrayList(SlashCommand),

    pub fn init(allocator: Allocator) SlashCommandRegistry {
        return SlashCommandRegistry{
            .allocator = allocator,
            .commands = array_list_compat.ArrayList(SlashCommand).init(allocator),
        };
    }

    pub fn deinit(self: *SlashCommandRegistry) void {
        self.commands.deinit();
    }

    /// Register the built-in commands
    pub fn registerDefaults(self: *SlashCommandRegistry) !void {
        // Full commands
        try self.register(SlashCommand{
            .name = "/help",
            .description = "Show available commands",
            .handler = cmdHelp,
        });
        try self.register(SlashCommand{
            .name = "/clear",
            .description = "Clear conversation history",
            .handler = cmdClear,
        });
        try self.register(SlashCommand{
            .name = "/compact",
            .description = "Compact conversation context",
            .handler = cmdCompact,
        });
        try self.register(SlashCommand{
            .name = "/cost",
            .description = "Show token usage and estimated cost",
            .handler = cmdCost,
        });
        try self.register(SlashCommand{
            .name = "/budget",
            .description = "Show budget status and spending limits",
            .handler = cmdBudget,
        });
        try self.register(SlashCommand{
            .name = "/model",
            .description = "Show or switch current model",
            .handler = cmdModel,
        });
        try self.register(SlashCommand{
            .name = "/tools",
            .description = "List available tools",
            .handler = cmdTools,
        });
        try self.register(SlashCommand{
            .name = "/tokens",
            .description = "Show current token usage",
            .handler = cmdTokens,
        });
        try self.register(SlashCommand{
            .name = "/exit",
            .description = "Exit the REPL",
            .handler = cmdExit,
        });
        try self.register(SlashCommand{
            .name = "/version",
            .description = "Show version information",
            .handler = cmdVersion,
        });
        try self.register(SlashCommand{
            .name = "/status",
            .description = "Show session status",
            .handler = cmdStatus,
        });

        // Short aliases for quick access
        try self.register(SlashCommand{ .name = "/h", .description = "Alias for /help", .handler = cmdHelp });
        try self.register(SlashCommand{ .name = "/c", .description = "Alias for /clear", .handler = cmdClear });
        try self.register(SlashCommand{ .name = "/m", .description = "Alias for /model", .handler = cmdModel });
        try self.register(SlashCommand{ .name = "/q", .description = "Alias for /exit", .handler = cmdExit });
        try self.register(SlashCommand{ .name = "/s", .description = "Alias for /status", .handler = cmdStatus });
        try self.register(SlashCommand{ .name = "/t", .description = "Alias for /tokens", .handler = cmdTokens });
        try self.register(SlashCommand{ .name = "/v", .description = "Alias for /version", .handler = cmdVersion });
    }

    /// Register a custom command
    pub fn register(self: *SlashCommandRegistry, command: SlashCommand) !void {
        try self.commands.append(command);
    }

    /// Find a command by name (including the / prefix)
    pub fn find(self: *const SlashCommandRegistry, name: []const u8) ?SlashCommand {
        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        return null;
    }

    /// Try to execute a slash command. Returns null if input is not a slash command.
    pub fn execute(self: *SlashCommandRegistry, input: []const u8) !?CommandResult {
        if (input.len == 0 or input[0] != '/') return null;

        // Split command name and arguments
        const space_idx = std.mem.indexOfScalar(u8, input, ' ');
        const cmd_name = if (space_idx) |i| input[0..i] else input;
        const args = if (space_idx) |i| std.mem.trim(u8, input[i + 1 ..], " ") else "";

        const cmd = self.find(cmd_name) orelse {
            return CommandResult{
                .allocator = self.allocator,
                .output = try self.allocator.dupe(u8, "Unknown command. Type /help for available commands."),
            };
        };

        return cmd.handler(self.allocator, args) catch |err| switch (err) {
            else => return CommandResult{
                .allocator = self.allocator,
                .output = try std.fmt.allocPrint(self.allocator, "Command error: {}", .{err}),
            },
        };
    }

    /// Check if input is a slash command (starts with /)
    pub fn isSlashCommand(input: []const u8) bool {
        return input.len > 0 and input[0] == '/';
    }

    /// Generate help text listing all registered commands
    pub fn helpText(self: *const SlashCommandRegistry, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        const writer = buf.writer();
        try writer.writeAll("Available commands:\n\n");
        for (self.commands.items) |cmd| {
            try writer.print("  {s}", .{cmd.name});
            // Pad to 20 chars
            var pad: usize = 20 - cmd.name.len;
            while (pad > 0) : (pad -= 1) {
                try writer.writeByte(' ');
            }
            try writer.print("{s}\n", .{cmd.description});
        }
        try writer.writeAll("\n");
        return buf.toOwnedSlice();
    }
};

// ============================================================
// Built-in Command Handlers
// ============================================================

fn cmdHelp(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    var registry = SlashCommandRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerDefaults();
    const text = try registry.helpText(allocator);
    return CommandResult{
        .allocator = allocator,
        .output = text,
    };
}

fn cmdClear(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.initWithFlags(allocator, "Conversation cleared.", false, true);
}

fn cmdCompact(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator, "Context compacted.");
}

fn cmdCost(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator, "Token cost: (usage tracking not yet connected)");
}

fn cmdBudget(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    // Budget status is shown in the TUI header and /usage command.
    // This command provides a quick summary.
    return CommandResult.init(allocator,
        \\Budget Status:
        \\  Use /usage for detailed breakdown
        \\  Budget limits configured in config.toml [budget] section
        \\  Options: daily_limit_usd, monthly_limit_usd, per_session_limit_usd
    );
}

fn cmdModel(allocator: Allocator, args: []const u8) !CommandResult {
    if (args.len == 0) {
        return CommandResult.init(allocator, "Current model: (default)");
    }
    return CommandResult.init(allocator, "Model switched."); // Actual switch handled by caller
}

fn cmdTools(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator,
        \\Available tools:
        \\  bash      - Execute shell commands
        \\  read      - Read files
        \\  write     - Write files
        \\  edit      - Edit files
        \\  glob      - Find files by pattern
        \\  grep      - Search file contents
        \\  mcp       - MCP server tools
        \\
    );
}

fn cmdTokens(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator, "Tokens: 0 input, 0 output (tracking not yet connected)");
}

fn cmdExit(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.initWithFlags(allocator, "Goodbye!", true, false);
}

fn cmdVersion(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator, "Crushcode v0.25.0");
}

fn cmdStatus(allocator: Allocator, args: []const u8) !CommandResult {
    _ = args;
    return CommandResult.init(allocator, "Status: active | Model: (default) | Turns: 0");
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "SlashCommandRegistry - register and find" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    const help = registry.find("/help");
    try testing.expect(help != null);
    try testing.expectEqualStrings("/help", help.?.name);

    const clear = registry.find("/clear");
    try testing.expect(clear != null);
    try testing.expectEqualStrings("/clear", clear.?.name);
}

test "SlashCommandRegistry - find unknown returns null" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    try testing.expect(registry.find("/nonexistent") == null);
}

test "SlashCommandRegistry - execute /help" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    var result = (try registry.execute("/help")).?;
    defer result.deinit();
    try testing.expect(!result.should_exit);
    try testing.expect(!result.should_clear);
    try testing.expect(result.output.len > 0);
}

test "SlashCommandRegistry - execute /clear sets should_clear" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    var result = (try registry.execute("/clear")).?;
    defer result.deinit();
    try testing.expect(result.should_clear);
}

test "SlashCommandRegistry - execute /exit sets should_exit" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    var result = (try registry.execute("/exit")).?;
    defer result.deinit();
    try testing.expect(result.should_exit);
}

test "SlashCommandRegistry - non-slash input returns null" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    const result = try registry.execute("hello world");
    try testing.expect(result == null);
}

test "SlashCommandRegistry - unknown command returns error message" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    var result = (try registry.execute("/unknown")).?;
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.output, "Unknown") != null);
}

test "SlashCommandRegistry - execute with args" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    var result = (try registry.execute("/model gpt-4o")).?;
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.output, "switched") != null);
}

test "SlashCommandRegistry - isSlashCommand" {
    try testing.expect(SlashCommandRegistry.isSlashCommand("/help"));
    try testing.expect(!SlashCommandRegistry.isSlashCommand("help"));
    try testing.expect(!SlashCommandRegistry.isSlashCommand(""));
}

test "SlashCommandRegistry - helpText generates listing" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerDefaults();

    const text = try registry.helpText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "/help") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/exit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/clear") != null);
}

test "SlashCommandRegistry - register custom command" {
    var registry = SlashCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.register(SlashCommand{
        .name = "/custom",
        .description = "A custom test command",
        .handler = cmdHelp, // reuse for test
    });

    const found = registry.find("/custom");
    try testing.expect(found != null);
    try testing.expectEqualStrings("A custom test command", found.?.description);
}
