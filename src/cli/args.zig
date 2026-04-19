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
    memory: ?[]const u8 = null, // session memory/history (file path or "auto")
    memory_limit: u32 = 100, // max messages to remember
    stream: bool = false, // enable streaming output
    debug: bool = false, // enable debug output
    show_thinking: bool = false, // show streaming thinking output
    permission: ?[]const u8 = null, // permission mode: default, auto, plan, acceptEdits, dontAsk, bypassPermissions
    intensity: ?[]const u8 = null, // output intensity: lite, normal, full, ultra (F1: Caveman-inspired)
    continue_session: bool = false, // --continue: load last session
    session_id: ?[]const u8 = null, // --session <id>: load specific session
    output_dir: ?[]const u8 = null, // --output-dir <dir>: batch output directory
    stop_on_error: bool = false, // --stop-on-error: halt batch on first error
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

            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                result.command = arg;
                command_found = true;
                continue;
            }

            // After command is found, or if it's a flag, parse options
            if (std.mem.startsWith(u8, arg, "-")) {
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
                } else if (std.mem.eql(u8, arg, "--tui")) {
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
                } else if (std.mem.startsWith(u8, arg, "--memory=")) {
                    result.memory = arg[9..];
                } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
                    if (args_iter.next()) |next_arg| {
                        result.memory = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--memory-limit=")) {
                    const val = arg[15..];
                    result.memory_limit = std.fmt.parseInt(u32, val, 10) catch 100;
                } else if (std.mem.eql(u8, arg, "--yolo")) {
                    result.permission = "bypassPermissions";
                } else if (std.mem.eql(u8, arg, "--auto")) {
                    result.permission = "auto";
                } else if (std.mem.eql(u8, arg, "--plan")) {
                    result.permission = "plan";
                } else if (std.mem.startsWith(u8, arg, "--permission=")) {
                    result.permission = arg[13..];
                } else if (std.mem.eql(u8, arg, "--permission") or std.mem.eql(u8, arg, "-p")) {
                    if (args_iter.next()) |next_arg| {
                        result.permission = next_arg;
                    }
                } else if (std.mem.eql(u8, arg, "--stream") or std.mem.eql(u8, arg, "-s")) {
                    result.stream = true;
                } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
                    result.debug = true;
                } else if (std.mem.eql(u8, arg, "--thinking") or std.mem.eql(u8, arg, "-t")) {
                    result.show_thinking = true;
                } else if (std.mem.startsWith(u8, arg, "--intensity=")) {
                    result.intensity = arg[12..];
                } else if (std.mem.eql(u8, arg, "--intensity")) {
                    if (args_iter.next()) |next_arg| {
                        result.intensity = next_arg;
                    }
                } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
                    result.continue_session = true;
                } else if (std.mem.startsWith(u8, arg, "--session=")) {
                    result.session_id = arg[10..];
                } else if (std.mem.eql(u8, arg, "--session")) {
                    if (args_iter.next()) |next_arg| {
                        result.session_id = next_arg;
                    }
                } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
                    result.output_dir = arg[13..];
                } else if (std.mem.eql(u8, arg, "--output-dir")) {
                    if (args_iter.next()) |next_arg| {
                        result.output_dir = next_arg;
                    }
                } else if (std.mem.eql(u8, arg, "--stop-on-error")) {
                    result.stop_on_error = true;
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
            .memory = if (result.memory) |m| try allocator.dupe(u8, m) else null,
            .memory_limit = result.memory_limit,
            .stream = result.stream,
            .debug = result.debug,
            .show_thinking = result.show_thinking,
            .permission = if (result.permission) |p| try allocator.dupe(u8, p) else null,
            .intensity = if (result.intensity) |i| try allocator.dupe(u8, i) else null,
            .continue_session = result.continue_session,
            .session_id = if (result.session_id) |s| try allocator.dupe(u8, s) else null,
            .output_dir = if (result.output_dir) |o| try allocator.dupe(u8, o) else null,
            .stop_on_error = result.stop_on_error,
            .remaining = remaining,
            .has_command = has_command,
        };
    }
};
