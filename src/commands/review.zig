const std = @import("std");
const shell_mod = @import("shell");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Scope of what to review
pub const ReviewScope = enum {
    unstaged,
    staged,
    branch,
    last_commit,
    specific_files,
};

/// Severity of a review finding
pub const FindingSeverity = enum {
    info,
    warning,
    @"error",
    suggestion,
};

/// A single review finding
pub const ReviewFinding = struct {
    file: []const u8,
    line: ?u32,
    severity: FindingSeverity,
    category: []const u8,
    message: []const u8,
    suggestion: ?[]const u8 = null,
};

/// Overall assessment of the review
pub const OverallAssessment = enum {
    positive,
    needs_attention,
    concerns,
};

/// Result of a code review
pub const ReviewResult = struct {
    allocator: Allocator,
    summary: []const u8,
    findings: array_list_compat.ArrayList(ReviewFinding),
    overall_assessment: OverallAssessment,

    pub fn init(allocator: Allocator) ReviewResult {
        return ReviewResult{
            .allocator = allocator,
            .summary = "",
            .findings = array_list_compat.ArrayList(ReviewFinding).init(allocator),
            .overall_assessment = .positive,
        };
    }

    pub fn deinit(self: *ReviewResult) void {
        self.findings.deinit();
    }
};

/// Run a shell command and return stdout. Returns null on failure.
fn runCommand(allocator: Allocator, command: []const u8) ?[]const u8 {
    const result = shell_mod.executeShellCommand(command, null) catch return null;
    if (result.exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn runCommandRaw(command: []const u8) ?shell_mod.ShellResult {
    return shell_mod.executeShellCommand(command, null) catch null;
}

/// Count lines added and removed from a diff
fn countDiffStats(diff: []const u8) struct { added: usize, removed: usize, files: usize } {
    var added: usize = 0;
    var removed: usize = 0;
    var files: usize = 0;

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > 4 and std.mem.startsWith(u8, line, "diff ")) {
            files += 1;
        } else if (line[0] == '+') {
            if (!std.mem.startsWith(u8, line, "+++")) {
                added += 1;
            }
        } else if (line[0] == '-') {
            if (!std.mem.startsWith(u8, line, "---")) {
                removed += 1;
            }
        }
    }
    return .{ .added = added, .removed = removed, .files = files };
}

/// Run review based on scope and return formatted review prompt.
/// Caller owns the returned string.
pub fn runReview(allocator: Allocator, scope: ReviewScope, files: ?[]const []const u8) ![]const u8 {
    const diff = switch (scope) {
        .unstaged => runCommandRaw("git diff 2>/dev/null"),
        .staged => runCommandRaw("git diff --cached 2>/dev/null"),
        .branch => runCommandRaw("git diff main...HEAD 2>/dev/null"),
        .last_commit => runCommandRaw("git show HEAD --format='' 2>/dev/null"),
        .specific_files => blk: {
            if (files) |f| {
                // Build command with file paths
                var cmd = array_list_compat.ArrayList(u8).init(allocator);
                defer cmd.deinit();
                try cmd.appendSlice("cat");
                for (f) |file_path| {
                    try cmd.appendSlice(" ");
                    try cmd.appendSlice(file_path);
                }
                try cmd.appendSlice(" 2>/dev/null");
                break :blk runCommandRaw(cmd.items);
            }
            break :blk null;
        },
    };

    const scope_label: []const u8 = switch (scope) {
        .unstaged => "unstaged changes",
        .staged => "staged changes",
        .branch => "branch (comparing to main)",
        .last_commit => "last commit",
        .specific_files => "specific files",
    };

    if (diff) |d| {
        if (d.stdout.len == 0) {
            return std.fmt.allocPrint(allocator, "/review: No changes found.\nScope: {s}", .{scope_label});
        }
        return formatReviewPrompt(allocator, d.stdout, scope_label);
    } else {
        return std.fmt.allocPrint(allocator, "/review: Could not gather diff content.\nScope: {s}\n\nMake sure you are in a git repository.", .{scope_label});
    }
}

/// Format diff output as a review prompt for the AI.
/// Caller owns the returned string.
pub fn formatReviewPrompt(allocator: Allocator, diff: []const u8, scope_label: []const u8) ![]const u8 {
    const stats = countDiffStats(diff);

    // Truncate diff if too long (keep first 15KB)
    const max_diff_len: usize = 15 * 1024;
    const truncated_diff = if (diff.len > max_diff_len) diff[0..max_diff_len] else diff;
    const was_truncated = diff.len > max_diff_len;

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("/review: Analyzing changes...\n");
    try writer.print("Scope: {s}\n", .{scope_label});
    try writer.print("Files changed: {d}\n", .{stats.files});
    try writer.print("Lines changed: +{d}/-{d}\n\n", .{ stats.added, stats.removed });
    try writer.writeAll(truncated_diff);

    if (was_truncated) {
        try writer.print("\n\n... [{d} bytes truncated] ...", .{diff.len - max_diff_len});
    }

    try writer.writeAll("\n\nReview this code for: bugs, security issues, performance, style, and maintainability.");

    return buf.toOwnedSlice();
}
