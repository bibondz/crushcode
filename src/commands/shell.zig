const std = @import("std");
const posix = std.posix;

pub const ShellResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Execute shell command via std.process.Child
pub fn executeShellCommand(command: []const u8) !ShellResult {
    const argv: [3][]const u8 = .{ "sh", "-c", command };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);

    _ = try child.spawn();

    const term = child.wait() catch |err| {
        return ShellResult{
            .exit_code = 1,
            .stdout = "",
            .stderr = @errorName(err),
        };
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    return ShellResult{
        .exit_code = exit_code,
        .stdout = "",
        .stderr = "",
    };
}

/// Execute shell command in interactive shell mode (basic PTY support)
pub fn executeInteractiveShell() !void {
    const shell = std.posix.getenv("SHELL") orelse "/bin/sh";

    std.debug.print("Interactive shell mode\n", .{});
    std.debug.print("Shell: {s}\n", .{shell});

    const argv: [2][]const u8 = .{ shell, "-i" };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    _ = try child.spawn();

    const term = child.wait() catch |err| {
        std.debug.print("Shell exited with error: {s}\n", .{@errorName(err)});
        return;
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    std.debug.print("Shell exited with code: {d}\n", .{exit_code});
}

/// Handle shell command from CLI args
pub fn handleShell(args: [][]const u8) !void {
    if (args.len == 0) {
        try executeInteractiveShell();
        return;
    }

    const allocator = std.heap.page_allocator;
    var command_buf = std.ArrayList(u8).init(allocator);
    defer command_buf.deinit();

    for (args, 0..) |arg, idx| {
        if (idx > 0) try command_buf.append(' ');
        try command_buf.appendSlice(arg);
    }
    const command = try command_buf.toOwnedSlice();

    std.debug.print("Executing: {s}\n", .{command});

    const result = try executeShellCommand(command);

    std.debug.print("\n[Exit code: {d}]\n", .{result.exit_code});
    if (result.stderr.len > 0) {
        std.debug.print("[Stderr: {s}]\n", .{result.stderr});
    }
}
