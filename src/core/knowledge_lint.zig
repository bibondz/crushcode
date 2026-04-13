const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Severity of a knowledge lint issue
pub const LintSeverity = enum {
    critical, // Factually wrong or dangerous
    warning, // Potentially outdated or inconsistent
    info, // Informational suggestion
};

/// A single lint finding about knowledge quality
pub const LintFinding = struct {
    allocator: Allocator,
    severity: LintSeverity,
    rule: LintRule,
    message: []const u8,
    location: ?[]const u8, // File path or knowledge ID
    suggestion: ?[]const u8,

    pub const LintRule = enum {
        orphan, // Knowledge not referenced by anything
        stale, // Not updated in a long time
        conflicting, // Contradicts other knowledge
        unattributed, // No source provenance
        duplicate, // Duplicate of existing knowledge
        broken_ref, // References non-existent knowledge
        low_confidence, // Source confidence below threshold
    };

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

    pub fn withLocation(self: *LintFinding, location: []const u8) !*LintFinding {
        self.location = try self.allocator.dupe(u8, location);
        return self;
    }

    pub fn withSuggestion(self: *LintFinding, suggestion: []const u8) !*LintFinding {
        self.suggestion = try self.allocator.dupe(u8, suggestion);
        return self;
    }
};

/// Result of a knowledge lint pass
pub const LintResult = struct {
    findings: array_list_compat.ArrayList(*LintFinding),
    total_checked: u32,
    pass_rate: f64,

    pub fn init(allocator: Allocator) LintResult {
        return LintResult{
            .findings = array_list_compat.ArrayList(*LintFinding).init(allocator),
            .total_checked = 0,
            .pass_rate = 100.0,
        };
    }

    pub fn deinit(self: *LintResult) void {
        for (self.findings.items) |f| {
            f.deinit();
            // Note: allocator not stored in LintResult — caller manages
        }
        self.findings.deinit();
    }

    pub fn countBySeverity(self: *const LintResult, severity: LintSeverity) u32 {
        var count: u32 = 0;
        for (self.findings.items) |f| {
            if (f.severity == severity) count += 1;
        }
        return count;
    }

    pub fn countByRule(self: *const LintResult, rule: LintFinding.LintRule) u32 {
        var count: u32 = 0;
        for (self.findings.items) |f| {
            if (f.rule == rule) count += 1;
        }
        return count;
    }
};

/// Knowledge Lint configuration
pub const KnowledgeLintConfig = struct {
    /// Maximum age in seconds before knowledge is considered stale (default: 7 days)
    stale_threshold_seconds: u64 = 7 * 24 * 60 * 60,
    /// Minimum confidence score before flagging (default: 0.5)
    min_confidence: f64 = 0.5,
    /// Enable specific rules
    check_orphans: bool = true,
    check_stale: bool = true,
    check_conflicts: bool = true,
    check_unattributed: bool = true,
    check_duplicates: bool = true,
    check_broken_refs: bool = true,
    check_low_confidence: bool = true,
};

/// Knowledge entry to lint (simplified interface)
pub const KnowledgeEntry = struct {
    id: []const u8,
    content: []const u8,
    confidence: f64,
    has_source: bool,
    references: [][]const u8,
    referenced_by: [][]const u8,
    updated_at: i64,
};

/// Knowledge Lint — validates knowledge quality and consistency.
/// Scans for orphans, stale data, conflicts, broken references, etc.
///
/// Usage:
///   var linter = KnowledgeLinter.init(allocator, .{});
///   const result = try linter.lint(entries);
///   defer result.deinit();
///   // Check result.findings for issues
///
/// Reference: LLM Wiki Guide knowledge lint (F18)
pub const KnowledgeLinter = struct {
    allocator: Allocator,
    config: KnowledgeLintConfig,

    pub fn init(allocator: Allocator, config: KnowledgeLintConfig) KnowledgeLinter {
        return KnowledgeLinter{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Run lint checks on a set of knowledge entries
    pub fn lint(self: *KnowledgeLinter, entries: []const KnowledgeEntry) !LintResult {
        var result = LintResult.init(self.allocator);
        errdefer result.deinit();
        result.total_checked = @intCast(entries.len);

        // Build ID set for reference checking
        var id_set = std.StringHashMap(void).init(self.allocator);
        defer id_set.deinit();
        for (entries) |e| {
            try id_set.put(e.id, {});
        }

        for (entries) |entry| {
            // Check: orphan (not referenced by anything)
            if (self.config.check_orphans and entry.referenced_by.len == 0) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .info, .orphan, "Knowledge entry is not referenced by any other entry");
                try f.withLocation(entry.id);
                try f.withSuggestion("Consider if this knowledge is still needed or if references should be added");
                try result.findings.append(f);
            }

            // Check: stale (not updated recently)
            if (self.config.check_stale) {
                const now = std.time.timestamp();
                const age = now - entry.updated_at;
                if (age > @as(i64, @intCast(self.config.stale_threshold_seconds))) {
                    const f = try self.allocator.create(LintFinding);
                    f.* = try LintFinding.init(self.allocator, .warning, .stale, "Knowledge entry has not been updated recently");
                    try f.withLocation(entry.id);
                    try result.findings.append(f);
                }
            }

            // Check: unattributed (no source)
            if (self.config.check_unattributed and !entry.has_source) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .warning, .unattributed, "Knowledge entry has no source attribution");
                try f.withLocation(entry.id);
                try f.withSuggestion("Add source provenance to track where this knowledge came from");
                try result.findings.append(f);
            }

            // Check: broken references
            if (self.config.check_broken_refs) {
                for (entry.references) |ref| {
                    if (!id_set.contains(ref)) {
                        const f = try self.allocator.create(LintFinding);
                        f.* = try LintFinding.init(self.allocator, .critical, .broken_ref, "References non-existent knowledge entry");
                        try f.withLocation(entry.id);
                        try f.withSuggestion(ref);
                        try result.findings.append(f);
                    }
                }
            }

            // Check: low confidence
            if (self.config.check_low_confidence and entry.confidence < self.config.min_confidence) {
                const f = try self.allocator.create(LintFinding);
                f.* = try LintFinding.init(self.allocator, .warning, .low_confidence, "Knowledge confidence is below threshold");
                try f.withLocation(entry.id);
                try result.findings.append(f);
            }
        }

        // Check: duplicates (content similarity)
        if (self.config.check_duplicates) {
            for (entries, 0..) |e1, i| {
                for (entries[i + 1 ..]) |e2| {
                    // Simple exact match check
                    if (std.mem.eql(u8, e1.content, e2.content)) {
                        const f = try self.allocator.create(LintFinding);
                        f.* = try LintFinding.init(self.allocator, .info, .duplicate, "Duplicate knowledge entry found");
                        try f.withLocation(e1.id);
                        try f.withSuggestion(e2.id);
                        try result.findings.append(f);
                    }
                }
            }
        }

        // Calculate pass rate
        if (result.total_checked > 0) {
            const critical = result.countBySeverity(.critical);
            const warnings = result.countBySeverity(.warning);
            const pass_rate = (@as(f64, @floatFromInt(result.total_checked)) - @as(f64, @floatFromInt(critical)) * 2.0 - @as(f64, @floatFromInt(warnings)) * 0.5) / @as(f64, @floatFromInt(result.total_checked)) * 100.0;
            result.pass_rate = @max(0.0, pass_rate);
        }

        return result;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "LintFinding - init and deinit" {
    const f = try LintFinding.init(testing.allocator, .warning, .stale, "Old entry");
    defer {
        var m = f;
        m.deinit();
    }
    try testing.expectEqual(LintSeverity.warning, f.severity);
    try testing.expectEqual(LintFinding.LintRule.stale, f.rule);
}

test "KnowledgeLinter - detects orphans" {
    var linter = KnowledgeLinter.init(testing.allocator, .{
        .check_stale = false,
        .check_unattributed = false,
        .check_duplicates = false,
        .check_broken_refs = false,
        .check_low_confidence = false,
    });

    const entries = [_]KnowledgeEntry{
        .{
            .id = "k1",
            .content = "Test",
            .confidence = 1.0,
            .has_source = true,
            .references = &.{},
            .referenced_by = &.{},
            .updated_at = std.time.timestamp(),
        },
    };

    var result = try linter.lint(&entries);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.countByRule(.orphan));
}

test "KnowledgeLinter - detects broken refs" {
    var linter = KnowledgeLinter.init(testing.allocator, .{
        .check_orphans = false,
        .check_stale = false,
        .check_unattributed = false,
        .check_duplicates = false,
        .check_low_confidence = false,
    });

    const entries = [_]KnowledgeEntry{
        .{
            .id = "k1",
            .content = "Test",
            .confidence = 1.0,
            .has_source = true,
            .references = &.{"missing_ref"},
            .referenced_by = &.{},
            .updated_at = std.time.timestamp(),
        },
    };

    var result = try linter.lint(&entries);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.countByRule(.broken_ref));
    try testing.expectEqual(@as(u32, 1), result.countBySeverity(.critical));
}

test "KnowledgeLinter - detects duplicates" {
    var linter = KnowledgeLinter.init(testing.allocator, .{
        .check_orphans = false,
        .check_stale = false,
        .check_unattributed = false,
        .check_low_confidence = false,
        .check_broken_refs = false,
    });

    const entries = [_]KnowledgeEntry{
        .{
            .id = "k1",
            .content = "Same content",
            .confidence = 1.0,
            .has_source = true,
            .references = &.{},
            .referenced_by = &.{"k2"},
            .updated_at = std.time.timestamp(),
        },
        .{
            .id = "k2",
            .content = "Same content",
            .confidence = 1.0,
            .has_source = true,
            .references = &.{},
            .referenced_by = &.{"k1"},
            .updated_at = std.time.timestamp(),
        },
    };

    var result = try linter.lint(&entries);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.countByRule(.duplicate));
}

test "KnowledgeLinter - clean entries have high pass rate" {
    var linter = KnowledgeLinter.init(testing.allocator, .{
        .check_orphans = false,
        .check_stale = false,
        .check_duplicates = false,
        .check_broken_refs = false,
        .check_low_confidence = false,
    });

    const entries = [_]KnowledgeEntry{
        .{
            .id = "k1",
            .content = "Good entry",
            .confidence = 1.0,
            .has_source = true,
            .references = &.{},
            .referenced_by = &.{},
            .updated_at = std.time.timestamp(),
        },
    };

    var result = try linter.lint(&entries);
    defer result.deinit();

    try testing.expect(result.pass_rate > 99.0);
}
