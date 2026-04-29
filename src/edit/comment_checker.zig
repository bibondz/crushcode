const std = @import("std");
const array_list_compat = @import("array_list_compat");

pub const CommentFinding = struct {
    line: u32,
    pattern_type: []const u8,
    comment_text: []const u8,
};

pub const CommentCheckResult = struct {
    findings: []CommentFinding,
    total_comments: u32,
    ai_comment_count: u32,

    pub fn deinit(self: *const CommentCheckResult, allocator: std.mem.Allocator) void {
        for (self.findings) |f| {
            allocator.free(f.comment_text);
        }
        allocator.free(self.findings);
    }
};

pub const CommentChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommentChecker {
        return CommentChecker{ .allocator = allocator };
    }

    /// Scan content for AI-generated comment patterns
    pub fn check(self: *CommentChecker, content: []const u8) !CommentCheckResult {
        var findings_list = array_list_compat.ArrayList(CommentFinding).init(self.allocator);
        errdefer {
            for (findings_list.items) |f| {
                self.allocator.free(f.comment_text);
            }
            findings_list.deinit();
        }

        var total_comments: u32 = 0;
        var ai_comment_count: u32 = 0;
        var line_num: u32 = 0;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            line_num += 1;

            // Skip doc comments (///, //!) and block comments
            if (std.mem.startsWith(u8, line, "///") or std.mem.startsWith(u8, line, "//!")) {
                continue;
            }

            // Only check single-line comments (// but not ///)
            if (std.mem.indexOf(u8, line, "//")) |comment_start| {
                // Skip if it's a doc comment (///)
                if (comment_start + 2 < line.len and line[comment_start + 2] == '/') {
                    continue;
                }

                total_comments += 1;

                // Extract comment text after // and trim whitespace
                const comment_part = line[comment_start + 2 ..];
                const comment_text = std.mem.trim(u8, comment_part, " \t\r");

                // Skip if empty
                if (comment_text.len == 0) continue;

                // Skip good comments that explain WHY
                if (std.mem.indexOf(u8, comment_text, "WHY:") != null or
                    std.mem.indexOf(u8, comment_text, "REASON:") != null or
                    std.mem.indexOf(u8, comment_text, "NOTE:") != null)
                {
                    continue;
                }

                // Skip TODO/FIXME/HACK comments
                if (std.mem.startsWith(u8, comment_text, "TODO") or
                    std.mem.startsWith(u8, comment_text, "FIXME") or
                    std.mem.startsWith(u8, comment_text, "HACK") or
                    std.mem.startsWith(u8, comment_text, "XXX"))
                {
                    continue;
                }

                // Check for AI patterns
                if (try self.checkPattern(comment_text)) |pattern_type| {
                    const comment_copy = try self.allocator.dupe(u8, comment_text);
                    try findings_list.append(.{
                        .line = line_num,
                        .pattern_type = pattern_type,
                        .comment_text = comment_copy,
                    });
                    ai_comment_count += 1;

                    // Limit to max 5 findings
                    if (findings_list.items.len >= 5) break;
                }
            }
        }

        return CommentCheckResult{
            .findings = try findings_list.toOwnedSlice(),
            .total_comments = total_comments,
            .ai_comment_count = ai_comment_count,
        };
    }

    /// Check if a comment matches any AI pattern, returning the pattern type or null
    fn checkPattern(self: *CommentChecker, comment: []const u8) !?[]const u8 {
        const lower = try self.allocator.dupe(u8, comment);
        defer self.allocator.free(lower);
        for (lower, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }

        // Pattern 1: Obvious statements (short comments that restate the code)
        // Only flag if total comment is short (<= 40 chars)
        if (comment.len <= 40) {
            const obvious_prefixes = [_][]const u8{
                "return ",   "set ",    "check if ", "get ",  "update ",
                "create ",   "delete ", "add ",     "remove ", "initialize ",
                "validate ", "parse ",  "format ",  "handle ", "process ",
                "calculate ", "build ", "generate ", "extract ", "convert ",
                "assign ",   "store ",  "save ",    "load ",   "clear ",
                "reset ",    "increment ", "decrement ", "append ", "prepend ",
            };
            for (obvious_prefixes) |prefix| {
                if (std.mem.startsWith(u8, lower, prefix)) {
                    return "obvious";
                }
            }
        }

        // Pattern 2: Verbose wrappers
        const verbose_patterns = [_][]const u8{
            "this function", "this method", "this module", "this struct",
            "we need to",   "let's",      "i will",      "i'm going to",
        };
        for (verbose_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower, pattern) != null) {
                return "verbose";
            }
        }

        // Pattern 3: AI filler
        const filler_patterns = [_][]const u8{
            "ensure that",       "it's important to", "it is important",
            "in order to",       "allows us to",      "helps to",
            "is used to",        "can be used to",    "provides the ability",
            "gives us the ability", "makes it easy",
        };
        for (filler_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower, pattern) != null) {
                return "filler";
            }
        }

        // Pattern 4: Template language
        const template_patterns = [_][]const u8{
            "in this section", "first, we will", "next, we",
            "finally, we",     "step 1:",        "step 2:",
            "step 3:",
        };
        for (template_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower, pattern) != null) {
                return "template";
            }
        }

        return null;
    }

    /// Format a summary message for tool output
    pub fn formatWarning(self: *const CommentChecker, result: *const CommentCheckResult) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const writer = buf.writer();

        try writer.print("⚠️ AI-generated comments detected ({d}/{d} comments). Consider simplifying:\n", .{
            result.ai_comment_count,
            result.total_comments,
        });

        for (result.findings) |f| {
            try writer.print("  Line {d}: {s} — \"{s}\"\n", .{ f.line, f.pattern_type, f.comment_text });
        }

        return buf.toOwnedSlice();
    }
};

test "detect obvious comments" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\fn example() i32 {
        \\    // Return the result
        \\    return 42;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.total_comments);
    try std.testing.expectEqual(@as(u32, 1), result.ai_comment_count);
    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("obvious", result.findings[0].pattern_type);
}

test "detect verbose comments" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\// This function handles the processing of data
        \\fn processData(data: []u8) void {
        \\    // We need to validate the input
        \\    _ = data;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), result.total_comments);
    try std.testing.expectEqual(@as(u32, 2), result.ai_comment_count);
    try std.testing.expectEqualStrings("verbose", result.findings[0].pattern_type);
}

test "detect filler comments" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\// It's important to validate the input
        \\fn validate(input: []u8) bool {
        \\    // Ensure that the data is not empty
        \\    return input.len > 0;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), result.total_comments);
    try std.testing.expectEqual(@as(u32, 2), result.ai_comment_count);
    try std.testing.expectEqualStrings("filler", result.findings[0].pattern_type);
}

test "good comments are not flagged" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\// WHY: Using FNV-1a for O(1) lookup performance
        \\fn hash(key: []const u8) u32 {
        \\    // NOTE: This handles null keys gracefully
        \\    if (key.len == 0) return 0;
        \\    return 42;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.ai_comment_count);
}

test "doc comments are skipped" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\/// This is a doc comment
        \\fn example() i32 {
        \\    return 42;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.total_comments);
    try std.testing.expectEqual(@as(u32, 0), result.ai_comment_count);
}

test "TODO/FIXME/HACK comments are skipped" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\// TODO: Implement this function
        \\fn example() i32 {
        \\    // FIXME: This is a hack
        \\    return 42;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), result.total_comments);
    try std.testing.expectEqual(@as(u32, 0), result.ai_comment_count);
}

test "formatWarning output" {
    const allocator = std.testing.allocator;
    var checker = CommentChecker.init(allocator);

    const test_code =
        \\// Return the result
        \\fn example() i32 {
        \\    return 42;
        \\}
    ;

    const result = try checker.check(test_code);
    defer result.deinit(allocator);

    const warning = try checker.formatWarning(&result);
    defer allocator.free(warning);

    try std.testing.expect(warning.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, warning, "AI-generated comments detected") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "obvious") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "Return the result") != null);
}
