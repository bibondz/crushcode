const std = @import("std");
const array_list_compat = @import("array_list_compat");
const posix = std.posix;

pub const ShellResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Redirection types for pipe/redirect parsing
const RedirectionType = u8;
const Redirect = struct {
    redirect_type: RedirectionType,
    target: []const u8,
    is_pipe: bool,
};

const RT_OUTPUT: RedirectionType = 0;
const RT_APPEND: RedirectionType = 1;
const RT_INPUT: RedirectionType = 2;
const RT_ERROR: RedirectionType = 3;
const RT_ERROR_APPEND: RedirectionType = 4;
const RT_BOTH: RedirectionType = 5;

/// Parse command string and extract redirections
fn parseRedirections(
    command: []const u8,
    allocator: std.mem.Allocator,
) struct { command: []const u8, redirections: []const Redirect } {
    var redirections = array_list_compat.ArrayList(Redirect).init(allocator);
    var clean_command = array_list_compat.ArrayList(u8).init(allocator);
    var i: usize = 0;

    while (i < command.len) {
        const char = command[i];

        if (i + 1 < command.len) {
            const next = command[i + 1];

            if (char == '|') {
                redirections.append(.{
                    .redirect_type = .output,
                    .target = "",
                    .is_pipe = true,
                }) catch {};
                i += 1;
                continue;
            }

            if (char == '>' and next == '>') {
                const target_start = i + 2;
                var target_end = target_start;
                while (target_end < command.len and command[target_end] == ' ') target_end += 1;
                while (target_end < command.len and command[target_end] != ' ') target_end += 1;

                if (target_end > target_start) {
                    redirections.append(.{
                        .redirect_type = .append,
                        .target = std.mem.trim(u8, command[target_start..target_end], " "),
                        .is_pipe = false,
                    }) catch {};
                }
                i = target_end;
                continue;
            }

            if (char == '>') {
                const target_start = i + 1;
                var target_end = target_start;
                while (target_end < command.len and command[target_end] == ' ') target_end += 1;
                while (target_end < command.len and command[target_end] != ' ') target_end += 1;

                if (target_end > target_start) {
                    redirections.append(.{
                        .redirect_type = .output,
                        .target = std.mem.trim(u8, command[target_start..target_end], " "),
                        .is_pipe = false,
                    }) catch {};
                }
                i = target_end;
                continue;
            }

            if (char == '2' and next == '>') {
                const redirect_start = i + 2;
                if (redirect_start < command.len and command[redirect_start] == '>') {
                    const target_start = redirect_start + 1;
                    var target_end = target_start;
                    while (target_end < command.len and command[target_end] == ' ') target_end += 1;
                    while (target_end < command.len and command[target_end] != ' ') target_end += 1;

                    if (target_end > target_start) {
                        redirections.append(.{
                            .redirect_type = .error_append,
                            .target = std.mem.trim(u8, command[target_start..target_end], " "),
                            .is_pipe = false,
                        }) catch {};
                    }
                    i = target_end;
                    continue;
                } else {
                    var target_end = redirect_start;
                    while (target_end < command.len and command[target_end] == ' ') target_end += 1;
                    while (target_end < command.len and command[target_end] != ' ') target_end += 1;

                    if (target_end > redirect_start) {
                        redirections.append(.{
                            .redirect_type = RT_ERROR,
                            .target = std.mem.trim(u8, command[redirect_start..target_end], " "),
                            .is_pipe = false,
                        }) catch {};
                    }
                    i = target_end;
                    continue;
                }
            }

            if (char == '<') {
                const target_start = i + 1;
                var target_end = target_start;
                while (target_end < command.len and command[target_end] == ' ') target_end += 1;
                while (target_end < command.len and command[target_end] != ' ') target_end += 1;

                if (target_end > target_start) {
                    redirections.append(.{
                        .redirect_type = .input,
                        .target = std.mem.trim(u8, command[target_start..target_end], " "),
                        .is_pipe = false,
                    }) catch {};
                }
                i = target_end;
                continue;
            }
        }

        clean_command.append(char) catch {};
        i += 1;
    }

    return .{
        .command = clean_command.toOwnedSlice() catch command,
        .redirections = redirections.toOwnedSlice() catch &.{},
    };
}

/// Execute shell command via std.process.Child with optional timeout
pub fn executeShellCommand(command: []const u8, timeout_seconds: ?u32) !ShellResult {
    const allocator = std.heap.page_allocator;

    // Parse redirections and strip them from command
    const parsed = parseRedirections(command, allocator);
    const cmd = parsed.command;

    // For now, just strip redirections - actual pipe execution would need more work
    // Check if there were any pipes for logging purposes
    var has_pipe = false;
    for (parsed.redirections) |r| {
        if (r.is_pipe) {
            has_pipe = true;
            break;
        }
    }
    _ = has_pipe; // Could be used for logging

    const argv: [3][]const u8 = .{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, allocator);

    // Set up pipes for stdout and stderr
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    // Handle timeout using a background thread
    if (timeout_seconds) |timeout| {
        return try waitWithTimeoutPipes(&child, timeout, allocator);
    }

    // Read output using the built-in collectOutput
    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024); // 1MB max

    const term = child.wait() catch |err| {
        return ShellResult{
            .exit_code = 1,
            .stdout = try stdout.toOwnedSlice(allocator),
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
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

/// Read from pipe into an allocated string
fn readPipeToString(fd: std.posix.fd_t, allocator: std.mem.Allocator) ![]const u8 {
    var buffer = array_list_compat.ArrayList(u8).init(allocator);
    var buf: [4096]u8 = undefined;

    while (true) {
        const bytes_read = std.posix.read(fd, &buf) catch break;
        if (bytes_read == 0) break;
        try buffer.appendSlice(buf[0..bytes_read]);
    }

    return buffer.toOwnedSlice();
}

/// Wait for child process with timeout using pipes
fn waitWithTimeoutPipes(
    child: *std.process.Child,
    timeout_seconds: u32,
    allocator: std.mem.Allocator,
) !ShellResult {
    const SharedState = struct {
        term: ?std.process.Child.Term = null,
        done: bool = false,
        lock: std.Thread.Mutex = .{},
    };

    const state = try allocator.create(SharedState);
    defer allocator.destroy(state);
    state.* = .{ .done = false };

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
            state.lock.lock();
            if (state.done) {
                state.lock.unlock();
            } else {
                state.lock.unlock();
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

    // Collect output after process completes
    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024) catch {};

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
        .stdout = stdout.items,
        .stderr = stderr.items,
    };
}

/// Read from pipe into an allocated string (uses provided allocator)
fn readPipeToStringAlloc(fd: std.posix.fd_t, allocator: std.mem.Allocator) []const u8 {
    var buffer = array_list_compat.ArrayList(u8).init(allocator);
    var buf: [4096]u8 = undefined;

    while (true) {
        const bytes_read = std.posix.read(fd, &buf) catch break;
        if (bytes_read == 0) break;
        buffer.appendSlice(buf[0..bytes_read]) catch break;
    }
    std.posix.close(fd);

    return buffer.toOwnedSlice();
}

/// Wait for child process with timeout (legacy - no pipes)
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
    var command_buf = array_list_compat.ArrayList(u8).init(allocator);
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

    if (result.stdout.len > 0) {
        std.debug.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        std.debug.print("[Stderr: {s}]\n", .{result.stderr});
    }
    std.debug.print("[Exit code: {d}]\n", .{result.exit_code});
}
