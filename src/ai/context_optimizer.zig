const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Optimization profile that controls compression aggressiveness.
pub const OptimizationProfile = enum {
    /// Balanced — keep code, reduce chatter
    coding,
    /// Verbose — keep explanations, reduce code
    analysis,
    /// Maximum compression — essential info only
    compact,
};

/// Action to take when a rule matches.
pub const RuleAction = enum {
    /// Remove the matched text entirely
    remove,
    /// Truncate the matched text (keep first N chars)
    truncate,
    /// Replace the matched text with a replacement string
    replace,
};

/// A single optimization rule.
pub const OptimizationRule = struct {
    name: []const u8,
    pattern: []const u8,
    action: RuleAction,
    replacement: ?[]const u8,
};

/// Estimated savings from optimization.
pub const SavingsEstimate = struct {
    original_tokens: u64,
    optimized_tokens: u64,
    savings_percent: f64,
};

/// Rule-based context optimizer that removes sycophantic phrases,
/// disclaimers, and other non-essential text from AI responses.
pub const ContextOptimizer = struct {
    allocator: Allocator,
    profile: OptimizationProfile,
    rules: array_list_compat.ArrayList(OptimizationRule),

    /// Initialize a ContextOptimizer with default rules for the given profile.
    pub fn init(allocator: Allocator, profile: OptimizationProfile) ContextOptimizer {
        var self = ContextOptimizer{
            .allocator = allocator,
            .profile = profile,
            .rules = array_list_compat.ArrayList(OptimizationRule).init(allocator),
        };

        // Load common rules for all profiles
        self.addDefaultCommonRules();

        // Load profile-specific rules
        switch (profile) {
            .coding => self.addCodingRules(),
            .analysis => self.addAnalysisRules(),
            .compact => self.addCompactRules(),
        }

        return self;
    }

    /// Free all owned rule strings and the rule list.
    pub fn deinit(self: *ContextOptimizer) void {
        self.rules.deinit();
    }

    /// Add a custom optimization rule.
    pub fn addRule(self: *ContextOptimizer, name: []const u8, pattern: []const u8, action: RuleAction, replacement: ?[]const u8) !void {
        const rule = OptimizationRule{
            .name = name,
            .pattern = pattern,
            .action = action,
            .replacement = replacement,
        };
        try self.rules.append(rule);
    }

    /// Apply all rules to the input text and return the optimized result.
    pub fn optimize(self: *ContextOptimizer, input: []const u8) ![]u8 {
        var result = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(result);

        for (self.rules.items) |rule| {
            const new_result = self.applyRule(result, rule) catch continue;
            self.allocator.free(result);
            result = new_result;
        }

        return result;
    }

    /// Estimate token savings without modifying the input.
    pub fn estimateSavings(self: *ContextOptimizer, input: []const u8) SavingsEstimate {
        const original_tokens = estimateTokens(input);
        var estimated_length: u64 = @intCast(input.len);

        for (self.rules.items) |rule| {
            // Estimate bytes removed by this rule
            estimated_length = estimateLengthAfterRule(input, rule, estimated_length);
        }

        const optimized_tokens = estimateTokensFromLen(estimated_length);
        const savings_percent = if (original_tokens > 0)
            @as(f64, @floatFromInt(original_tokens -| optimized_tokens)) / @as(f64, @floatFromInt(original_tokens)) * 100.0
        else
            0.0;

        return SavingsEstimate{
            .original_tokens = original_tokens,
            .optimized_tokens = optimized_tokens,
            .savings_percent = savings_percent,
        };
    }

    // ── Internal helpers ──────────────────────────────────────────────────

    /// Apply a single rule to the text, returning a new allocation.
    fn applyRule(self: *ContextOptimizer, text: []const u8, rule: OptimizationRule) ![]u8 {
        switch (rule.action) {
            .remove => return self.applyRemove(text, rule.pattern),
            .replace => return self.applyReplace(text, rule.pattern, rule.replacement),
            .truncate => return self.applyTruncate(text, rule.pattern),
        }
    }

    fn applyRemove(self: *ContextOptimizer, text: []const u8, pattern: []const u8) ![]u8 {
        // Remove all occurrences of pattern from text
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var pos: usize = 0;
        while (pos < text.len) {
            if (std.mem.indexOf(u8, text[pos..], pattern)) |idx| {
                // Copy text before match
                try result.appendSlice(text[pos .. pos + idx]);
                pos = pos + idx + pattern.len;
            } else {
                try result.appendSlice(text[pos..]);
                break;
            }
        }

        return result.toOwnedSlice();
    }

    fn applyReplace(self: *ContextOptimizer, text: []const u8, pattern: []const u8, replacement: ?[]const u8) ![]u8 {
        const repl = replacement orelse "";
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var pos: usize = 0;
        while (pos < text.len) {
            if (std.mem.indexOf(u8, text[pos..], pattern)) |idx| {
                try result.appendSlice(text[pos .. pos + idx]);
                try result.appendSlice(repl);
                pos = pos + idx + pattern.len;
            } else {
                try result.appendSlice(text[pos..]);
                break;
            }
        }

        return result.toOwnedSlice();
    }

    fn applyTruncate(self: *ContextOptimizer, text: []const u8, pattern: []const u8) ![]u8 {
        // For truncate: if pattern is found, keep only text before the first occurrence
        if (std.mem.indexOf(u8, text, pattern)) |idx| {
            if (idx == 0) return try self.allocator.dupe(u8, "");
            return try self.allocator.dupe(u8, text[0..idx]);
        }
        return try self.allocator.dupe(u8, text);
    }

    /// Add rules common to all profiles — sycophantic phrases, disclaimers, etc.
    fn addDefaultCommonRules(self: *ContextOptimizer) void {
        // Remove sycophantic phrases
        self.addRule("sycophantic_great_question", "Great question!", .remove, null) catch {};
        self.addRule("sycophantic_hope_helps", "I hope this helps!", .remove, null) catch {};
        self.addRule("sycophantic_let_me_help", "Let me help you with that", .remove, null) catch {};
        self.addRule("sycophantic_certainly", "Certainly!", .remove, null) catch {};
        self.addRule("sycophantic_of_course", "Of course!", .remove, null) catch {};
        self.addRule("sycophantic_sure_excl", "Sure!", .remove, null) catch {};
        self.addRule("sycophantic_absolutely", "Absolutely!", .remove, null) catch {};

        // Remove AI disclaimers
        self.addRule("disclaimer_as_ai", "As an AI", .remove, null) catch {};
        self.addRule("disclaimer_as_language_model", "As a language model", .remove, null) catch {};

        // Remove "Here's a summary:" prefix
        self.addRule("summary_prefix", "Here's a summary:", .remove, null) catch {};

        // Remove trailing offers for more help
        self.addRule("trailing_anything_else", "Let me know if you need anything else!", .remove, null) catch {};
    }

    /// Add coding-profile rules: remove verbose explanations between code blocks.
    fn addCodingRules(self: *ContextOptimizer) void {
        // In coding mode, remove verbose filler between code sections
        self.addRule("coding_explanation_between_code", "Let me explain what this code does:", .remove, null) catch {};
        self.addRule("coding_step_by_step", "Let's break this down step by step:", .remove, null) catch {};
    }

    /// Add analysis-profile rules: keep explanations, remove redundant code.
    fn addAnalysisRules(self: *ContextOptimizer) void {
        // In analysis mode, remove repetitive code example markers
        self.addRule("analysis_code_example", "For example, consider this code:", .remove, null) catch {};
        self.addRule("analysis_another_example", "Here's another example:", .remove, null) catch {};
    }

    /// Add compact-profile rules: maximum compression.
    fn addCompactRules(self: *ContextOptimizer) void {
        // Compact mode — remove all non-essential prefixes and fillers
        self.addRule("compact_note_that", "Note that ", .remove, null) catch {};
        self.addRule("compact_important_to", "It's important to note that ", .remove, null) catch {};
        self.addRule("compact_keep_in_mind", "Keep in mind that ", .remove, null) catch {};
        self.addRule("compact_please_note", "Please note that ", .remove, null) catch {};
    }
};

/// Estimate tokens using chars/4 heuristic.
fn estimateTokens(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return @intCast((text.len + 3) / 4);
}

/// Estimate tokens from a byte length using the same heuristic.
fn estimateTokensFromLen(len: u64) u64 {
    if (len == 0) return 0;
    return (len + 3) / 4;
}

/// Estimate the remaining length after applying a rule (for savings estimation).
fn estimateLengthAfterRule(input: []const u8, rule: OptimizationRule, current_estimate: u64) u64 {
    // Count occurrences of pattern in input
    var count: u64 = 0;
    var pos: usize = 0;
    while (pos < input.len) {
        if (std.mem.indexOf(u8, input[pos..], rule.pattern)) |idx| {
            count += 1;
            pos = pos + idx + rule.pattern.len;
        } else {
            break;
        }
    }

    if (count == 0) return current_estimate;

    const bytes_removed = count * @as(u64, @intCast(rule.pattern.len));

    var bytes_added: u64 = 0;
    switch (rule.action) {
        .remove => {},
        .replace => {
            if (rule.replacement) |repl| {
                bytes_added = count * @as(u64, @intCast(repl.len));
            }
        },
        .truncate => {
            // Truncate: hard to estimate precisely; assume it removes roughly half
            // of the remaining text after the first occurrence
            if (std.mem.indexOf(u8, input, rule.pattern)) |idx| {
                const after = input.len - idx - rule.pattern.len;
                return current_estimate -| @as(u64, @intCast(after / 2));
            }
            return current_estimate;
        },
    }

    return current_estimate -| bytes_removed + bytes_added;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ContextOptimizer - optimize removes sycophantic phrases" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    const input = "Great question! Here is the answer to your problem.";
    const result = try optimizer.optimize(input);
    defer allocator.free(result);

    // "Great question!" should be removed
    try testing.expect(std.mem.indexOf(u8, result, "Great question!") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Here is the answer") != null);
}

test "ContextOptimizer - optimize removes AI disclaimers" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    const input = "As an AI language model, I can help with that. Here is the code.";
    const result = try optimizer.optimize(input);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "As an AI") == null);
}

test "ContextOptimizer - estimateSavings returns reasonable estimates" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    // Input with lots of sycophantic text
    const input = "Great question! Certainly! Let me help you with that. Here is the actual content that matters.";
    const estimate = optimizer.estimateSavings(input);

    try testing.expect(estimate.original_tokens > 0);
    try testing.expect(estimate.optimized_tokens <= estimate.original_tokens);
    try testing.expect(estimate.savings_percent >= 0.0);
}

test "ContextOptimizer - estimateSavings for empty input" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    const estimate = optimizer.estimateSavings("");
    try testing.expectEqual(@as(u64, 0), estimate.original_tokens);
    try testing.expectEqual(@as(u64, 0), estimate.optimized_tokens);
}

test "ContextOptimizer - different profiles produce different results" {
    const allocator = std.testing.allocator;

    var coding_opt = ContextOptimizer.init(allocator, .coding);
    defer coding_opt.deinit();

    var compact_opt = ContextOptimizer.init(allocator, .compact);
    defer compact_opt.deinit();

    const input = "Note that this is important. Here is the code.";

    const coding_result = try coding_opt.optimize(input);
    defer allocator.free(coding_result);

    const compact_result = try compact_opt.optimize(input);
    defer allocator.free(compact_result);

    // Both should have removed different things
    // Compact has more aggressive rules
    try testing.expect(compact_result.len <= coding_result.len);
}

test "ContextOptimizer - custom rules work" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    try optimizer.addRule("custom_test", "REMOVE_ME", .remove, null);

    const input = "Hello REMOVE_ME world";
    const result = try optimizer.optimize(input);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "REMOVE_ME") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "world") != null);
}

test "ContextOptimizer - replace rule works" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    try optimizer.addRule("custom_replace", "PLACEHOLDER", .replace, "actual_value");

    const input = "The value is PLACEHOLDER.";
    const result = try optimizer.optimize(input);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "PLACEHOLDER") == null);
    try testing.expect(std.mem.indexOf(u8, result, "actual_value") != null);
}

test "ContextOptimizer - removes multiple sycophantic phrases" {
    const allocator = std.testing.allocator;
    var optimizer = ContextOptimizer.init(allocator, .coding);
    defer optimizer.deinit();

    const input = "Great question! I hope this helps! Let me know if you need anything else!";
    const result = try optimizer.optimize(input);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Great question!") == null);
    try testing.expect(std.mem.indexOf(u8, result, "I hope this helps!") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Let me know") == null);
}

test "estimateTokens - basic estimation" {
    // "Hello, world!" = 13 chars => 13/4 = 3.25 => ceil = 4
    const tokens = estimateTokens("Hello, world!");
    try testing.expectEqual(@as(u64, 4), tokens);
}

test "estimateTokens - empty string" {
    try testing.expectEqual(@as(u64, 0), estimateTokens(""));
}
