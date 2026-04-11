const std = @import("std");

pub const Args = struct {
    command: []const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    config_file: ?[]const u8,
    interactive: bool = false,
    remaining: [][]const u8,
    has_command: bool = false,

    pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.ArgIterator) !Args {
        var remaining_list = std.ArrayListUnmanaged([]const u8){};

        var result = Args{
            .command = "chat",
            .provider = null,
            .model = null,
            .config_file = null,
            .interactive = false,
            .remaining = undefined, // Will be set later
        };

        var is_first_arg = true;
        while (args_iter.next()) |arg| {
            if (is_first_arg) {
                // Skip program name
                is_first_arg = false;
                continue;
            }

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
                } else if (std.mem.startsWith(u8, arg, "--config=")) {
                    result.config_file = arg[9..];
                } else if (std.mem.eql(u8, arg, "--config")) {
                    if (args_iter.next()) |next_arg| {
                        result.config_file = next_arg;
                    }
                } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
                    result.interactive = true;
                }
            } else if (std.mem.eql(u8, result.command, "chat")) {
                // Still at default command - this should be the actual command
                // Check if it looks like a flag (starts with -)
                if (!std.mem.startsWith(u8, arg, "-")) {
                    result.command = arg;
                } else {
                    // Flag-like argument goes to remaining
                    try remaining_list.append(allocator, try allocator.dupe(u8, arg));
                }
            } else {
                // Everything else goes to remaining
                try remaining_list.append(allocator, try allocator.dupe(u8, arg));
            }
        }

        const remaining = try remaining_list.toOwnedSlice(allocator);
        const has_command = result.command.ptr != "chat".ptr;

        return Args{
            .command = try allocator.dupe(u8, result.command),
            .provider = if (result.provider) |p| try allocator.dupe(u8, p) else null,
            .model = if (result.model) |m| try allocator.dupe(u8, m) else null,
            .config_file = if (result.config_file) |c| try allocator.dupe(u8, c) else null,
            .interactive = result.interactive,
            .remaining = remaining,
            .has_command = has_command,
        };
    }
};
