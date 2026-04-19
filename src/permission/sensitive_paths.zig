const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

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
