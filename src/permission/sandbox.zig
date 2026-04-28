const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SandboxMode = enum { off, cwd, custom };

pub const SandboxConfig = struct {
    mode: SandboxMode = .cwd,
    custom_path: ?[]const u8 = null,
};

pub const SandboxResult = struct {
    allowed: bool,
    reason: ?[]const u8 = null,
};

pub const SandboxChecker = struct {
    allocator: Allocator,
    config: SandboxConfig,
    cwd: []const u8,

    pub fn init(allocator: Allocator, config: SandboxConfig, cwd: []const u8) SandboxChecker {
        return SandboxChecker{
            .allocator = allocator,
            .config = config,
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *SandboxChecker) void {
        if (self.config.custom_path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn isCommandAllowed(self: *SandboxChecker, command: []const u8) !SandboxResult {
        // If sandbox is off, everything is allowed
        if (self.config.mode == .off) {
            return SandboxResult{ .allowed = true };
        }

        // Split command by &&, ||, ; to handle chained commands
        const parts = try self.splitCommands(command);
        defer {
            for (parts) |p| self.allocator.free(p);
            self.allocator.free(parts);
        }

        // Check each command part
        for (parts) |part| {
            const targets = try self.extractWriteTargets(part);
            defer {
                for (targets) |t| {
                    self.allocator.free(t);
                }
                self.allocator.free(targets);
            }

            // If no write targets in this part, continue
            if (targets.len == 0) {
                continue;
            }

            // Determine allowed prefix based on mode
            const allowed_prefix = if (self.config.mode == .custom) self.config.custom_path.? else self.cwd;

            // Check each target
            for (targets) |target| {
                if (!std.mem.startsWith(u8, target, allowed_prefix)) {
                    return SandboxResult{
                        .allowed = false,
                        .reason = "Write target outside sandbox boundary",
                    };
                }
            }
        }

        return SandboxResult{ .allowed = true };
    }

    fn splitCommands(self: *SandboxChecker, command: []const u8) ![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer {
            for (parts.items) |p| self.allocator.free(p);
            parts.deinit(self.allocator);
        }

        var start: usize = 0;
        var in_quote = false;
        var quote_char: u8 = 0;

        for (command, 0..) |c, i| {
            if (!in_quote and (c == '"' or c == '\'')) {
                in_quote = true;
                quote_char = c;
            } else if (in_quote and c == quote_char) {
                in_quote = false;
            } else if (!in_quote and (c == '&' or c == '|' or c == ';')) {
                // Check if this is part of && or ||
                if (i > 0 and command[i - 1] == c) {
                    // This is the second character of && or ||
                    const part = std.mem.trim(u8, command[start .. i - 1], " \t\r\n");
                    if (part.len > 0) {
                        try parts.append(self.allocator, try self.allocator.dupe(u8, part));
                    }
                    start = i + 1;
                } else if (i == command.len - 1 or command[i + 1] != c) {
                    // This is a single & or | or ;
                    const part = std.mem.trim(u8, command[start..i], " \t\r\n");
                    if (part.len > 0) {
                        try parts.append(self.allocator, try self.allocator.dupe(u8, part));
                    }
                    start = i + 1;
                }
            }
        }

        // Add the last part
        const last_part = std.mem.trim(u8, command[start..], " \t\r\n");
        if (last_part.len > 0) {
            try parts.append(self.allocator, try self.allocator.dupe(u8, last_part));
        }

        return parts.toOwnedSlice(self.allocator);
    }

    fn extractWriteTargets(self: *SandboxChecker, command: []const u8) ![][]const u8 {
        var targets: std.ArrayList([]const u8) = .empty;
        defer {
            for (targets.items) |t| self.allocator.free(t);
            targets.deinit(self.allocator);
        }

        // Lowercase for case-insensitive matching
        const lower_cmd = try self.allocator.dupe(u8, command);
        defer self.allocator.free(lower_cmd);
        for (lower_cmd, 0..) |c, i| {
            lower_cmd[i] = std.ascii.toLower(c);
        }

        // Check for redirects: > and >>
        var iter = std.mem.splitScalar(u8, lower_cmd, '>');
        var part_idx: usize = 0;
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (part_idx > 0 and trimmed.len > 0) {
                // This is after a > or >>, extract the target
                // Resolve path
                const resolved = try self.resolvePath(trimmed);
                try targets.append(self.allocator, resolved);
            }
            part_idx += 1;
        }

        // Check for write commands: tee, cp, mv, install, dd, rsync, scp
        const write_commands = [_][]const u8{
            "tee ",
            "cp ",
            "mv ",
            "install ",
            "dd ",
            "rsync ",
            "scp ",
        };

        for (write_commands) |cmd| {
            if (std.mem.indexOf(u8, lower_cmd, cmd)) |_| {
                // Extract the last non-flag argument as the target
                const args = try self.parseArgs(command);
                defer {
                    for (args) |a| self.allocator.free(a);
                    self.allocator.free(args);
                }

                var last_non_flag: ?[]const u8 = null;
                for (args) |arg| {
                    if (arg.len == 0) continue;
                    if (arg[0] == '-') continue; // Skip flags
                    if (std.mem.eql(u8, arg, "|")) continue; // Skip pipe symbols
                    if (last_non_flag) |prev| {
                        self.allocator.free(prev);
                    }
                    last_non_flag = try self.allocator.dupe(u8, arg);
                }

                if (last_non_flag) |target| {
                    const resolved = try self.resolvePath(target);
                    try targets.append(self.allocator, resolved);
                    self.allocator.free(target);
                }
            }
        }

        return targets.toOwnedSlice(self.allocator);
    }

    fn resolvePath(self: *SandboxChecker, path: []const u8) ![]const u8 {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, path, " \t\r\n");

        // If already absolute, return normalized path
        if (std.fs.path.isAbsolute(trimmed)) {
            return self.normalizePath(trimmed);
        }

        // Prepend cwd and normalize
        const joined = try std.fs.path.join(self.allocator, &.{ self.cwd, trimmed });
        defer self.allocator.free(joined);
        return self.normalizePath(joined);
    }

    fn normalizePath(self: *SandboxChecker, path: []const u8) ![]const u8 {
        // Use std.fs.path.resolve to normalize .. and .
        const resolved = try std.fs.path.resolve(self.allocator, &.{path});
        return resolved;
    }

    fn parseArgs(self: *SandboxChecker, command: []const u8) ![][]const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
        }

        var iter = std.mem.tokenizeScalar(u8, command, ' ');
        while (iter.next()) |arg| {
            // Trim quotes
            const trimmed = std.mem.trim(u8, arg, "\"'");
            try args.append(self.allocator, try self.allocator.dupe(u8, trimmed));
        }

        return args.toOwnedSlice(self.allocator);
    }
};

// ==================== Tests ====================

const testing = std.testing;

test "Test 1: Write to cwd subpath allowed" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("echo hello > out.txt");
    try testing.expect(result.allowed);
}

test "Test 2: Write to /tmp blocked" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("echo hello > /tmp/out.txt");
    try testing.expect(!result.allowed);
    try testing.expect(result.reason != null);
}

test "Test 3: Write to parent dir blocked" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user/project";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("echo hello > ../out.txt");
    try testing.expect(!result.allowed);
}

test "Test 4: Read command always allowed" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("ls -la");
    try testing.expect(result.allowed);
}

test "Test 5: Pipe without redirect allowed" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("cat file | grep foo");
    try testing.expect(result.allowed);
}

test "Test 6: Multiple writes mixed" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("cp a.txt /tmp/b.txt && echo ok > local.txt");
    try testing.expect(!result.allowed);
}

test "Test 7: Sandbox off allows everything" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .off };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("rm -rf /tmp/test");
    try testing.expect(result.allowed);
}

test "Test 8: Custom path allows writes" {
    const allocator = testing.allocator;
    const custom_path = try allocator.dupe(u8, "/custom/dir");
    // Note: Don't free custom_path here - ownership is transferred to config

    const config = SandboxConfig{
        .mode = .custom,
        .custom_path = custom_path,
    };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit(); // This will free custom_path

    const result = try checker.isCommandAllowed("echo ok > /custom/dir/f.txt");
    try testing.expect(result.allowed);
}

test "Test 9: tee detected as write" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("echo hello | tee /tmp/log.txt");
    try testing.expect(!result.allowed);
}

test "Test 10: install detected as write" {
    const allocator = testing.allocator;
    const config = SandboxConfig{ .mode = .cwd };
    const cwd = "/home/user";
    var checker = SandboxChecker.init(allocator, config, cwd);
    defer checker.deinit();

    const result = try checker.isCommandAllowed("install -m 755 script /usr/local/bin/");
    try testing.expect(!result.allowed);
}
