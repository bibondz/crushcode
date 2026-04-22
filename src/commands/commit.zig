const std = @import("std");
const shell_mod = @import("shell");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Learned commit style from recent history
pub const CommitStyle = struct {
    prefix: []const u8 = "",
    use_scope: bool = false,
    max_length: u32 = 72,
    include_co_authored: bool = true,
    has_prefix: bool = false,
};

/// Result of a commit analysis
pub const CommitResult = struct {
    allocator: Allocator,
    message: []const u8,
    files_staged: array_list_compat.ArrayList([]const u8),
    committed: bool,
    hash: ?[]const u8 = null,

    pub fn init(allocator: Allocator) CommitResult {
        return CommitResult{
            .allocator = allocator,
            .message = "",
            .files_staged = array_list_compat.ArrayList([]const u8).init(allocator),
            .committed = false,
        };
    }

    pub fn deinit(self: *CommitResult) void {
        self.files_staged.deinit();
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

/// Parse recent git log to determine commit style preferences.
pub fn analyzeCommitStyle(allocator: Allocator, log: []const u8) !CommitStyle {
    var style = CommitStyle{};
    var prefix_count: usize = 0;
    var scope_count: usize = 0;
    var total_length: usize = 0;
    var line_count: usize = 0;

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        line_count += 1;
        if (line_count > 10) break;

        total_length += trimmed.len;

        // Check for conventional commit prefix (feat:, fix:, chore:, docs:, etc.)
        const known_prefixes = [_][]const u8{
            "feat", "fix", "chore", "docs", "test", "refactor", "perf", "style", "build", "ci", "revert",
        };

        for (&known_prefixes) |prefix| {
            if (std.mem.startsWith(u8, trimmed, prefix)) {
                prefix_count += 1;

                // Check for scope: feat(scope):
                if (trimmed.len > prefix.len and trimmed[prefix.len] == '(') {
                    if (std.mem.indexOfScalar(u8, trimmed[prefix.len..], ')')) |close_paren| {
                        _ = close_paren;
                        scope_count += 1;
                    }
                }
                break;
            }
        }
    }

    if (line_count > 0) {
        style.max_length = @intCast(@min(total_length / line_count + 20, 100));
    }

    if (prefix_count > line_count / 2) {
        style.has_prefix = true;
    }

    if (scope_count > 0) {
        style.use_scope = true;
    }

    _ = allocator;
    return style;
}

/// Detect commit type from diff content
fn detectCommitType(diff: []const u8) []const u8 {
    // Check for new files (lines starting with "+++ b/" without matching "--- a/")
    var has_new_files = false;
    var has_test_files = false;
    var has_doc_files = false;
    var has_config_files = false;

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "new file mode") or
            std.mem.startsWith(u8, line, "+++ b/"))
        {
            has_new_files = true;
        }
        // Check for test patterns in file paths
        if (std.mem.indexOf(u8, line, "test") != null or
            std.mem.indexOf(u8, line, "_test.") != null or
            std.mem.indexOf(u8, line, "spec") != null)
        {
            has_test_files = true;
        }
        if (std.mem.indexOf(u8, line, "README") != null or
            std.mem.indexOf(u8, line, ".md") != null or
            std.mem.indexOf(u8, line, "CHANGELOG") != null or
            std.mem.indexOf(u8, line, "docs/") != null)
        {
            has_doc_files = true;
        }
        if (std.mem.indexOf(u8, line, "build.zig") != null or
            std.mem.indexOf(u8, line, ".toml") != null or
            std.mem.indexOf(u8, line, ".yml") != null or
            std.mem.indexOf(u8, line, ".yaml") != null or
            std.mem.indexOf(u8, line, "Makefile") != null or
            std.mem.indexOf(u8, line, "Dockerfile") != null)
        {
            has_config_files = true;
        }
    }

    if (has_test_files) return "test";
    if (has_doc_files and !has_new_files) return "docs";
    if (has_config_files and !has_new_files) return "chore";
    if (has_new_files) return "feat";
    return "fix";
}

/// Detect scope from file paths in diff
fn detectScope(diff: []const u8, allocator: Allocator) ?[]const u8 {
    // Collect common directory prefixes from modified files
    var dirs = array_list_compat.ArrayList([]const u8).init(allocator);
    defer dirs.deinit();

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            const path = line[6..];
            // Get first directory component
            if (std.mem.indexOfScalar(u8, path, '/')) |slash_idx| {
                const dir = path[0..slash_idx];
                // Skip common non-scope dirs
                if (!std.mem.eql(u8, dir, "src") and !std.mem.eql(u8, dir, "lib") and !std.mem.eql(u8, dir, "pkg")) {
                    // Only add unique
                    var found = false;
                    for (dirs.items) |d| {
                        if (std.mem.eql(u8, d, dir)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        dirs.append(dir) catch continue;
                    }
                }
            }
        }
    }

    // If all changes are in the same subdirectory, use it as scope
    if (dirs.items.len == 1) {
        return dirs.items[0];
    }
    return null;
}

/// Generate a commit message from diff content and style preferences.
/// Caller owns the returned string.
pub fn generateCommitMessage(allocator: Allocator, diff: []const u8, style: CommitStyle) ![]const u8 {
    const commit_type = detectCommitType(diff);
    const scope = if (style.use_scope) detectScope(diff, allocator) else null;

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // First line: type(scope): description
    if (style.has_prefix) {
        if (scope) |s| {
            try writer.print("{s}({s}): ", .{ commit_type, s });
        } else {
            try writer.print("{s}: ", .{commit_type});
        }
    }

    // Generate first line based on diff patterns
    try writer.writeAll(try generateFirstLine(allocator, diff, commit_type));

    // Add body with bullet points from diff analysis
    try writer.writeAll("\n\n");
    try writer.writeAll(try generateBody(allocator, diff));

    return buf.toOwnedSlice();
}

fn generateFirstLine(allocator: Allocator, diff: []const u8, commit_type: []const u8) ![]const u8 {
    _ = allocator;

    // Try to extract meaningful first line from diff
    var has_new = false;
    var has_mod = false;
    var file_count: usize = 0;
    var last_file: []const u8 = "";

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            file_count += 1;
            last_file = line[6..];
            if (std.mem.indexOf(u8, line, "new file") != null) {
                has_new = true;
            } else {
                has_mod = true;
            }
        }
    }

    // Simple heuristic for generating first line
    if (has_new and !has_mod) {
        if (std.mem.eql(u8, commit_type, "test")) {
            return "add tests for recent changes";
        }
        return "add new functionality";
    }
    if (has_mod and !has_new) {
        return "update and improve existing code";
    }
    return "update codebase with changes";
}

fn generateBody(allocator: Allocator, diff: []const u8) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Extract key changes from diff hunks
    var changes = array_list_compat.ArrayList([]const u8).init(allocator);
    defer changes.deinit();

    var lines = std.mem.splitScalar(u8, diff, '\n');
    var in_hunk = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            continue;
        }
        if (in_hunk and line.len > 1) {
            if (line[0] == '+') {
                const content = std.mem.trim(u8, line[1..], " \t");
                if (content.len > 5 and content.len < 80) {
                    changes.append(content) catch continue;
                }
            }
        }
    }

    // Generate up to 5 bullet points
    var count: usize = 0;
    for (changes.items) |change| {
        if (count >= 5) break;
        // Skip lines that look like code syntax only
        if (std.mem.startsWith(u8, change, "//") or
            std.mem.startsWith(u8, change, "/*") or
            std.mem.startsWith(u8, change, "pub fn") or
            std.mem.startsWith(u8, change, "fn ") or
            std.mem.startsWith(u8, change, "const ") or
            std.mem.startsWith(u8, change, "var ") or
            std.mem.startsWith(u8, change, "import") or
            std.mem.startsWith(u8, change, "}"))
        {
            continue;
        }
        try writer.print("- {s}\n", .{change});
        count += 1;
    }

    if (count == 0) {
        try writer.writeAll("- Various codebase improvements\n");
    }

    return buf.toOwnedSlice() catch "various improvements";
}

/// Run the commit command analysis. Returns formatted output for display.
/// Does NOT actually create a commit.
/// Caller owns the returned string.
pub fn runCommit(allocator: Allocator, args: []const u8) ![]const u8 {
    // Parse flags
    var dry_run = false;
    var no_verify = false;
    var stage_all = false;

    var arg_iter = std.mem.splitScalar(u8, args, ' ');
    while (arg_iter.next()) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "--dry-run")) dry_run = true;
        if (std.mem.eql(u8, trimmed, "--no-verify")) no_verify = true;
        if (std.mem.eql(u8, trimmed, "--all") or std.mem.eql(u8, trimmed, "-a")) stage_all = true;
    }

    // Get git status
    const status_raw = runCommandRaw("git status --short 2>/dev/null");
    const status = if (status_raw) |r| r.stdout else "";

    if (status.len == 0) {
        return allocator.dupe(u8, "/commit: No changes detected. Make some changes first.");
    }

    // Get diff content
    const diff_raw = if (stage_all) runCommandRaw("git diff HEAD 2>/dev/null") else runCommandRaw("git diff 2>/dev/null");
    const diff = if (diff_raw) |r| r.stdout else "";

    // Get staged diff
    const staged_raw = runCommandRaw("git diff --cached 2>/dev/null");
    const staged = if (staged_raw) |r| r.stdout else "";

    // Get recent commit log for style analysis
    const log_raw = runCommand(allocator, "git log --oneline -10 2>/dev/null");
    const log = log_raw orelse "";

    // Analyze commit style
    const style = analyzeCommitStyle(allocator, log) catch CommitStyle{};

    // Determine which diff to use for message generation
    const active_diff = if (staged.len > 0) staged else diff;
    if (active_diff.len == 0) {
        return allocator.dupe(u8, "/commit: No staged or unstaged changes to analyze.");
    }

    // Generate proposed commit message
    const proposed_msg = generateCommitMessage(allocator, active_diff, style) catch
        "chore: update codebase";

    // Format output
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("/commit: Analyzing changes...\n\n");

    // Show status
    try writer.writeAll("Staged files:\n");
    var has_staged = false;
    var status_lines = std.mem.splitScalar(u8, status, '\n');
    while (status_lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len < 4) continue;

        const status_code = trimmed_line[0..2];
        const file_path = std.mem.trim(u8, trimmed_line[3..], " ");

        if (status_code[0] != ' ' and status_code[0] != '?') {
            try writer.print("  {s} {s}\n", .{ status_code, file_path });
            has_staged = true;
        }
    }

    if (!has_staged) {
        try writer.writeAll("  (none — use /commit --all or git add to stage)\n");
    }

    // Show recent commit style
    if (log.len > 0) {
        try writer.writeAll("\nRecent commit style:\n");
        var log_lines = std.mem.splitScalar(u8, log, '\n');
        var log_count: usize = 0;
        while (log_lines.next()) |ll| {
            if (ll.len == 0) continue;
            try writer.print("  {s}\n", .{ll});
            log_count += 1;
            if (log_count >= 5) break;
        }
    }

    // Show proposed message
    try writer.writeAll("\nProposed commit message:\n");
    try writer.writeAll("\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\n"); // ─────────────────────
    try writer.writeAll(proposed_msg);
    try writer.writeAll("\n");
    try writer.writeAll("\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\n");

    if (dry_run) {
        try writer.writeAll("\n(dry-run mode — no changes made)");
    } else {
        try writer.writeAll("\nReview the proposed message above and edit as needed.");
    }

    return buf.toOwnedSlice();
}
