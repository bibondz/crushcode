const std = @import("std");
const posix = std.posix;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    timed_out: bool = false,
};

/// Execute a shell command via `sh -c` and capture output.
/// Caller owns the returned ProcessResult.stdout and .stderr memory (allocated from `allocator`).
pub fn runShellCommand(allocator: std.mem.Allocator, command: []const u8) !ProcessResult {
    const argv: [3][]const u8 = .{ "sh", "-c", command };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    errdefer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .exit_code = exit_code,
    };
}

/// Shared state for thread communication in runShellCommandWithTimeout
const SharedState = struct {
    stdout_buf: std.ArrayListUnmanaged(u8),
    stderr_buf: std.ArrayListUnmanaged(u8),
    term: ?std.process.Child.Term = null,
    done: bool = false,
    timed_out_flag: bool = false,
    error_val: ?anyerror = null,
    lock: std.Thread.Mutex = .{},
};

/// Execute a shell command with optional timeout in seconds.
/// When timeout_seconds is null or 0, behaves like runShellCommand (no timeout).
/// When timeout triggers, child is killed (SIGKILL on POSIX), returns exit_code=124
/// and timed_out=true with any output collected so far.
pub fn runShellCommandWithTimeout(
    allocator: std.mem.Allocator,
    command: []const u8,
    timeout_seconds: ?u32,
) !ProcessResult {
    const argv: [3][]const u8 = .{ "sh", "-c", command };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    // If no timeout, use simple path like runShellCommand
    if (timeout_seconds == null or timeout_seconds.? == 0) {
        var stdout = std.ArrayListUnmanaged(u8){};
        var stderr = std.ArrayListUnmanaged(u8){};
        errdefer {
            stdout.deinit(allocator);
            stderr.deinit(allocator);
        }

        try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
        const term = try child.wait();

        const exit_code: u8 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |code| @intCast(code),
            else => 1,
        };

        return .{
            .stdout = try stdout.toOwnedSlice(allocator),
            .stderr = try stderr.toOwnedSlice(allocator),
            .exit_code = exit_code,
            .timed_out = false,
        };
    }

    // With timeout: use threading
    const timeout_ms = timeout_seconds.? * 1000;
    var shared_state = SharedState{
        .stdout_buf = .{},
        .stderr_buf = .{},
    };
    defer {
        shared_state.stdout_buf.deinit(allocator);
        shared_state.stderr_buf.deinit(allocator);
    }

    const child_id = child.id;

    // Reader thread function - returns void, captures errors in shared state
    const reader_thread_fn = struct {
        fn run(child_ptr: *std.process.Child, state_ptr: *SharedState, alloc: std.mem.Allocator) void {
            // Read stdout
            if (child_ptr.stdout) |stdout| {
                var buffer: [4096]u8 = undefined;
                while (true) {
                    const n = stdout.read(&buffer) catch |err| {
                        if (err == error.EndOfStream) break;
                        state_ptr.lock.lock();
                        defer state_ptr.lock.unlock();
                        state_ptr.error_val = err;
                        state_ptr.done = true;
                        return;
                    };
                    if (n == 0) break;
                    state_ptr.stdout_buf.appendSlice(alloc, buffer[0..n]) catch {
                        state_ptr.lock.lock();
                        defer state_ptr.lock.unlock();
                        state_ptr.done = true;
                        return;
                    };
                    if (state_ptr.stdout_buf.items.len >= 1024 * 1024) break;
                }
            }

            // Read stderr
            if (child_ptr.stderr) |stderr| {
                var buffer: [4096]u8 = undefined;
                while (true) {
                    const n = stderr.read(&buffer) catch |err| {
                        if (err == error.EndOfStream) break;
                        state_ptr.lock.lock();
                        defer state_ptr.lock.unlock();
                        state_ptr.error_val = err;
                        state_ptr.done = true;
                        return;
                    };
                    if (n == 0) break;
                    state_ptr.stderr_buf.appendSlice(alloc, buffer[0..n]) catch {
                        state_ptr.lock.lock();
                        defer state_ptr.lock.unlock();
                        state_ptr.done = true;
                        return;
                    };
                    if (state_ptr.stderr_buf.items.len >= 1024 * 1024) break;
                }
            }

            // Wait for child to finish
            const term = child_ptr.wait() catch |err| {
                state_ptr.lock.lock();
                defer state_ptr.lock.unlock();
                state_ptr.error_val = err;
                state_ptr.done = true;
                return;
            };

            state_ptr.lock.lock();
            defer state_ptr.lock.unlock();
            state_ptr.term = term;
            state_ptr.done = true;
        }
    }.run;

    // Spawn reader thread
    var thread = try std.Thread.spawn(.{}, reader_thread_fn, .{ &child, &shared_state, allocator });

    // Wait for timeout or completion
    const start = std.time.milliTimestamp();
    var timed_out = false;
    while (true) {
        shared_state.lock.lock();
        const done = shared_state.done;
        shared_state.lock.unlock();

        if (done) break;

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
        if (elapsed > timeout_ms) {
            // Timeout: kill child
            if (@import("builtin").os.tag != .windows) {
                posix.kill(child_id, posix.SIG.KILL) catch {};
            }
            shared_state.lock.lock();
            shared_state.timed_out_flag = true;
            shared_state.lock.unlock();
            timed_out = true;
            break;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Wait for reader thread to finish
    thread.join();

    // Extract results
    shared_state.lock.lock();
    defer shared_state.lock.unlock();

    // Check for errors in the reader thread
    if (shared_state.error_val) |err| {
        return err;
    }

    const exit_code: u8 = if (timed_out) 124 else blk: {
        if (shared_state.term) |term| {
            break :blk switch (term) {
                .Exited => |code| @intCast(code),
                .Signal => |code| @intCast(code),
                else => 1,
            };
        }
        break :blk 1;
    };

    return .{
        .stdout = try shared_state.stdout_buf.toOwnedSlice(allocator),
        .stderr = try shared_state.stderr_buf.toOwnedSlice(allocator),
        .exit_code = exit_code,
        .timed_out = timed_out,
    };
}

test "runShellCommand - echo hello" {
    const result = try runShellCommand(std.testing.allocator, "echo hello");
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "runShellCommand - exit code" {
    const result = try runShellCommand(std.testing.allocator, "exit 42");
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 42), result.exit_code);
}

test "runShellCommand - stderr capture" {
    const result = try runShellCommand(std.testing.allocator, "echo error_msg >&2");
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "error_msg") != null);
}

test "runShellCommand - empty output" {
    const result = try runShellCommand(std.testing.allocator, "true");
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "runShellCommandWithTimeout - command completes within timeout" {
    const result = try runShellCommandWithTimeout(std.testing.allocator, "echo hello", 5);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
    try std.testing.expectEqual(false, result.timed_out);
}

test "runShellCommandWithTimeout - command exceeds timeout" {
    const result = try runShellCommandWithTimeout(std.testing.allocator, "sleep 10", 1);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 124), result.exit_code);
    try std.testing.expectEqual(true, result.timed_out);
}

test "runShellCommandWithTimeout - no timeout (null)" {
    const result = try runShellCommandWithTimeout(std.testing.allocator, "echo hello", null);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "runShellCommandWithTimeout - stderr captured" {
    const result = try runShellCommandWithTimeout(std.testing.allocator, "echo err >&2", null);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "err") != null);
}

test "runShellCommandWithTimeout - exit code preserved" {
    const result = try runShellCommandWithTimeout(std.testing.allocator, "exit 42", null);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expectEqual(@as(u8, 42), result.exit_code);
}
