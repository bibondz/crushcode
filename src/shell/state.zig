const std = @import("std");
const Allocator = std.mem.Allocator;
const array_list_compat = @import("array_list_compat");

/// Manages shell execution state: working directory, environment variable
/// overrides, and last command exit code. All strings stored are owned by
/// the provided allocator.
pub const ShellState = struct {
    allocator: Allocator,
    cwd: []const u8,
    env: std.StringHashMap([]const u8),
    last_exit_code: u8,
    home_dir: ?[]const u8,

    /// Initialize a new ShellState capturing the current process working
    /// directory and HOME environment variable. The env overrides map starts
    /// empty — call `setEnv` to add overrides.
    pub fn init(allocator: Allocator) !ShellState {
        var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
        const raw_cwd = try std.posix.getcwd(&cwd_buf);
        const owned_cwd = try allocator.dupe(u8, raw_cwd);

        const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;

        return .{
            .allocator = allocator,
            .cwd = owned_cwd,
            .env = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .home_dir = home,
        };
    }

    /// Free all owned strings and the env map.
    pub fn deinit(self: *ShellState) void {
        self.allocator.free(self.cwd);
        if (self.home_dir) |h| {
            self.allocator.free(h);
        }

        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();
    }

    /// Change the tracked working directory. Supports "~" expansion (replaced
    /// with the cached home directory). Relative paths are resolved against
    /// the current `self.cwd`. The target must exist and be a directory.
    pub fn updateCwd(self: *ShellState, new_path: []const u8) !void {
        const resolved = try self.resolvePath(new_path);
        defer self.allocator.free(resolved);

        // Validate target exists and is a directory
        std.fs.cwd().access(resolved, .{}) catch
            return error.PathNotFound;

        // Verify it's actually a directory
        var dir = std.fs.cwd().openDir(resolved, .{}) catch
            return error.NotADirectory;
        dir.close();

        self.allocator.free(self.cwd);
        self.cwd = try self.allocator.dupe(u8, resolved);
    }

    /// Return the current tracked working directory.
    pub fn getCwd(self: *const ShellState) []const u8 {
        return self.cwd;
    }

    /// Set an environment variable override. If the key already exists the
    /// old value is freed. Both key and value are duplicated into the
    /// allocator.
    pub fn setEnv(self: *ShellState, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        // If key already exists, free old key+value
        if (self.env.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.env.put(owned_key, owned_value);
    }

    /// Look up an environment variable. Checks the override map first, then
    /// falls back to the current process environment via
    /// `std.process.getEnvVarOwned`.
    pub fn getEnv(self: *const ShellState, key: []const u8) ?[]const u8 {
        if (self.env.get(key)) |val| {
            return val;
        }
        // Fall back to process environment
        return std.process.getEnvVarOwned(self.allocator, key) catch null;
    }

    /// Remove an environment variable override. Frees the owned key and value.
    pub fn removeEnv(self: *ShellState, key: []const u8) void {
        if (self.env.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    /// Build a null-terminated array of "KEY=VALUE" strings suitable for
    /// `std.process.Child`. Starts from the current process environment,
    /// then applies any overrides from `self.env`. Caller must free each
    /// string and the slice via the provided allocator.
    pub fn buildEnvPairs(self: *ShellState, allocator: Allocator) ![][:0]const u8 {
        // Start from current process environment
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        // Override with our values
        var env_iter = self.env.iterator();
        while (env_iter.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Build array of "KEY=VALUE" pairs
        var pairs = array_list_compat.ArrayList([:0]const u8).init(allocator);
        defer pairs.deinit();

        var map_iter = env_map.iterator();
        while (map_iter.next()) |entry| {
            const pair = try std.fmt.allocPrintZ(allocator, "{s}={s}", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            });
            try pairs.append(pair);
        }

        return pairs.toOwnedSlice();
    }

    /// Resolve a path to an absolute path. Expands "~" to the cached home
    /// directory and resolves relative paths against `self.cwd`. The
    /// returned string is owned by the caller.
    pub fn resolvePath(self: *ShellState, path: []const u8) ![]const u8 {
        const expanded = expandTilde: {
            if (path.len > 0 and path[0] == '~') {
                if (self.home_dir) |home| {
                    if (path.len == 1) {
                        break :expandTilde try self.allocator.dupe(u8, home);
                    } else {
                        break :expandTilde try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, path[1..] });
                    }
                }
            }
            break :expandTilde try self.allocator.dupe(u8, path);
        };
        errdefer self.allocator.free(expanded);

        // If already absolute, return as-is
        if (std.fs.path.isAbsolute(expanded)) {
            return expanded;
        }

        // Resolve relative against cwd
        const resolved = try std.fs.path.resolve(self.allocator, &[_][]const u8{ self.cwd, expanded });
        self.allocator.free(expanded);
        return resolved;
    }

    /// Store the exit code from the last executed command.
    pub fn setExitCode(self: *ShellState, code: u8) void {
        self.last_exit_code = code;
    }

    /// Retrieve the exit code of the last executed command.
    pub fn getExitCode(self: *const ShellState) u8 {
        return self.last_exit_code;
    }
};

// -- Tests --------------------------------------------------------------------

test "ShellState init/deinit captures cwd and home" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    try testing.expect(state.cwd.len > 0);
    try testing.expect(state.home_dir != null);
    try testing.expect(state.last_exit_code == 0);
}

test "setEnv/getEnv/removeEnv round-trip" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    try state.setEnv("CRUSH_TEST_KEY", "hello");
    const val = state.getEnv("CRUSH_TEST_KEY").?;
    try testing.expectEqualStrings("hello", val);

    // Override
    try state.setEnv("CRUSH_TEST_KEY", "world");
    const val2 = state.getEnv("CRUSH_TEST_KEY").?;
    try testing.expectEqualStrings("world", val2);

    // Remove
    state.removeEnv("CRUSH_TEST_KEY");
    // After removal, falls back to process env (likely null)
    const after = state.getEnv("CRUSH_TEST_KEY");
    try testing.expect(after == null);
}

test "resolvePath expands tilde and resolves relative" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    // Tilde alone
    const home = state.resolvePath("~") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer state.allocator.free(home);
    if (state.home_dir) |h| {
        try testing.expectEqualStrings(h, home);
    }

    // Absolute path returned as-is
    const abs = try state.resolvePath("/tmp");
    defer state.allocator.free(abs);
    try testing.expect(std.fs.path.isAbsolute(abs));
}

test "exitCode set/get" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(@as(u8, 0), state.getExitCode());
    state.setExitCode(42);
    try testing.expectEqual(@as(u8, 42), state.getExitCode());
}

test "buildEnvPairs produces KEY=VALUE strings" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    try state.setEnv("CRUSH_ENV_TEST", "value123");

    const pairs = try state.buildEnvPairs(testing.allocator);
    defer {
        for (pairs) |p| testing.allocator.free(p);
        testing.allocator.free(pairs);
    }

    var found = false;
    for (pairs) |p| {
        if (std.mem.indexOf(u8, p, "CRUSH_ENV_TEST=value123") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "updateCwd rejects non-existent path" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    const result = state.updateCwd("/no/such/directory/ever");
    try testing.expectError(error.PathNotFound, result);
}

test "getCwd returns current tracked directory" {
    const testing = std.testing;
    var state = try ShellState.init(testing.allocator);
    defer state.deinit();

    const cwd = state.getCwd();
    try testing.expect(cwd.len > 0);
    try testing.expect(std.fs.path.isAbsolute(cwd));
}
