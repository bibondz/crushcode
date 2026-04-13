const std = @import("std");

pub const Args = struct {
    command: []const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    profile: ?[]const u8,
    config_file: ?[]const u8,
    interactive: bool = false,
    tui: bool = false,
    json: bool = false,
    color: ?[]const u8 = null, // "auto", "always", "never"
    checkpoint: ?[]const u8 = null, // checkpoint ID to restore
    restore: ?[]const u8 = null, // checkpoint ID to restore (alias for --checkpoint)
    agents: ?[]const u8 = null, // comma-separated agent categories to spawn
    max_agents: u32 = 5, // max concurrent agents
    remaining: [][]const u8,
    has_command: bool = false,

    pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.ArgIterator) !Args {
        var remaining_list = std.ArrayListUnmanaged([]const u8){};

        var result = Args{
            .command = "chat",
            .provider = null,
            .model = null,
            .profile = null,
            .config_file = null,
            .interactive = false,
            .remaining = undefined, // Will be set later
        };

        var is_first_arg = true;
        var command_found = false; // Track if we've identified the command
        while (args_iter.next()) |arg| {
            if (is_first_arg) {
                // Skip program name
                is_first_arg = false;
                continue;
            }

            // First non-flag argument is the command
            if (!command_found and !std.mem.startsWith(u8, arg, "-")) {
                result.command = arg;
                command_found = true;
                continue;
            }

            // After command is found, or if it's a flag, parse options
            if (std.mem.startsWith(u8, arg, "--")) {
                // Parse flags with = or space
                if (std.mem.startsWith(u8, arg, "--provider=")) {
                    result.provider = arg[11..];
                } else if (std.mem.eql(u8, arg, "--provider")) {
                    if (args_iter.next()) |next_arg| {
                        result.provider = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--model=")) {
                    result.model = arg[8..];
                } else if (std.mem.eql(u8, arg, "--model")) {
                    if (args_iter.next()) |next_arg| {
                        result.model = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--profile=")) {
                    result.profile = arg[10..];
                } else if (std.mem.eql(u8, arg, "--profile")) {
                    if (args_iter.next()) |next_arg| {
                        result.profile = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--config=")) {
                    result.config_file = arg[9..];
                } else if (std.mem.eql(u8, arg, "--config")) {
                    if (args_iter.next()) |next_arg| {
                        result.config_file = next_arg;
                    }
                } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
                    result.interactive = true;
                } else if (std.mem.eql(u8, arg, "--tui") or std.mem.eql(u8, arg, "-t")) {
                    result.tui = true;
                } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
                    result.json = true;
                } else if (std.mem.eql(u8, arg, "--color")) {
                    if (args_iter.next()) |next_arg| {
                        result.color = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--color=")) {
                    result.color = arg[8..];
                } else if (std.mem.startsWith(u8, arg, "--checkpoint=")) {
                    result.checkpoint = arg[13..];
                } else if (std.mem.eql(u8, arg, "--checkpoint")) {
                    if (args_iter.next()) |next_arg| {
                        result.checkpoint = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--restore=")) {
                    result.restore = arg[10..];
                } else if (std.mem.eql(u8, arg, "--restore")) {
                    if (args_iter.next()) |next_arg| {
                        result.restore = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--agents=")) {
                    result.agents = arg[9..];
                } else if (std.mem.eql(u8, arg, "--agents") or std.mem.eql(u8, arg, "-a")) {
                    if (args_iter.next()) |next_arg| {
                        result.agents = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--max-agents=")) {
                    const val = arg[13..];
                    result.max_agents = std.fmt.parseInt(u32, val, 10) catch 5;
                } else if (std.mem.eql(u8, arg, "--max-agents")) {
                    if (args_iter.next()) |next_arg| {
                        result.max_agents = std.fmt.parseInt(u32, next_arg, 10) catch 5;
                    }
                } else {
                    // Unknown flag - add to remaining
                    try remaining_list.append(allocator, try allocator.dupe(u8, arg));
                }
            } else {
                // Positional argument (value for previous flag, or extra args)
                try remaining_list.append(allocator, try allocator.dupe(u8, arg));
            }
        }

        const remaining = try remaining_list.toOwnedSlice(allocator);
        const has_command = command_found;

        return Args{
            .command = try allocator.dupe(u8, result.command),
            .provider = if (result.provider) |p| try allocator.dupe(u8, p) else null,
            .model = if (result.model) |m| try allocator.dupe(u8, m) else null,
            .profile = if (result.profile) |p| try allocator.dupe(u8, p) else null,
            .config_file = if (result.config_file) |c| try allocator.dupe(u8, c) else null,
            .interactive = result.interactive,
            .tui = result.tui,
            .json = result.json,
            .color = if (result.color) |c| try allocator.dupe(u8, c) else null,
            .checkpoint = if (result.checkpoint) |c| try allocator.dupe(u8, c) else null,
            .restore = if (result.restore) |r| try allocator.dupe(u8, r) else null,
            .agents = if (result.agents) |a| try allocator.dupe(u8, a) else null,
            .max_agents = result.max_agents,
            .remaining = remaining,
            .has_command = has_command,
        };
    }
};
