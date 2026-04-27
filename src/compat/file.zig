const std = @import("std");

pub const File = struct {
    const Self = @This();

    handle: std.fs.File.Handle,

    pub const Reader = std.io.GenericReader(File, std.fs.File.ReadError, read);
    pub const Writer = std.io.GenericWriter(File, std.fs.File.WriteError, write);

    pub fn wrap(file: std.fs.File) Self {
        return .{ .handle = file.handle };
    }

    pub fn stdin() Self {
        return Self.wrap(std.fs.File.stdin());
    }

    pub fn stdout() Self {
        return Self.wrap(std.fs.File.stdout());
    }

    pub fn stderr() Self {
        return Self.wrap(std.fs.File.stderr());
    }

    pub fn inner(self: Self) std.fs.File {
        return .{ .handle = self.handle };
    }

    pub fn reader(self: Self) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: Self) Writer {
        return .{ .context = self };
    }

    pub fn read(self: Self, buffer: []u8) std.fs.File.ReadError!usize {
        return self.inner().read(buffer);
    }

    pub fn write(self: Self, bytes: []const u8) std.fs.File.WriteError!usize {
        return self.inner().write(bytes);
    }

    pub fn writeAll(self: Self, bytes: []const u8) std.fs.File.WriteError!void {
        return self.inner().writeAll(bytes);
    }

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) std.fs.File.WriteError!void {
        try self.writer().print(fmt, args);
    }

    pub fn flush(self: Self) std.fs.File.WriteError!void {
        return self.writer().flush();
    }

    pub fn readUntilDelimiter(self: Self, buf: []u8, delimiter: u8) anyerror![]u8 {
        return self.reader().readUntilDelimiter(buf, delimiter);
    }

    pub fn readUntilDelimiterOrEof(self: Self, buf: []u8, delimiter: u8) anyerror!?[]u8 {
        return self.reader().readUntilDelimiterOrEof(buf, delimiter);
    }

    pub fn readUntilDelimiterOrEofAlloc(self: Self, allocator: std.mem.Allocator, delimiter: u8, max_size: usize) anyerror!?[]u8 {
        return self.reader().readUntilDelimiterOrEofAlloc(allocator, delimiter, max_size);
    }

    pub fn sync(self: Self) std.fs.File.SyncError!void {
        return self.inner().sync();
    }

    pub fn close(self: Self) void {
        self.inner().close();
    }
};

pub fn wrap(file: std.fs.File) File {
    return File.wrap(file);
}

/// Cross-platform environment variable getter.
/// On Linux/macOS, uses std.posix.getenv (returns optional sentinel slice).
/// On Windows, uses std.process.getEnvVarOwned (allocates, caller must free).
///
/// For non-Windows targets, returns a borrowed sentinel-terminated slice
/// (no allocation needed). For Windows, the caller must free the result.
///
/// Usage (non-Windows, the common case):
///   const home = file_compat.getEnv("HOME") orelse "";
pub fn getEnv(key: []const u8) ?[:0]const u8 {
    // Use comptime to avoid Windows compile errors
    if (@import("builtin").target.os.tag == .windows) {
        return null; // Windows callers should use getEnvOwned
    }
    return std.posix.getenv(key);
}

/// Allocate-and-copy version of getEnv. Works on ALL platforms.
/// Caller owns the returned slice and must free it with allocator.
/// Returns null if the variable is not set.
pub fn getEnvOwned(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const result = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    return result;
}
