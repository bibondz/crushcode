const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");

const Allocator = std.mem.Allocator;

/// Re-export types from the existing knowledge_lint module
pub const LintSeverity = enum {
    critical,
    warning,
    info,
};

pub const LintRule = enum {
    orphan,
    stale,
    conflicting,
    unattributed,
    duplicate,
    broken_ref,
    low_confidence,
};

/// A single lint finding about knowledge quality
pub const LintFinding = struct {
    allocator: Allocator,
    severity: LintSeverity,
    rule: LintRule,
    message: []const u8,
    location: ?[]const u8,
    suggestion: ?[]const u8,

    pub fn init(allocator: Allocator, severity: LintSeverity, rule: LintRule, message: []const u8) !LintFinding {
        return LintFinding{
            .allocator = allocator,
            .severity = severity,
            .rule = rule,
            .message = try allocator.dupe(u8, message),
            .location = null,
            .suggestion = null,
        };
    }

    pub fn deinit(self: *LintFinding) void {
        self.allocator.free(self.message);
        if (self.location) |l| self.allocator.free(l);
        if (self.suggestion) |s| self.allocator.free(s);
    }

    pub fn withLocation(self: *LintFinding, location: []const u8) !void {
        self.location = try self.allocator.dupe(u8, location);
    }

    pub fn withSuggestion(self: *LintFinding, suggestion: []const u8) !void {
        self.suggestion = try self.allocator.dupe(u8, suggestion);
    }
};

/// Health checker for the knowledge vault.
/// Reuses patterns from existing `src/core/knowledge_lint.zig`.
///
/// Reference: Second-brain lint patterns (F48)
pub const KnowledgeLinter = struct {
    allocator: Allocator,
    vault: *schema.KnowledgeVault,
    /// Maximum age in seconds before a node is considered stale (30 days)
    stale_threshold_seconds: u64 = 30 * 24 * 60 * 60,

    pub fn init(allocator: Allocator, vault: *schema.KnowledgeVault) KnowledgeLinter {
        return KnowledgeLinter{
            .allocator = allocator,
            .vault = vault,
            .stale_threshold_seconds = 30 * 24 * 60 * 60,
        };
    }

    /// Run all lint checks on the vault
    pub fn lint(self: *KnowledgeLinter) ![]*LintFinding {
        var findings = array_list_compat.ArrayList(*LintFinding).init(self.allocator);
        defer findings.deinit();

        // Build ID set for reference checking
        var id_set = std.StringHashMap(void).init(self.allocator);
        defer id_set.deinit();
        var iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            try id_set.put(entry.key_ptr.*, {});
        }

        // Build citation graph: who cites whom
        var cited_by = std.StringHashMap(array_list_compat.ArrayList([]const u8)).init(self.allocator);
        defer {
            var cb_iter = cited_by.iterator();
            while (cb_iter.next()) |entry| {
                for (entry.value_ptr.items) |id| self.allocator.free(id);
                entry.value_ptr.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            cited_by.deinit();
        }

        iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;
            for (node.citations.items) |cit| {
                const gop = try cited_by.getOrPut(cit);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.allocator.dupe(u8, cit);
                    gop.value_ptr.* = array_list_compat.ArrayList([]const u8).init(self.allocator);
                }
                try gop.value_ptr.append(try self.allocator.dupe(u8, node.id));
            }
        }

        // Collect nodes for pairwise checks
        var all_nodes = array_list_compat.ArrayList(*schema.KnowledgeNode).init(self.allocator);
        defer all_nodes.deinit();
        iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            try all_nodes.append(entry.value_ptr.*);
        }

        // Run per-node checks
        for (all_nodes.items) |node| {
            // Orphan detection: not cited by any other node
            const is_cited = cited_by.get(node.id) != null;
            if (!is_cited and self.vault.count() > 1) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .info, .orphan, "Knowledge node is not referenced by any other node");
                try f.withLocation(node.id);
                try f.withSuggestion("Consider if this knowledge is still needed or if references should be added");
                try findings.append(f);
            }

            // Stale detection: not updated in >30 days
            const now = std.time.timestamp();
            const age = now - node.updated_at;
            if (age > @as(i64, @intCast(self.stale_threshold_seconds))) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .warning, .stale, "Knowledge node has not been updated in over 30 days");
                try f.withLocation(node.id);
                try findings.append(f);
            }

            // Unattributed (no source path)
            if (node.source_path == null) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .warning, .unattributed, "Knowledge node has no source attribution");
                try f.withLocation(node.id);
                try f.withSuggestion("Add source provenance to track where this knowledge came from");
                try findings.append(f);
            }

            // Broken references: citations pointing to non-existent nodes
            for (node.citations.items) |cit| {
                if (!id_set.contains(cit)) {
                    const f = try self.allocator.create(LintFinding);
                    f.* = try LintFinding.init(self.allocator, .critical, .broken_ref, "Citation references non-existent knowledge node");
                    try f.withLocation(node.id);
                    try f.withSuggestion(cit);
                    try findings.append(f);
                }
            }

            // Low confidence
            if (node.confidence < 0.3) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .warning, .low_confidence, "Knowledge confidence is below 0.3 threshold");
                try f.withLocation(node.id);
                try findings.append(f);
            }
        }

        // Duplicate detection: nodes with similar titles (>80% name overlap)
        for (all_nodes.items, 0..) |n1, i| {
            for (all_nodes.items[i + 1 ..]) |n2| {
                const similarity = computeNameSimilarity(n1.title, n2.title);
                if (similarity > 0.8) {
                    const msg = try std.fmt.allocPrint(self.allocator, "Similar titles: '{s}' and '{s}' ({d:.0}% overlap)", .{ n1.title, n2.title, similarity * 100.0 });
                    defer self.allocator.free(msg);
                    const f = try self.allocator.create(LintFinding);
                    f.* = try LintFinding.init(self.allocator, .info, .duplicate, msg);
                    try f.withLocation(n1.id);
                    try f.withSuggestion(n2.id);
                    try findings.append(f);
                }
            }
        }

        return findings.toOwnedSlice();
    }

    /// Lint a single node by ID
    pub fn lintNode(self: *KnowledgeLinter, node_id: []const u8) ![]*LintFinding {
        var findings = array_list_compat.ArrayList(*LintFinding).init(self.allocator);
        defer findings.deinit();

        const node = self.vault.getNode(node_id) orelse return &.{};

        // Stale check
        const now = std.time.timestamp();
        const age = now - node.updated_at;
        if (age > @as(i64, @intCast(self.stale_threshold_seconds))) {
            const f = try self.allocator.create(LintFinding);
            f.* = try LintFinding.init(self.allocator, .warning, .stale, "Knowledge node has not been updated recently");
            try f.withLocation(node.id);
            try findings.append(f);
        }

        // Unattributed
        if (node.source_path == null) {
            const f = try self.allocator.create(LintFinding);
            f.* = try LintFinding.init(self.allocator, .warning, .unattributed, "Knowledge node has no source attribution");
            try f.withLocation(node.id);
            try findings.append(f);
        }

        // Low confidence
        if (node.confidence < 0.3) {
            const f = try self.allocator.create(LintFinding);
            f.* = try LintFinding.init(self.allocator, .warning, .low_confidence, "Knowledge confidence is below threshold");
            try f.withLocation(node.id);
            try findings.append(f);
        }

        return findings.toOwnedSlice();
    }
};

/// Compute simple name similarity using character overlap ratio.
/// Returns 0.0-1.0 where 1.0 means identical.
fn computeNameSimilarity(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 and b.len == 0) return 1.0;
    if (a.len == 0 or b.len == 0) return 0.0;

    // Exact match
    if (std.mem.eql(u8, a, b)) return 1.0;

    // Simple character overlap: count matching characters in order
    const min_len = @min(a.len, b.len);
    const max_len = @max(a.len, b.len);
    var matches: usize = 0;
    for (0..min_len) |i| {
        const ca = if (a[i] >= 'A' and a[i] <= 'Z') a[i] + 32 else a[i];
        const cb = if (b[i] >= 'A' and b[i] <= 'Z') b[i] + 32 else b[i];
        if (ca == cb) matches += 1;
    }
    return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(max_len));
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "KnowledgeLinter detects orphans" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Orphan", "content", .file);
    try n1.setSourcePath("test.md");
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "k2", "Other", "other content", .file);
    try n2.setSourcePath("test2.md");
    try n2.addCitation("k1"); // k1 is cited, k2 is orphan
    try vault.addNode(n2);

    var linter = KnowledgeLinter.init(testing.allocator, &vault);
    const findings = try linter.lint();
    defer {
        for (findings) |f| {
            f.deinit();
            testing.allocator.destroy(f);
        }
        testing.allocator.free(findings);
    }

    // k2 should be orphan (no one cites it), k1 should not be (k2 cites it)
    var orphan_count: u32 = 0;
    for (findings) |f| {
        if (f.rule == .orphan) orphan_count += 1;
    }
    try testing.expect(orphan_count >= 1);
}

test "KnowledgeLinter detects broken refs" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Test", "content", .file);
    try n1.setSourcePath("test.md");
    try n1.addCitation("nonexistent_ref");
    try vault.addNode(n1);

    var linter = KnowledgeLinter.init(testing.allocator, &vault);
    const findings = try linter.lint();
    defer {
        for (findings) |f| {
            f.deinit();
            testing.allocator.destroy(f);
        }
        testing.allocator.free(findings);
    }

    var broken_count: u32 = 0;
    for (findings) |f| {
        if (f.rule == .broken_ref) broken_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), broken_count);
}

test "KnowledgeLinter lintNode" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Test", "content", .ai_generated);
    n1.confidence = 0.1; // Low confidence
    try vault.addNode(n1);

    var linter = KnowledgeLinter.init(testing.allocator, &vault);
    const findings = try linter.lintNode("k1");
    defer {
        for (findings) |f| {
            f.deinit();
            testing.allocator.destroy(f);
        }
        testing.allocator.free(findings);
    }

    try testing.expect(findings.len > 0);
}

test "computeNameSimilarity" {
    try testing.expect(computeNameSimilarity("hello", "hello") == 1.0);
    try testing.expect(computeNameSimilarity("", "") == 1.0);
    try testing.expect(computeNameSimilarity("abc", "") == 0.0);
    try testing.expect(computeNameSimilarity("Hello", "hello") == 1.0);
    try testing.expect(computeNameSimilarity("abcde", "abcdf") > 0.5);
}
