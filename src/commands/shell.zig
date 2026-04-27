const std = @import("std");
const string_utils = @import("string_utils");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const posix = std.posix;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub const ShellResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Maximum output size before truncation (30KB)
pub const MAX_OUTPUT_CHARS: usize = 30 * 1024;

/// Count the number of newlines in a string
fn countLines(text: []const u8) usize {
    // shell's countLines counts newline characters (not lines)
    const lines = string_utils.countLines(text);
    return if (lines == 0) 0 else @intCast(lines - 1);
}

/// Truncate output to MAX_OUTPUT_CHARS using smart midpoint style:
/// show first 40% + last 40%, truncate middle 20%.
/// Caller must free the returned string.
/// If output is within limits, returns a duplicate.
pub fn truncateOutputAlloc(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    if (output.len <= MAX_OUTPUT_CHARS) {
        return try allocator.dupe(u8, output);
    }
    const head_size = MAX_OUTPUT_CHARS * 40 / 100;
    const tail_size = MAX_OUTPUT_CHARS * 40 / 100;
    const removed = output[head_size .. output.len - tail_size];
    const removed_bytes = removed.len;
    return try std.fmt.allocPrint(allocator, "{s}\n\n... [{d} bytes truncated — use grep/read_file for specific sections] ...\n\n{s}", .{
        output[0..head_size],
        removed_bytes,
        output[output.len - tail_size ..],
    });
}

/// Redirection types (using integers to avoid enum parsing issues)
const RT_OUTPUT: u8 = 0;
const RT_APPEND: u8 = 1;
const RT_INPUT: u8 = 2;
const RT_ERROR: u8 = 3;
const RT_ERROR_APPEND: u8 = 4;
const RT_BOTH: u8 = 5;

const ParsedRedirect = struct {
    redirect_type: u8,
    target: []const u8,
    is_pipe: bool,
};

/// Parse command string and extract redirections (strips them from command)
fn parseRedirections(command: []const u8, allocator: std.mem.Allocator) struct { command: []const u8, redirections: []const ParsedRedirect } {
    var redirections = array_list_compat.ArrayList(ParsedRedirect).init(allocator);
    var clean_command = array_list_compat.ArrayList(u8).init(allocator);
    var i: usize = 0;

    while (i < command.len) {
        const char = command[i];
        if (i + 1 < command.len) {
            const next = command[i + 1];

            if (char == '|') {
                redirections.append(.{ .redirect_type = RT_OUTPUT, .target = "", .is_pipe = true }) catch {};
                i += 1;
                continue;
            }

            if (char == '>' and next == '>') {
                const ts = i + 2;
                var te = ts;
                while (te < command.len and command[te] == ' ') te += 1;
                while (te < command.len and command[te] != ' ') te += 1;
                if (te > ts) {
                    redirections.append(.{ .redirect_type = RT_APPEND, .target = std.mem.trim(u8, command[ts..te], " "), .is_pipe = false }) catch {};
                }
                i = te;
                continue;
            }

            if (char == '>') {
                const ts = i + 1;
                var te = ts;
                while (te < command.len and command[te] == ' ') te += 1;
                while (te < command.len and command[te] != ' ') te += 1;
                if (te > ts) {
                    redirections.append(.{ .redirect_type = RT_OUTPUT, .target = std.mem.trim(u8, command[ts..te], " "), .is_pipe = false }) catch {};
                }
                i = te;
                continue;
            }

            if (char == '2' and next == '>') {
                const rs = i + 2;
                if (rs < command.len and command[rs] == '>') {
                    const ts = rs + 1;
                    var te = ts;
                    while (te < command.len and command[te] == ' ') te += 1;
                    while (te < command.len and command[te] != ' ') te += 1;
                    if (te > ts) {
                        redirections.append(.{ .redirect_type = RT_ERROR_APPEND, .target = std.mem.trim(u8, command[ts..te], " "), .is_pipe = false }) catch {};
                    }
                    i = te;
                    continue;
                } else {
                    var te = rs;
                    while (te < command.len and command[te] == ' ') te += 1;
                    while (te < command.len and command[te] != ' ') te += 1;
                    if (te > rs) {
                        redirections.append(.{ .redirect_type = RT_ERROR, .target = std.mem.trim(u8, command[rs..te], " "), .is_pipe = false }) catch {};
                    }
                    i = te;
                    continue;
                }
            }

            if (char == '<') {
                const ts = i + 1;
                var te = ts;
                while (te < command.len and command[te] == ' ') te += 1;
                while (te < command.len and command[te] != ' ') te += 1;
                if (te > ts) {
                    redirections.append(.{ .redirect_type = RT_INPUT, .target = std.mem.trim(u8, command[ts..te], " "), .is_pipe = false }) catch {};
                }
                i = te;
                continue;
            }
        }

        clean_command.append(char) catch {};
        i += 1;
    }

    return .{ .command = clean_command.toOwnedSlice() catch command, .redirections = redirections.toOwnedSlice() catch &.{} };
}

/// Execute shell command via std.process.Child with optional timeout
pub fn executeShellCommand(command: []const u8, timeout_seconds: ?u32) !ShellResult {
    const allocator = std.heap.page_allocator;
    const parsed = parseRedirections(command, allocator);
    const cmd = parsed.command;

    const argv: [3][]const u8 = .{ "sh", "-c", cmd };
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

        std.Thread.sleep(10 * std.time.ns_per_ms);
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
                if (@import("builtin").os.tag != .windows) {
                    posix.kill(child.id, posix.SIG.TERM) catch {};
                }
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
    const shell = file_compat.getEnv("SHELL") orelse "/bin/sh";

    out("Interactive shell mode\n", .{});
    out("Shell: {s}\n", .{shell});

    const argv: [2][]const u8 = .{ shell, "-i" };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    _ = try child.spawn();

    const term = child.wait() catch |err| {
        out("Shell exited with error: {s}\n", .{@errorName(err)});
        return;
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    out("Shell exited with code: {d}\n", .{exit_code});
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
                out("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 2;
            continue;
        }
        // Check for -t
        if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            timeout = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                out("Invalid timeout: {s}\n", .{args[i + 1]});
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

    out("Executing: {s}", .{cmd_str});
    if (timeout) |t| {
        out(" (timeout: {d}s)", .{t});
    }
    out("\n", .{});

    const result = try executeShellCommand(cmd_str, timeout);

    out("\n[Exit code: {d}]\n", .{result.exit_code});
    if (result.stderr.len > 0) {
        out("[Stderr: {s}]\n", .{result.stderr});
    }
}
