const std = @import("std");
const array_list_compat = @import("array_list_compat");
const default_commands = @import("default_commands");

/// A plugin command definition loaded from config.
pub const PluginCommand = struct {
    name: []const u8,
    description: []const u8,
    shell: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginCommand) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.shell);
    }
};

fn freeCommandFields(commands: []const PluginCommand) void {
    for (commands) |command| {
        var mutable = command;
        mutable.deinit();
    }
}

fn getCommandsValue(parsed: std.json.Parsed(std.json.Value)) !std.json.Array {
    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidFormat,
    };

    const commands_value = root_object.get("commands") orelse return error.InvalidFormat;
    return switch (commands_value) {
        .array => |array| array,
        else => return error.InvalidFormat,
    };
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidFormat;
    return switch (value) {
        .string => |string| string,
        else => return error.InvalidFormat,
    };
}

fn getUserCommandsDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.HomeNotFound;
            defer allocator.free(userprofile);
            return std.fs.path.join(allocator, &.{ userprofile, ".crushcode", "commands" });
        }

        return err;
    };
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".crushcode", "commands" });
}

/// Load default plugin commands embedded in binary.
pub fn loadDefaultCommands(allocator: std.mem.Allocator) ![]PluginCommand {
    return parseCommands(allocator, default_commands.json);
}

/// Load user plugin commands from ~/.crushcode/commands/*.json.
pub fn loadUserCommands(allocator: std.mem.Allocator) ![]PluginCommand {
    const commands_dir = getUserCommandsDir(allocator) catch |err| switch (err) {
        error.HomeNotFound, error.EnvironmentVariableNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(commands_dir);

    var dir = std.fs.openDirAbsolute(commands_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close();

    var all_commands = array_list_compat.ArrayList(PluginCommand).init(allocator);
    errdefer {
        freeCommandFields(all_commands.items);
        all_commands.deinit();
    }

    var walker = dir.walk(allocator) catch return try all_commands.toOwnedSlice();
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) {
            continue;
        }

        const file = entry.dir.openFile(entry.basename, .{}) catch continue;
        defer file.close();

        const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(contents);

        const commands = parseCommands(allocator, contents) catch continue;
        defer allocator.free(commands);

        for (commands) |command| {
            try all_commands.append(command);
        }
    }

    return all_commands.toOwnedSlice();
}

/// Parse plugin commands from JSON.
pub fn parseCommands(allocator: std.mem.Allocator, json_bytes: []const u8) ![]PluginCommand {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const commands_array = try getCommandsValue(parsed);

    var commands = array_list_compat.ArrayList(PluginCommand).init(allocator);
    errdefer {
        freeCommandFields(commands.items);
        commands.deinit();
    }

    for (commands_array.items) |command_value| {
        const object = switch (command_value) {
            .object => |value| value,
            else => return error.InvalidFormat,
        };

        try commands.append(.{
            .name = try allocator.dupe(u8, try getStringField(object, "name")),
            .description = try allocator.dupe(u8, try getStringField(object, "description")),
            .shell = try allocator.dupe(u8, try getStringField(object, "shell")),
            .allocator = allocator,
        });
    }

    return commands.toOwnedSlice();
}

/// Execute a plugin command.
pub fn executeCommand(allocator: std.mem.Allocator, command: PluginCommand) !void {
    const argv = [_][]const u8{ "sh", "-c", command.shell };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    if (stdout.items.len > 0) {
        std.debug.print("{s}", .{stdout.items});
    }
    if (stderr.items.len > 0) {
        std.debug.print("\x1b[31m{s}\x1b[0m", .{stderr.items});
    }

    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

/// Free a list of plugin commands.
pub fn freeCommands(allocator: std.mem.Allocator, commands: []const PluginCommand) void {
    if (commands.len == 0) {
        return;
    }

    freeCommandFields(commands);
    allocator.free(commands);
}

/// Find a plugin command by name.
pub fn findCommand(commands: []const PluginCommand, name: []const u8) ?PluginCommand {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) {
            return command;
        }
    }

    return null;
}

/// Print available plugin commands.
pub fn printCommands(commands: []const PluginCommand) void {
    if (commands.len == 0) {
        return;
    }

    std.debug.print("\nPlugin Commands:\n", .{});
    for (commands) |command| {
        std.debug.print("  {s} — {s}\n", .{ command.name, command.description });
    }
}
