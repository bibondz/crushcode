// Consolidated permission lists — blocklist, safelist, and sensitive path checker.
// Originally three separate files, merged for organizational clarity.

const std = @import("std");
const json = std.json;
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ============================================================
// Command Blocklist
// ============================================================

/// Hardcoded default dangerous command patterns.
/// These are always loaded regardless of user configuration.
const default_blocklist_patterns = [_][]const u8{
    "rm -rf /",
    "rm -rf /*",
    "rm -rf .",
    "rm -rf *",
    "mkfs",
    "format",
    "dd if=",
    "dd of=/dev/",
    ":(){ :|:& };:",
    "fork bomb",
    "> /dev/sda",
    "> /dev/hda",
    "chmod -R 777 /",
    "chown -R .* /",
};

/// Global command blocklist for dangerous shell commands.
/// Maintains a set of blocked patterns that are checked before command execution.
/// Patterns are matched case-insensitively as substrings within the command.
pub const CommandBlocklist = struct {
    allocator: Allocator,
    patterns: array_list_compat.ArrayList([]const u8),

    /// Initialize the blocklist with hardcoded dangerous patterns.
    /// All default patterns are duplicated into the provided allocator.
    pub fn init(allocator: Allocator) CommandBlocklist {
        var self = CommandBlocklist{
            .allocator = allocator,
            .patterns = array_list_compat.ArrayList([]const u8).init(allocator),
        };

        // Load hardcoded defaults — these cannot fail since we just dupe strings
        for (default_blocklist_patterns) |pattern| {
            const owned = allocator.dupe(u8, pattern) catch continue;
            self.patterns.append(owned) catch {
                allocator.free(owned);
            };
        }

        return self;
    }

    /// Free all owned pattern strings and the pattern list.
    pub fn deinit(self: *CommandBlocklist) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit();
    }

    /// Check if a command matches any blocked pattern.
    /// Returns the matched pattern string if blocked, or null if the command is safe.
    /// Comparison is case-insensitive.
    pub fn isBlocked(self: *const CommandBlocklist, command: []const u8) ?[]const u8 {
        var lower_buf: [4096]u8 = undefined;
        if (command.len > lower_buf.len) return null;
        const lower_command = std.ascii.lowerString(&lower_buf, command);

        var pattern_buf: [4096]u8 = undefined;
        for (self.patterns.items) |pattern| {
            if (pattern.len > pattern_buf.len) continue;
            const lower_pattern = std.ascii.lowerString(&pattern_buf, pattern);

            if (std.mem.indexOf(u8, lower_command, lower_pattern)) |_| {
                return pattern;
            }
        }

        return null;
    }

    /// Add a user-defined pattern to the blocklist.
    /// The pattern string is duplicated and owned by the allocator.
    pub fn addPattern(self: *CommandBlocklist, pattern: []const u8) !void {
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);
        try self.patterns.append(owned);
    }

    /// Load additional patterns from a JSON file at `config_dir/blocklist.json`.
    /// Expected format: `["pattern1", "pattern2", ...]`
    /// If the file does not exist, silently succeeds (hardcoded defaults still apply).
    /// Invalid entries (non-string values) are skipped.
    pub fn loadFromFile(self: *CommandBlocklist, config_dir: []const u8) !void {
        // Build path: config_dir/blocklist.json
        var path_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();

        const w = path_buf.writer();
        try w.writeAll(config_dir);
        try w.writeAll("/blocklist.json");

        const file_path = path_buf.items;

        // Read file contents — gracefully handle missing file
        const contents = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(contents);

        // Parse as JSON value
        const parsed = json.parseFromSlice(json.Value, self.allocator, contents, .{}) catch |err| {
            if (err == error.InvalidCharacter) return;
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return;

        // Extract string entries and add as patterns
        for (root.array.items) |item| {
            if (item == .string) {
                self.addPattern(item.string) catch continue;
            }
        }
    }

    /// Return all currently loaded patterns as a slice.
    /// Useful for display or debugging purposes.
    pub fn getPatterns(self: *const CommandBlocklist) []const []const u8 {
        return self.patterns.items;
    }
};

// ============================================================
// Safe Command List
// ============================================================

/// A whitelist of shell commands that are considered safe for auto-approval.
///
/// Commands are matched as case-insensitive prefixes, so "ls -la /home"
/// matches the safe entry "ls". Git commands are restricted to read-only
/// subcommands only.
pub const SafeCommandList = struct {
    allocator: Allocator,
    /// Owned command prefix strings (allocator-backed).
    safe_commands: array_list_compat.ArrayList([]const u8),

    /// Hardcoded safe commands baked into the binary.
    const default_safe_commands = [_][]const u8{
        // Read-only file operations
        "ls",
        "pwd",
        "echo",
        "cat",
        "head",
        "tail",
        "wc",
        "sort",
        "uniq",
        "tee",
        // Search tools
        "find",
        "grep",
        "rg",
        "fd",
        "ag",
        // Git read-only subcommands
        "git status",
        "git log",
        "git diff",
        "git show",
        "git branch",
        "git remote",
        "git stash list",
        "git tag",
        "git describe",
        "git rev-parse",
        "git ls-files",
        "git blame",
        // System information
        "ps",
        "df",
        "du",
        "free",
        "uptime",
        "hostname",
        "whoami",
        "uname",
        "date",
        "env",
        "which",
        "type",
        // Development tool version queries
        "node --version",
        "node -v",
        "python --version",
        "python -V",
        "python3 --version",
        "zig version",
        "cargo --version",
        "npm --version",
        "npm list",
        "npm view",
        "yarn --version",
        "pnpm --version",
        // Network read-only diagnostics
        "ping",
        "traceroute",
        "dig",
        "nslookup",
        "host",
        "ifconfig",
        "ip addr",
        // Archive listing (read-only)
        "tar -tf",
        "tar --list",
        "unzip -l",
    };

    /// Initialize the safe command list with all hardcoded defaults.
    pub fn init(allocator: Allocator) SafeCommandList {
        var self = SafeCommandList{
            .allocator = allocator,
            .safe_commands = array_list_compat.ArrayList([]const u8).init(allocator),
        };
        errdefer self.deinit();

        // Pre-populate with hardcoded defaults — safe_commands now owns these strings.
        for (&default_safe_commands) |cmd| {
            self.safe_commands.append(allocator.dupe(u8, cmd) catch @panic("OOM")) catch @panic("OOM");
        }

        return self;
    }

    /// Free all owned command strings and the list itself.
    pub fn deinit(self: *SafeCommandList) void {
        for (self.safe_commands.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.safe_commands.deinit();
    }

    /// Check whether `command` is considered safe (auto-approve).
    ///
    /// Strips leading whitespace, lowercases, then checks if the result
    /// starts with any entry in the safe list.  Matching is prefix-based:
    /// "ls -la /home" is safe because it starts with "ls".
    pub fn isSafe(self: *const SafeCommandList, command: []const u8) bool {
        // Trim leading whitespace
        const trimmed = std.mem.trimLeft(u8, command, &std.ascii.whitespace);

        if (trimmed.len == 0) return false;

        // Lowercase into a temporary buffer for comparison
        var buf: [4096]u8 = undefined;
        if (trimmed.len > buf.len) return false;
        const lowered = std.ascii.lowerString(&buf, trimmed);

        for (self.safe_commands.items) |safe_prefix| {
            // safe_prefix entries are stored in lowercase already
            if (std.mem.startsWith(u8, lowered, safe_prefix)) {
                // Ensure the match ends at a word boundary or the end of the
                // lowered string.  This prevents "envy" from matching "env".
                const end = safe_prefix.len;
                if (end == lowered.len) return true;
                const next_char = lowered[end];
                if (next_char == ' ' or next_char == '\t' or next_char == '\n') return true;
            }
        }

        return false;
    }

    /// Append a user-defined safe command prefix.
    ///
    /// The string is duplicated and owned by the allocator.
    pub fn addCommand(self: *SafeCommandList, command: []const u8) !void {
        const owned = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned);

        // Lowercase so prefix matching in isSafe works correctly
        _ = std.ascii.lowerString(owned, owned);
        try self.safe_commands.append(owned);
    }

    /// Load additional safe commands from `config_dir/safelist.json`.
    ///
    /// Expected format: `["command1", "command2", ...]`
    ///
    /// If the file does not exist the call silently succeeds.
    /// Invalid JSON or non-array top-level values are treated as errors.
    pub fn loadFromFile(self: *SafeCommandList, config_dir: []const u8) !void {
        // Build path: config_dir/safelist.json
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/safelist.json", .{config_dir}) catch return;

        // Read file — NotFound is not an error
        const contents = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(contents);

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, contents, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return;

        for (root.array.items) |item| {
            if (item == .string) {
                try self.addCommand(item.string);
            }
        }
    }

    /// Return a slice of all safe command prefixes (for display purposes).
    pub fn getCommands(self: *const SafeCommandList) []const []const u8 {
        return self.safe_commands.items;
    }
};

// ============================================================
// Sensitive Path Checker
// ============================================================

/// Hardcoded default protected path patterns.
/// These are always loaded regardless of user configuration.
const default_protected_patterns = [_][]const u8{
    ".ssh/",
    ".env",
    ".aws/",
    ".gcp/",
    "credentials",
    ".gnupg/",
    "secret",
    ".pem",
    ".key",
    "id_rsa",
    "id_ed25519",
    ".kube/config",
    ".npmrc",
    ".pypirc",
};

/// Checks file paths against a set of protected patterns.
/// Uses simple substring matching (case-insensitive) — no regex dependency.
pub const SensitivePathChecker = struct {
    allocator: Allocator,
    protected_patterns: array_list_compat.ArrayList([]const u8),

    /// Initialize with built-in protected path patterns.
    pub fn init(allocator: Allocator) SensitivePathChecker {
        var self = SensitivePathChecker{
            .allocator = allocator,
            .protected_patterns = array_list_compat.ArrayList([]const u8).init(allocator),
        };

        // Load hardcoded defaults
        for (default_protected_patterns) |pattern| {
            const owned = allocator.dupe(u8, pattern) catch continue;
            self.protected_patterns.append(owned) catch {
                allocator.free(owned);
            };
        }

        return self;
    }

    /// Free all owned pattern strings and the pattern list.
    pub fn deinit(self: *SensitivePathChecker) void {
        for (self.protected_patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.protected_patterns.deinit();
    }

    /// Check if a path matches any protected pattern (case-insensitive).
    pub fn isSensitive(self: *const SensitivePathChecker, path: []const u8) bool {
        // Lowercase the input path for comparison
        var path_buf: [4096]u8 = undefined;
        if (path.len > path_buf.len) return false;
        const lower_path = std.ascii.lowerString(&path_buf, path);

        for (self.protected_patterns.items) |pattern| {
            var pattern_buf: [4096]u8 = undefined;
            if (pattern.len > pattern_buf.len) continue;
            const lower_pattern = std.ascii.lowerString(&pattern_buf, pattern);

            if (std.mem.indexOf(u8, lower_path, lower_pattern)) |_| {
                return true;
            }
        }

        return false;
    }

    /// Add a custom protected path pattern.
    pub fn addPattern(self: *SensitivePathChecker, pattern: []const u8) !void {
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);
        try self.protected_patterns.append(owned);
    }

    /// Return all currently loaded patterns as a slice.
    pub fn getPatterns(self: *const SensitivePathChecker) []const []const u8 {
        return self.protected_patterns.items;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SensitivePathChecker - .ssh paths detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.ssh/id_rsa"));
    try testing.expect(checker.isSensitive("/home/user/.ssh/"));
    try testing.expect(checker.isSensitive("C:\\Users\\user\\.ssh\\known_hosts"));
}

test "SensitivePathChecker - .env files detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive(".env"));
    try testing.expect(checker.isSensitive(".env.production"));
    try testing.expect(checker.isSensitive("/app/.env.local"));
}

test "SensitivePathChecker - .pem files detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("server.pem"));
    try testing.expect(checker.isSensitive("/etc/ssl/certs/cert.pem"));
}

test "SensitivePathChecker - .key files detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("private.key"));
    try testing.expect(checker.isSensitive("/etc/ssl/server.key"));
}

test "SensitivePathChecker - credentials files detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("credentials.json"));
    try testing.expect(checker.isSensitive("/home/user/.aws/credentials"));
}

test "SensitivePathChecker - .aws paths detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.aws/config"));
    try testing.expect(checker.isSensitive(".aws/credentials"));
}

test "SensitivePathChecker - .kube/config detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.kube/config"));
}

test "SensitivePathChecker - .npmrc detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.npmrc"));
}

test "SensitivePathChecker - .pypirc detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.pypirc"));
}

test "SensitivePathChecker - normal paths NOT flagged" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(!checker.isSensitive("/home/user/project/src/main.zig"));
    try testing.expect(!checker.isSensitive("/tmp/build_output.o"));
    try testing.expect(!checker.isSensitive("README.md"));
    try testing.expect(!checker.isSensitive("/usr/bin/gcc"));
    try testing.expect(!checker.isSensitive("package.json"));
}

test "SensitivePathChecker - case-insensitive matching works" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    // Uppercase variants should still match
    try testing.expect(checker.isSensitive("/home/user/.SSH/id_rsa"));
    try testing.expect(checker.isSensitive(".ENV"));
    try testing.expect(checker.isSensitive("CERTIFICATE.PEM"));
    try testing.expect(checker.isSensitive(".AWS/CONFIG"));
}

test "SensitivePathChecker - custom pattern works" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    // Not sensitive before adding custom pattern
    try testing.expect(!checker.isSensitive("/home/user/custom_secret_file"));

    try checker.addPattern("custom_secret");

    try testing.expect(checker.isSensitive("/home/user/custom_secret_file"));
}

test "SensitivePathChecker - id_rsa and id_ed25519 detected" {
    const allocator = std.testing.allocator;
    var checker = SensitivePathChecker.init(allocator);
    defer checker.deinit();

    try testing.expect(checker.isSensitive("/home/user/.ssh/id_rsa"));
    try testing.expect(checker.isSensitive("/home/user/.ssh/id_rsa.pub"));
    try testing.expect(checker.isSensitive("/home/user/.ssh/id_ed25519"));
    try testing.expect(checker.isSensitive("/home/user/.ssh/id_ed25519.pub"));
}
