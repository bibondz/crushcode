const std = @import("std");

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
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
