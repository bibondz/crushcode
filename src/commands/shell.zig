const std = @import("std");
const posix = std.posix;

pub const ShellResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Execute shell command via std.process.Child with optional timeout
pub fn executeShellCommand(command: []const u8, timeout_seconds: ?u32) !ShellResult {
    const argv: [3][]const u8 = .{ "sh", "-c", command };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);

    _ = try child.spawn();

    // Handle timeout using a background thread
    if (timeout_seconds) |timeout| {
        return try waitWithTimeout(&child, timeout);
    }

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

/// Wait for child process with timeout using a background thread
fn waitWithTimeout(child: *std.process.Child, timeout_seconds: u32) !ShellResult {
    const allocator = std.heap.page_allocator;

    // Shared state between threads
    const SharedState = struct {
        term: ?std.process.Child.Term = null,
        done: bool = false,
        lock: std.Thread.Mutex = .{},
    };

    const state = try allocator.create(SharedState);
    defer allocator.destroy(state);
    state.* = .{ .done = false };

    // Spawn thread to wait for the process
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SharedState, c: *std.process.Child) void {
            const result = c.wait() catch {
                s.lock.lock();
                s.term = .{ .Exited = 1 };
                s.done = true;
                s.lock.unlock();
                return;
            };
            s.lock.lock();
            s.term = result;
            s.done = true;
            s.lock.unlock();
        }
    }.run, .{ state, child });

    // Poll for completion or timeout
    const start = std.time.milliTimestamp();
    const timeout_ms = @as(i64, timeout_seconds) * 1000;

    while (true) {
        state.lock.lock();
        const is_done = state.done;
        state.lock.unlock();

        if (is_done) break;

        std.time.sleep(10 * std.time.ns_per_ms);
        const elapsed = std.time.milliTimestamp() - start;
        if (elapsed >= timeout_ms) {
            // Timeout reached - kill the process
            // First check if already done
            state.lock.lock();
            if (state.done) {
                // Already finished, no need to kill
                state.lock.unlock();
            } else {
                state.lock.unlock();
                // Use raw POSIX kill to send SIGTERM - don't call child's kill() which internally waits
                posix.kill(child.id, posix.SIG.TERM) catch {};
                thread.join();
                return ShellResult{
                    .exit_code = 124,
                    .stdout = "",
                    .stderr = "Command timed out",
                };
            }
            break;
        }
    }

    thread.join();

    state.lock.lock();
    const term = state.term orelse std.process.Child.Term{ .Exited = 1 };
    state.lock.unlock();

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
    var timeout: ?u32 = null;

    // Parse --timeout, -t, or leading number as timeout
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        // Check for --timeout
        if (std.mem.eql(u8, arg, "--timeout") and i + 1 < args.len) {
            timeout = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                std.debug.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 2;
            continue;
        }
        // Check for -t
        if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            timeout = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                std.debug.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 2;
            continue;
        }

        // If arg is all digits, treat as timeout (e.g., "shell 5 echo foo")
        var all_digits = true;
        for (arg) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits and arg.len > 0) {
            timeout = std.fmt.parseInt(u32, arg, 10) catch null;
            i += 1;
        } else {
            // Not a flag we recognize, this is the command - stop parsing
            break;
        }
    }

    // If no args remaining, start interactive shell
    if (i >= args.len) {
        try executeInteractiveShell();
        return;
    }

    // Command is everything from index i onwards
    const command_args = args[i..];
    const allocator = std.heap.page_allocator;
    var command_buf = std.ArrayList(u8).init(allocator);
    defer command_buf.deinit();

    for (command_args, 0..) |arg, idx| {
        if (idx > 0) try command_buf.append(' ');
        try command_buf.appendSlice(arg);
    }
    const cmd_str = try command_buf.toOwnedSlice();

    std.debug.print("Executing: {s}", .{cmd_str});
    if (timeout) |t| {
        std.debug.print(" (timeout: {d}s)", .{t});
    }
    std.debug.print("\n", .{});

    const result = try executeShellCommand(cmd_str, timeout);

    std.debug.print("\n[Exit code: {d}]\n", .{result.exit_code});
    if (result.stderr.len > 0) {
        std.debug.print("[Stderr: {s}]\n", .{result.stderr});
    }
}
