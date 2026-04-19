const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Severity level for review findings
pub const FindingSeverity = enum {
    critical, // Must fix before proceeding
    high, // Should fix
    medium, // Recommended improvement
    low, // Minor suggestion
    info, // Informational note
};

/// Category of a review finding
pub const FindingCategory = enum {
    correctness, // Logic or factual errors
    security, // Security vulnerabilities
    performance, // Performance issues
    style, // Code style or formatting
    architecture, // Design or architecture concerns
    testing, // Test coverage gaps
    documentation, // Documentation issues
};

/// A single finding from the review
pub const ReviewFinding = struct {
    allocator: Allocator,
    severity: FindingSeverity,
    category: FindingCategory,
    title: []const u8,
    description: []const u8,
    location: ?[]const u8, // File path or line reference
    suggestion: ?[]const u8, // Suggested fix

    pub fn init(
        allocator: Allocator,
        severity: FindingSeverity,
        category: FindingCategory,
        title: []const u8,
        description: []const u8,
    ) !ReviewFinding {
        return ReviewFinding{
            .allocator = allocator,
            .severity = severity,
            .category = category,
            .title = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, description),
            .location = null,
            .suggestion = null,
        };
    }

    pub fn withLocation(self: *ReviewFinding, location: []const u8) !*ReviewFinding {
        self.location = try self.allocator.dupe(u8, location);
        return self;
    }

    pub fn withSuggestion(self: *ReviewFinding, suggestion: []const u8) !*ReviewFinding {
        self.suggestion = try self.allocator.dupe(u8, suggestion);
        return self;
    }

    pub fn deinit(self: *ReviewFinding) void {
        self.allocator.free(self.title);
        self.allocator.free(self.description);
        if (self.location) |l| self.allocator.free(l);
        if (self.suggestion) |s| self.allocator.free(s);
    }
};

/// Overall review verdict
pub const ReviewVerdict = enum {
    approve, // No critical/high findings
    approve_with_comments, // Only medium/low findings
    request_changes, // Has critical or high severity findings
    reject, // Fundamental problems
};

/// Result of an adversarial review pass
pub const ReviewResult = struct {
    allocator: Allocator,
    reviewer_model: []const u8,
    findings: array_list_compat.ArrayList(*ReviewFinding),
    verdict: ReviewVerdict,
    summary: []const u8,
    reviewed_at: i64,

    pub fn init(allocator: Allocator, reviewer_model: []const u8) !ReviewResult {
        return ReviewResult{
            .allocator = allocator,
            .reviewer_model = try allocator.dupe(u8, reviewer_model),
            .findings = array_list_compat.ArrayList(*ReviewFinding).init(allocator),
            .verdict = .approve,
            .summary = "",
            .reviewed_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *ReviewResult) void {
        self.allocator.free(self.reviewer_model);
        if (self.summary.len > 0) self.allocator.free(self.summary);
        for (self.findings.items) |f| {
            f.deinit();
            self.allocator.destroy(f);
        }
        self.findings.deinit();
    }

    pub fn addFinding(self: *ReviewResult, finding: *ReviewFinding) !void {
        try self.findings.append(finding);
        self.recalculateVerdict();
    }

    fn recalculateVerdict(self: *ReviewResult) void {
        var has_critical = false;
        var has_high = false;
        for (self.findings.items) |f| {
            switch (f.severity) {
                .critical => has_critical = true,
                .high => has_high = true,
                else => {},
            }
        }
        if (has_critical) {
            self.verdict = .reject;
        } else if (has_high) {
            self.verdict = .request_changes;
        } else if (self.findings.items.len > 0) {
            self.verdict = .approve_with_comments;
        } else {
            self.verdict = .approve;
        }
    }

    /// Count findings by severity
    pub fn countBySeverity(self: *const ReviewResult, severity: FindingSeverity) u32 {
        var count: u32 = 0;
        for (self.findings.items) |f| {
            if (f.severity == severity) count += 1;
        }
        return count;
    }

    /// Count findings by category
    pub fn countByCategory(self: *const ReviewResult, category: FindingCategory) u32 {
        var count: u32 = 0;
        for (self.findings.items) |f| {
            if (f.category == category) count += 1;
        }
        return count;
    }

    pub fn setSummary(self: *ReviewResult, summary: []const u8) !void {
        if (self.summary.len > 0) self.allocator.free(self.summary);
        self.summary = try self.allocator.dupe(u8, summary);
    }
};

/// Dual-model review configuration
pub const AdversarialReviewConfig = struct {
    /// Model used for generation
    generator_model: []const u8 = "default",
    /// Model used for review (different from generator for adversarial perspective)
    reviewer_model: []const u8 = "default",
    /// Minimum severity to include in findings
    min_severity: FindingSeverity = .low,
    /// Focus categories (empty = all)
    focus_categories: []const FindingCategory = &.{},
};

/// Adversarial Dual-Model Review system.
/// Uses a second model to critically review output from the first model.
///
/// Flow:
///   1. Generator model produces output
///   2. Reviewer model examines the output
///   3. Findings are collected and categorized
///   4. Verdict determines if output needs revision
///
/// Reference: Cavekit adversarial review pattern (F10)
pub const AdversarialReviewer = struct {
    allocator: Allocator,
    config: AdversarialReviewConfig,
    reviews: array_list_compat.ArrayList(*ReviewResult),

    pub fn init(allocator: Allocator, config: AdversarialReviewConfig) AdversarialReviewer {
        return AdversarialReviewer{
            .allocator = allocator,
            .config = config,
            .reviews = array_list_compat.ArrayList(*ReviewResult).init(allocator),
        };
    }

    pub fn deinit(self: *AdversarialReviewer) void {
        for (self.reviews.items) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        self.reviews.deinit();
    }

    /// Create a new review result for tracking findings
    pub fn startReview(self: *AdversarialReviewer) !*ReviewResult {
        const result = try self.allocator.create(ReviewResult);
        result.* = try ReviewResult.init(self.allocator, self.config.reviewer_model);
        try self.reviews.append(result);
        return result;
    }

    /// Add a finding to the current review
    pub fn addFinding(
        self: *AdversarialReviewer,
        review: *ReviewResult,
        severity: FindingSeverity,
        category: FindingCategory,
        title: []const u8,
        description: []const u8,
    ) !*ReviewFinding {
        const finding = try self.allocator.create(ReviewFinding);
        finding.* = try ReviewFinding.init(self.allocator, severity, category, title, description);
        try review.addFinding(finding);
        return finding;
    }

    /// Get all reviews
    pub fn getReviews(self: *const AdversarialReviewer) []const *ReviewResult {
        return self.reviews.items;
    }

    /// Get the latest review
    pub fn latestReview(self: *const AdversarialReviewer) ?*ReviewResult {
        if (self.reviews.items.len == 0) return null;
        return self.reviews.items[self.reviews.items.len - 1];
    }

    /// Check if any review has blocking findings
    pub fn hasBlockingFindings(self: *const AdversarialReviewer) bool {
        for (self.reviews.items) |review| {
            if (review.verdict == .reject or review.verdict == .request_changes) {
                return true;
            }
        }
        return false;
    }

    /// Aggregate findings across all reviews
    pub fn aggregateFindings(self: *const AdversarialReviewer) ReviewAggregation {
        var total: u32 = 0;
        var critical: u32 = 0;
        var high: u32 = 0;
        var medium: u32 = 0;
        var low: u32 = 0;

        for (self.reviews.items) |review| {
            for (review.findings.items) |f| {
                total += 1;
                switch (f.severity) {
                    .critical => critical += 1,
                    .high => high += 1,
                    .medium => medium += 1,
                    .low => low += 1,
                    .info => {},
                }
            }
        }

        return ReviewAggregation{
            .total_findings = total,
            .critical = critical,
            .high = high,
            .medium = medium,
            .low = low,
            .total_reviews = @intCast(self.reviews.items.len),
        };
    }
};

pub const ReviewAggregation = struct {
    total_findings: u32,
    critical: u32,
    high: u32,
    medium: u32,
    low: u32,
    total_reviews: u32,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "ReviewFinding - init and deinit" {
    const f = try ReviewFinding.init(testing.allocator, .high, .security, "SQL Injection", "User input not sanitized");
    defer {
        var mutable = f;
        mutable.deinit();
    }
    try testing.expectEqual(FindingSeverity.high, f.severity);
    try testing.expectEqual(FindingCategory.security, f.category);
    try testing.expectEqualStrings("SQL Injection", f.title);
}

test "ReviewResult - verdict calculation" {
    var result = ReviewResult.init(testing.allocator, "reviewer-model");
    defer result.deinit();

    try testing.expectEqual(ReviewVerdict.approve, result.verdict);

    const f1 = try testing.allocator.create(ReviewFinding);
    f1.* = try ReviewFinding.init(testing.allocator, .medium, .style, "Naming", "Use camelCase");
    try result.addFinding(f1);
    try testing.expectEqual(ReviewVerdict.approve_with_comments, result.verdict);

    const f2 = try testing.allocator.create(ReviewFinding);
    f2.* = try ReviewFinding.init(testing.allocator, .critical, .security, "Vuln", "Remote code execution");
    try result.addFinding(f2);
    try testing.expectEqual(ReviewVerdict.reject, result.verdict);
}

test "AdversarialReviewer - full review flow" {
    var reviewer = AdversarialReviewer.init(testing.allocator, .{
        .generator_model = "llama3",
        .reviewer_model = "claude-3-opus",
    });
    defer reviewer.deinit();

    const review = try reviewer.startReview();
    _ = try reviewer.addFinding(review, .low, .style, "Trailing whitespace", "Line 42 has trailing whitespace");
    _ = try reviewer.addFinding(review, .medium, .performance, "N+1 query", "Loop makes individual DB queries");
    _ = try reviewer.addFinding(review, .high, .correctness, "Race condition", "Shared state not locked");

    try testing.expectEqual(@as(usize, 3), review.findings.items.len);
    try testing.expectEqual(ReviewVerdict.request_changes, review.verdict);
    try testing.expect(reviewer.hasBlockingFindings());
}

test "AdversarialReviewer - aggregation" {
    var reviewer = AdversarialReviewer.init(testing.allocator, .{});
    defer reviewer.deinit();

    const r1 = try reviewer.startReview();
    _ = try reviewer.addFinding(r1, .high, .security, "Issue 1", "Desc 1");

    const r2 = try reviewer.startReview();
    _ = try reviewer.addFinding(r2, .low, .style, "Issue 2", "Desc 2");
    _ = try reviewer.addFinding(r2, .critical, .correctness, "Issue 3", "Desc 3");

    const agg = reviewer.aggregateFindings();
    try testing.expectEqual(@as(u32, 3), agg.total_findings);
    try testing.expectEqual(@as(u32, 1), agg.critical);
    try testing.expectEqual(@as(u32, 1), agg.high);
    try testing.expectEqual(@as(u32, 1), agg.low);
    try testing.expectEqual(@as(u32, 2), agg.total_reviews);
}

test "ReviewResult - countBySeverity" {
    var result = ReviewResult.init(testing.allocator, "reviewer");
    defer result.deinit();

    const f1 = try testing.allocator.create(ReviewFinding);
    f1.* = try ReviewFinding.init(testing.allocator, .low, .style, "A", "a");
    try result.addFinding(f1);

    const f2 = try testing.allocator.create(ReviewFinding);
    f2.* = try ReviewFinding.init(testing.allocator, .low, .style, "B", "b");
    try result.addFinding(f2);

    try testing.expectEqual(@as(u32, 2), result.countBySeverity(.low));
    try testing.expectEqual(@as(u32, 0), result.countBySeverity(.critical));
}
