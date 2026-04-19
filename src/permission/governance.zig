const std = @import("std");

const Allocator = std.mem.Allocator;

/// Governance zone classification for operations.
pub const GovernanceZone = enum {
    /// Execute immediately (safe: read files, search, lint)
    auto,
    /// Ask user first (code edits, new files, config changes)
    propose,
    /// Always block (delete files, force push, merge to main)
    never,
};

/// Governance policy that maps operations to governance zones.
pub const GovernancePolicy = struct {
    allocator: Allocator,
    policies: std.StringHashMap(GovernanceZone),

    /// Initialize with default policies.
    pub fn init(allocator: Allocator) GovernancePolicy {
        var self = GovernancePolicy{
            .allocator = allocator,
            .policies = std.StringHashMap(GovernanceZone).init(allocator),
        };

        self.addDefaults() catch {};
        return self;
    }

    /// Free all owned policy keys and the hash map.
    pub fn deinit(self: *GovernancePolicy) void {
        var iter = self.policies.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.policies.deinit();
    }

    /// Get the governance zone for an operation.
    /// Returns .propose as default if the operation is not found.
    pub fn getZone(self: *const GovernancePolicy, operation: []const u8) GovernanceZone {
        return self.policies.get(operation) orelse .propose;
    }

    /// Override the zone for an operation.
    pub fn setZone(self: *GovernancePolicy, operation: []const u8, zone: GovernanceZone) !void {
        const owned_key = try self.allocator.dupe(u8, operation);
        errdefer self.allocator.free(owned_key);

        // If key already exists, free the old one
        const result = try self.policies.fetchPut(owned_key, zone);
        if (result) |old| {
            self.allocator.free(old.key);
        }
    }

    /// True if the operation is in the .auto zone (can proceed immediately).
    pub fn isAllowed(self: *const GovernancePolicy, operation: []const u8) bool {
        return self.getZone(operation) == .auto;
    }

    /// True if the operation is in the .propose zone (needs user approval).
    pub fn needsApproval(self: *const GovernancePolicy, operation: []const u8) bool {
        return self.getZone(operation) == .propose;
    }

    /// True if the operation is in the .never zone (always blocked).
    pub fn isBlocked(self: *const GovernancePolicy, operation: []const u8) bool {
        return self.getZone(operation) == .never;
    }

    /// Populate default governance policies.
    fn addDefaults(self: *GovernancePolicy) !void {
        // AUTO operations — execute immediately
        const auto_ops = [_][]const u8{
            "file_read",
            "search",
            "grep",
            "glob",
            "lint",
            "memory_update",
            "log_read",
            "status_check",
            "session_list",
        };
        for (auto_ops) |op| {
            const key = try self.allocator.dupe(u8, op);
            try self.policies.put(key, .auto);
        }

        // PROPOSE operations — ask user first
        const propose_ops = [_][]const u8{
            "file_write",
            "file_edit",
            "shell_exec",
            "code_edit",
            "config_change",
            "install_package",
            "git_commit",
        };
        for (propose_ops) |op| {
            const key = try self.allocator.dupe(u8, op);
            try self.policies.put(key, .propose);
        }

        // NEVER operations — always blocked
        const never_ops = [_][]const u8{
            "file_delete",
            "force_push",
            "merge_main",
            "drop_database",
            "rm_rf",
            "sudo",
            "credential_expose",
        };
        for (never_ops) |op| {
            const key = try self.allocator.dupe(u8, op);
            try self.policies.put(key, .never);
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "GovernancePolicy - default AUTO operations are allowed" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    try testing.expect(policy.isAllowed("file_read"));
    try testing.expect(policy.isAllowed("search"));
    try testing.expect(policy.isAllowed("grep"));
    try testing.expect(policy.isAllowed("glob"));
    try testing.expect(policy.isAllowed("lint"));
    try testing.expect(policy.isAllowed("memory_update"));
    try testing.expect(policy.isAllowed("log_read"));
    try testing.expect(policy.isAllowed("status_check"));
    try testing.expect(policy.isAllowed("session_list"));
}

test "GovernancePolicy - default NEVER operations are blocked" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    try testing.expect(policy.isBlocked("file_delete"));
    try testing.expect(policy.isBlocked("force_push"));
    try testing.expect(policy.isBlocked("merge_main"));
    try testing.expect(policy.isBlocked("drop_database"));
    try testing.expect(policy.isBlocked("rm_rf"));
    try testing.expect(policy.isBlocked("sudo"));
    try testing.expect(policy.isBlocked("credential_expose"));
}

test "GovernancePolicy - PROPOSE operations need approval" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    try testing.expect(policy.needsApproval("file_write"));
    try testing.expect(policy.needsApproval("file_edit"));
    try testing.expect(policy.needsApproval("shell_exec"));
    try testing.expect(policy.needsApproval("code_edit"));
    try testing.expect(policy.needsApproval("config_change"));
    try testing.expect(policy.needsApproval("install_package"));
    try testing.expect(policy.needsApproval("git_commit"));
}

test "GovernancePolicy - unknown operations default to propose" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    try testing.expect(policy.needsApproval("unknown_operation"));
    try testing.expect(!policy.isAllowed("unknown_operation"));
    try testing.expect(!policy.isBlocked("unknown_operation"));
}

test "GovernancePolicy - custom zone override works" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    // "file_read" starts as AUTO
    try testing.expect(policy.isAllowed("file_read"));

    // Override to NEVER
    try policy.setZone("file_read", .never);
    try testing.expect(policy.isBlocked("file_read"));
    try testing.expect(!policy.isAllowed("file_read"));

    // Override to PROPOSE
    try policy.setZone("file_read", .propose);
    try testing.expect(policy.needsApproval("file_read"));
}

test "GovernancePolicy - getZone returns correct zones" {
    const allocator = std.testing.allocator;
    var policy = GovernancePolicy.init(allocator);
    defer policy.deinit();

    try testing.expectEqual(GovernanceZone.auto, policy.getZone("file_read"));
    try testing.expectEqual(GovernanceZone.propose, policy.getZone("file_write"));
    try testing.expectEqual(GovernanceZone.never, policy.getZone("file_delete"));
    try testing.expectEqual(GovernanceZone.propose, policy.getZone("unknown_op"));
}
