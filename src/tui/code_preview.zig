/// Code Preview — CLI-level file preview and snippet display.
/// Uses plain text output (no vaxis dependency).
/// Provides CodeSnippet, DiffHunk, and CodePreview types for formatting
/// file contents, highlighted ranges, and side-by-side diffs to stdout.
const std = @import("std");
const string_utils = @import("string_utils");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

// ── Data types ────────────────────────────────────────────────────────

/// Display mode for code preview output.
pub const PreviewMode = enum {
    full,
    snippet,
    diff,
};

/// A contiguous range of lines from a file, with optional highlight.
pub const CodeSnippet = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    start_line: u32,
    end_line: u32,
    highlight_line: ?u32,

    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        content: []const u8,
        start_line: u32,
        end_line: u32,
        highlight_line: ?u32,
    ) !CodeSnippet {
        return .{
            .allocator = allocator,
            .file_path = try allocator.dupe(u8, file_path),
            .content = try allocator.dupe(u8, content),
            .start_line = start_line,
            .end_line = end_line,
            .highlight_line = highlight_line,
        };
    }

    pub fn deinit(self: *CodeSnippet) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.content);
    }
};

/// A hunk of differences between two files.
pub const DiffHunk = struct {
    left_start: u32,
    right_start: u32,
    left_lines: [][]const u8,
    right_lines: [][]const u8,

    pub fn deinit(self: *DiffHunk, allocator: std.mem.Allocator) void {
        for (self.left_lines) |line| allocator.free(line);
        allocator.free(self.left_lines);
        for (self.right_lines) |line| allocator.free(line);
        allocator.free(self.right_lines);
    }
};

// ── CodePreview ───────────────────────────────────────────────────────

pub const CodePreview = struct {
    allocator: std.mem.Allocator,
    tab_width: u32,
    max_width: u16,
    max_height: u16,
    line_number_width: u32,

    pub fn init(allocator: std.mem.Allocator) CodePreview {
        return .{
            .allocator = allocator,
            .tab_width = 4,
            .max_width = 120,
            .max_height = 40,
            .line_number_width = 6,
        };
    }

    pub fn deinit(self: *CodePreview) void {
        _ = self;
    }

    /// Load and format an entire file for display.
    /// Returns null if the file cannot be read.
    pub fn previewFile(self: CodePreview, file_path: []const u8) ?CodeSnippet {
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return null;
        const line_count = countLines(content);
        const snippet = CodeSnippet.init(self.allocator, file_path, content, 1, line_count, null) catch {
            self.allocator.free(content);
            return null;
        };
        self.allocator.free(content);
        return snippet;
    }

    /// Show ±context_lines around target_line in the given file.
    /// Returns null if the file cannot be read.
    pub fn previewSnippet(self: CodePreview, file_path: []const u8, target_line: u32, context_lines: u32) ?CodeSnippet {
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(content);

        const total_lines = countLines(content);
        if (total_lines == 0) return null;

        const start = if (target_line > context_lines + 1) target_line - context_lines else 1;
        const end = if (target_line + context_lines <= total_lines) target_line + context_lines else total_lines;

        const lines = extractLines(self.allocator, content, start, end) catch return null;
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }

        // Build snippet content from extracted lines
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (lines, 0..) |line, i| {
            if (i > 0) buf.append('\n') catch return null;
            buf.appendSlice(line) catch return null;
        }

        const snippet_content = buf.toOwnedSlice() catch return null;
        const snippet = CodeSnippet.init(self.allocator, file_path, snippet_content, start, end, target_line) catch {
            self.allocator.free(snippet_content);
            return null;
        };
        self.allocator.free(snippet_content);
        return snippet;
    }

    /// Compare two files line-by-line and produce diff hunks.
    /// Caller owns returned slice and must call deinit on each hunk.
    pub fn previewDiff(self: CodePreview, file_path_a: []const u8, file_path_b: []const u8) ?[]DiffHunk {
        const content_a = std.fs.cwd().readFileAlloc(self.allocator, file_path_a, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(content_a);
        const content_b = std.fs.cwd().readFileAlloc(self.allocator, file_path_b, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(content_b);

        const lines_a = splitLines(self.allocator, content_a) catch return null;
        errdefer {
            for (lines_a) |l| self.allocator.free(l);
            self.allocator.free(lines_a);
        }
        const lines_b = splitLines(self.allocator, content_b) catch return null;
        errdefer {
            for (lines_b) |l| self.allocator.free(l);
            self.allocator.free(lines_b);
        }

        var hunks = array_list_compat.ArrayList(DiffHunk).init(self.allocator);
        errdefer {
            for (hunks.items) |*h| h.deinit(self.allocator);
            hunks.deinit();
        }

        var ia: u32 = 0;
        var ib: u32 = 0;

        while (ia < lines_a.len or ib < lines_b.len) {
            // Find the start of a difference
            while (ia < lines_a.len and ib < lines_b.len and
                std.mem.eql(u8, lines_a[ia], lines_b[ib]))
            {
                ia += 1;
                ib += 1;
            }

            if (ia >= lines_a.len and ib >= lines_b.len) break;

            const hunk_start_a = ia;
            const hunk_start_b = ib;

            // Collect differing lines — advance until we find matching lines again
            var left_list = array_list_compat.ArrayList([]const u8).init(self.allocator);
            var right_list = array_list_compat.ArrayList([]const u8).init(self.allocator);
            errdefer {
                for (left_list.items) |l| self.allocator.free(l);
                left_list.deinit();
                for (right_list.items) |l| self.allocator.free(l);
                right_list.deinit();
            }

            // Gather non-matching lines from both sides
            while (ia < lines_a.len or ib < lines_b.len) {
                const a_match = ia < lines_a.len and ib < lines_b.len and
                    std.mem.eql(u8, lines_a[ia], lines_b[ib]);
                if (a_match) break;

                // Check if we've gone too far — if both sides have lines but they don't match,
                // add from whichever side has unmatched lines
                if (ia < lines_a.len) {
                    const duped = self.allocator.dupe(u8, lines_a[ia]) catch break;
                    left_list.append(duped) catch {
                        self.allocator.free(duped);
                        break;
                    };
                    ia += 1;
                }
                if (ib < lines_b.len) {
                    const duped = self.allocator.dupe(u8, lines_b[ib]) catch break;
                    right_list.append(duped) catch {
                        self.allocator.free(duped);
                        break;
                    };
                    ib += 1;
                }
            }

            if (left_list.items.len > 0 or right_list.items.len > 0) {
                hunks.append(.{
                    .left_start = hunk_start_a + 1, // 1-based
                    .right_start = hunk_start_b + 1,
                    .left_lines = left_list.toOwnedSlice() catch break,
                    .right_lines = right_list.toOwnedSlice() catch break,
                }) catch break;
            } else {
                left_list.deinit();
                right_list.deinit();
            }
        }

        // Free split line arrays (the lines themselves are now owned by hunks or freed above)
        for (lines_a) |l| self.allocator.free(l);
        self.allocator.free(lines_a);
        for (lines_b) |l| self.allocator.free(l);
        self.allocator.free(lines_b);

        return hunks.toOwnedSlice() catch return null;
    }

    /// Format a CodeSnippet with line numbers, file header, and optional highlight.
    /// Caller owns the returned string.
    pub fn formatSnippet(self: CodePreview, snippet: *const CodeSnippet) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        const lang = detectLanguage(snippet.file_path);

        // Header
        try w.print("──── {s} ({s}) ────\n", .{ snippet.file_path, lang });

        const lines = try splitLines(self.allocator, snippet.content);
        defer {
            for (lines) |l| self.allocator.free(l);
            self.allocator.free(lines);
        }

        for (lines, 0..) |line, i| {
            const line_num: u32 = snippet.start_line + @as(u32, @intCast(i));
            const is_highlight = snippet.highlight_line != null and snippet.highlight_line.? == line_num;

            // Expand tabs
            const expanded = try expandTabs(self.allocator, line, self.tab_width);
            defer self.allocator.free(expanded);

            // Truncate to max_width
            const visible = if (expanded.len > self.max_width) expanded[0..self.max_width] else expanded;

            if (is_highlight) {
                try w.print("► {d:>4} │ {s}\n", .{ line_num, visible });
            } else {
                try w.print("  {d:>4} │ {s}\n", .{ line_num, visible });
            }
        }

        return buf.toOwnedSlice();
    }

    /// Format diff hunks with +/- prefixes and file header.
    /// Caller owns the returned string.
    pub fn formatDiff(self: CodePreview, hunks: []const DiffHunk, path_a: []const u8, path_b: []const u8) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.print("──── diff: {s} ↔ {s} ────\n", .{ path_a, path_b });

        // Load both files to get context lines
        const content_a = std.fs.cwd().readFileAlloc(self.allocator, path_a, 10 * 1024 * 1024) catch "";
        defer if (content_a.len > 0) self.allocator.free(content_a);
        const content_b = std.fs.cwd().readFileAlloc(self.allocator, path_b, 10 * 1024 * 1024) catch "";
        defer if (content_b.len > 0) self.allocator.free(content_b);

        const lines_a = if (content_a.len > 0) try splitLines(self.allocator, content_a) else &[_][]const u8{};
        defer {
            if (content_a.len > 0) {
                for (lines_a) |l| self.allocator.free(l);
                self.allocator.free(lines_a);
            }
        }
        const lines_b = if (content_b.len > 0) try splitLines(self.allocator, content_b) else &[_][]const u8{};
        defer {
            if (content_b.len > 0) {
                for (lines_b) |l| self.allocator.free(l);
                self.allocator.free(lines_b);
            }
        }

        var cursor_a: u32 = 0;
        var cursor_b: u32 = 0;

        for (hunks) |hunk| {
            // Print context lines before this hunk
            const ctx_start_a = cursor_a;
            const ctx_end_a = hunk.left_start - 1; // left_start is 1-based
            var ca = ctx_start_a;
            var cb = cursor_b;
            while (ca < ctx_end_a and ca < lines_a.len) {
                const expanded = try expandTabs(self.allocator, lines_a[ca], self.tab_width);
                defer self.allocator.free(expanded);
                const visible = if (expanded.len > self.max_width) expanded[0..self.max_width] else expanded;
                try w.print("  {d:>4} │ {s}\n", .{ ca + 1, visible });
                ca += 1;
                if (cb < lines_b.len) cb += 1;
            }
            cursor_a = ca;
            cursor_b = cb;

            // Print removed lines (from left file)
            for (hunk.left_lines, 0..) |line, i| {
                const expanded = try expandTabs(self.allocator, line, self.tab_width);
                defer self.allocator.free(expanded);
                const visible = if (expanded.len > self.max_width) expanded[0..self.max_width] else expanded;
                const line_num = hunk.left_start + @as(u32, @intCast(i));
                try w.print("- {d:>4} │ {s}\n", .{ line_num, visible });
            }

            // Print added lines (from right file)
            for (hunk.right_lines, 0..) |line, i| {
                const expanded = try expandTabs(self.allocator, line, self.tab_width);
                defer self.allocator.free(expanded);
                const visible = if (expanded.len > self.max_width) expanded[0..self.max_width] else expanded;
                const line_num = hunk.right_start + @as(u32, @intCast(i));
                try w.print("+ {d:>4} │ {s}\n", .{ line_num, visible });
            }

            cursor_a = hunk.left_start - 1 + @as(u32, @intCast(hunk.left_lines.len));
            cursor_b = hunk.right_start - 1 + @as(u32, @intCast(hunk.right_lines.len));
        }

        // Print trailing context
        while (cursor_a < lines_a.len) {
            const expanded = try expandTabs(self.allocator, lines_a[cursor_a], self.tab_width);
            defer self.allocator.free(expanded);
            const visible = if (expanded.len > self.max_width) expanded[0..self.max_width] else expanded;
            try w.print("  {d:>4} │ {s}\n", .{ cursor_a + 1, visible });
            cursor_a += 1;
        }

        return buf.toOwnedSlice();
    }

    // ── Utility functions (free-standing) ────────────────────────────

    /// Count the number of lines in content (number of '\n').
    /// An empty string has 0 lines. A trailing newline does not add an extra line.
    pub fn countLines(content: []const u8) u32 {
        const n = string_utils.countLines(content);
        // string_utils counts trailing-newline as an extra line; code_preview doesn't
        if (content.len > 0 and content[content.len - 1] == '\n') return n - 1;
        return n;
    }

    /// Extract lines [start..end] (1-based, inclusive) from content.
    /// Caller owns returned slice and each line string.
    pub fn extractLines(allocator: std.mem.Allocator, content: []const u8, start: u32, end: u32) ![][]const u8 {
        var all_lines = array_list_compat.ArrayList([]const u8).init(allocator);
        defer all_lines.deinit();

        var iter = std.mem.splitScalar(u8, content, '\n');
        var idx: u32 = 0;
        while (iter.next()) |line| {
            idx += 1;
            if (idx >= start and idx <= end) {
                try all_lines.append(try allocator.dupe(u8, line));
            }
            if (idx > end) break;
        }

        return all_lines.toOwnedSlice();
    }

    /// Simple extension-based language detection.
    /// Returns a static string (no allocation needed).
    pub fn detectLanguage(file_path: []const u8) []const u8 {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) return "Text";

        // ext includes the dot, e.g. ".zig"
        if (std.mem.eql(u8, ext, ".zig")) return "Zig";
        if (std.mem.eql(u8, ext, ".py")) return "Python";
        if (std.mem.eql(u8, ext, ".rs")) return "Rust";
        if (std.mem.eql(u8, ext, ".ts")) return "TypeScript";
        if (std.mem.eql(u8, ext, ".tsx")) return "TypeScript";
        if (std.mem.eql(u8, ext, ".js")) return "JavaScript";
        if (std.mem.eql(u8, ext, ".jsx")) return "JavaScript";
        if (std.mem.eql(u8, ext, ".go")) return "Go";
        if (std.mem.eql(u8, ext, ".c")) return "C";
        if (std.mem.eql(u8, ext, ".h")) return "C";
        if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) return "C++";
        if (std.mem.eql(u8, ext, ".hpp")) return "C++";
        if (std.mem.eql(u8, ext, ".java")) return "Java";
        if (std.mem.eql(u8, ext, ".rb")) return "Ruby";
        if (std.mem.eql(u8, ext, ".swift")) return "Swift";
        if (std.mem.eql(u8, ext, ".kt")) return "Kotlin";
        if (std.mem.eql(u8, ext, ".scala")) return "Scala";
        if (std.mem.eql(u8, ext, ".sh")) return "Shell";
        if (std.mem.eql(u8, ext, ".bash")) return "Bash";
        if (std.mem.eql(u8, ext, ".zsh")) return "Zsh";
        if (std.mem.eql(u8, ext, ".json")) return "JSON";
        if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "YAML";
        if (std.mem.eql(u8, ext, ".toml")) return "TOML";
        if (std.mem.eql(u8, ext, ".xml")) return "XML";
        if (std.mem.eql(u8, ext, ".html")) return "HTML";
        if (std.mem.eql(u8, ext, ".css")) return "CSS";
        if (std.mem.eql(u8, ext, ".md")) return "Markdown";
        if (std.mem.eql(u8, ext, ".sql")) return "SQL";
        if (std.mem.eql(u8, ext, ".lua")) return "Lua";
        if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs")) return "Elixir";
        if (std.mem.eql(u8, ext, ".hs")) return "Haskell";
        if (std.mem.eql(u8, ext, ".ml")) return "OCaml";
        if (std.mem.eql(u8, ext, ".nim")) return "Nim";
        if (std.mem.eql(u8, ext, ".php")) return "PHP";
        if (std.mem.eql(u8, ext, ".sol")) return "Solidity";
        return "Text";
    }
};

// ── Internal helpers ──────────────────────────────────────────────────

/// Split content into owned lines (no trailing \r or \n).
fn splitLines(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var list = array_list_compat.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        // Trim trailing \r for Windows line endings
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try list.append(try allocator.dupe(u8, trimmed));
    }

    // Remove trailing empty line that splitScalar produces for content ending with \n
    while (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
        const empty = list.pop().?;
        allocator.free(empty);
    }

    return list.toOwnedSlice();
}

/// Expand tabs to spaces.
fn expandTabs(allocator: std.mem.Allocator, line: []const u8, tab_width: u32) ![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) {
        return allocator.dupe(u8, line);
    }

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();

    for (line) |ch| {
        if (ch == '\t') {
            var i: u32 = 0;
            while (i < tab_width) : (i += 1) {
                try buf.append(' ');
            }
        } else {
            try buf.append(ch);
        }
    }

    return buf.toOwnedSlice();
}

// ── CLI handler ───────────────────────────────────────────────────────

/// Print a formatted code preview to stdout.
pub fn printPreview(file_path: []const u8, highlight_line: ?u32, context_lines: u32, mode: PreviewMode) void {
    const allocator = std.heap.page_allocator;
    const stdout = file_compat.File.stdout().writer();

    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    switch (mode) {
        .full => {
            var snippet = preview.previewFile(file_path) orelse {
                stdout.print("Error: could not read file '{s}'\n", .{file_path}) catch {};
                return;
            };
            defer snippet.deinit();

            // If highlight_line is set, override the snippet's highlight
            if (highlight_line) |hl| {
                snippet.highlight_line = hl;
            }

            const formatted = preview.formatSnippet(&snippet) catch return;
            defer allocator.free(formatted);
            stdout.print("{s}", .{formatted}) catch {};
        },
        .snippet => {
            const target = highlight_line orelse {
                stdout.print("Error: --snippet requires a line number\n", .{}) catch {};
                return;
            };
            var snippet = preview.previewSnippet(file_path, target, context_lines) orelse {
                stdout.print("Error: could not read file '{s}'\n", .{file_path}) catch {};
                return;
            };
            defer snippet.deinit();

            const formatted = preview.formatSnippet(&snippet) catch return;
            defer allocator.free(formatted);
            stdout.print("{s}", .{formatted}) catch {};
        },
        .diff => {
            stdout.print("Error: diff mode requires two file paths\n", .{}) catch {};
        },
    }
}

/// Print a diff between two files to stdout.
pub fn printDiff(file_path_a: []const u8, file_path_b: []const u8) void {
    const allocator = std.heap.page_allocator;
    const stdout = file_compat.File.stdout().writer();

    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    const hunks = preview.previewDiff(file_path_a, file_path_b) orelse {
        stdout.print("Error: could not diff files '{s}' and '{s}'\n", .{ file_path_a, file_path_b }) catch {};
        return;
    };
    defer {
        for (hunks) |*h| h.deinit(allocator);
        allocator.free(hunks);
    }

    const formatted = preview.formatDiff(hunks, file_path_a, file_path_b) catch return;
    defer allocator.free(formatted);
    stdout.print("{s}", .{formatted}) catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────

test "CodeSnippet creation and deinit" {
    const allocator = std.testing.allocator;
    var snippet = try CodeSnippet.init(allocator, "test.zig", "const x = 1;", 1, 1, null);
    defer snippet.deinit();

    try std.testing.expectEqualStrings("test.zig", snippet.file_path);
    try std.testing.expectEqualStrings("const x = 1;", snippet.content);
    try std.testing.expectEqual(@as(u32, 1), snippet.start_line);
    try std.testing.expectEqual(@as(u32, 1), snippet.end_line);
    try std.testing.expect(snippet.highlight_line == null);
}

test "PreviewFile reads and returns snippet" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&buf, "test_preview_file_{}.zig", .{std.time.milliTimestamp()});
    const f = try std.fs.cwd().createFile(tmp_path, .{});
    f.writeAll("line one\nline two\nline three\n") catch {};
    f.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    var snippet = preview.previewFile(tmp_path) orelse {
        @panic("previewFile returned null");
    };
    defer snippet.deinit();

    try std.testing.expectEqualStrings(tmp_path, snippet.file_path);
    try std.testing.expectEqual(@as(u32, 1), snippet.start_line);
    try std.testing.expectEqual(@as(u32, 3), snippet.end_line);
}

test "PreviewSnippet extracts correct line range" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&buf, "test_snippet_{}.zig", .{std.time.milliTimestamp()});
    var content_list = array_list_compat.ArrayList(u8).init(allocator);
    defer content_list.deinit();
    var i: u32 = 1;
    while (i <= 20) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator, "line {d}\n", .{i});
        defer allocator.free(line);
        try content_list.appendSlice(line);
    }
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        f.writeAll(content_list.items) catch {};
        f.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    var snippet = preview.previewSnippet(tmp_path, 10, 2) orelse {
        @panic("previewSnippet returned null");
    };
    defer snippet.deinit();

    // ±2 around line 10 = lines 8..12
    try std.testing.expectEqual(@as(u32, 8), snippet.start_line);
    try std.testing.expectEqual(@as(u32, 12), snippet.end_line);
    try std.testing.expectEqual(@as(u32, 10), snippet.highlight_line.?);
}

test "FormatSnippet includes line numbers and highlight marker" {
    const allocator = std.testing.allocator;
    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    var snippet = try CodeSnippet.init(allocator, "test.zig", "hello\nworld", 1, 2, 2);
    defer snippet.deinit();

    const formatted = try preview.formatSnippet(&snippet);
    defer allocator.free(formatted);

    // Should contain the file path
    try std.testing.expect(std.mem.indexOf(u8, formatted, "test.zig") != null);
    // Should contain the highlight marker
    try std.testing.expect(std.mem.indexOf(u8, formatted, "►") != null);
    // Should contain line numbers
    try std.testing.expect(std.mem.indexOf(u8, formatted, "│") != null);
    // Should contain "world" on the highlighted line
    try std.testing.expect(std.mem.indexOf(u8, formatted, "world") != null);
}

test "DiffHunk creation" {
    const allocator = std.testing.allocator;
    const left = try allocator.dupe(u8, "old line");
    const right = try allocator.dupe(u8, "new line");

    const left_lines = try allocator.dupe([]const u8, &[_][]const u8{left});
    const right_lines = try allocator.dupe([]const u8, &[_][]const u8{right});

    var hunk = DiffHunk{
        .left_start = 1,
        .right_start = 1,
        .left_lines = left_lines,
        .right_lines = right_lines,
    };
    defer hunk.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), hunk.left_start);
    try std.testing.expectEqual(@as(u32, 1), hunk.right_start);
    try std.testing.expectEqual(@as(usize, 1), hunk.left_lines.len);
    try std.testing.expectEqual(@as(usize, 1), hunk.right_lines.len);
}

test "CountLines utility" {
    try std.testing.expectEqual(@as(u32, 0), CodePreview.countLines(""));
    try std.testing.expectEqual(@as(u32, 1), CodePreview.countLines("one"));
    try std.testing.expectEqual(@as(u32, 2), CodePreview.countLines("one\ntwo"));
    try std.testing.expectEqual(@as(u32, 2), CodePreview.countLines("one\ntwo\n"));
    try std.testing.expectEqual(@as(u32, 5), CodePreview.countLines("a\nb\nc\nd\ne"));
}

test "ExtractLines range extraction" {
    const allocator = std.testing.allocator;
    const content = "line1\nline2\nline3\nline4\nline5";
    const lines = try CodePreview.extractLines(allocator, content, 2, 4);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line2", lines[0]);
    try std.testing.expectEqualStrings("line3", lines[1]);
    try std.testing.expectEqualStrings("line4", lines[2]);
}

test "DetectLanguage from file extension" {
    try std.testing.expectEqualStrings("Zig", CodePreview.detectLanguage("main.zig"));
    try std.testing.expectEqualStrings("Python", CodePreview.detectLanguage("app.py"));
    try std.testing.expectEqualStrings("Rust", CodePreview.detectLanguage("main.rs"));
    try std.testing.expectEqualStrings("TypeScript", CodePreview.detectLanguage("index.ts"));
    try std.testing.expectEqualStrings("TypeScript", CodePreview.detectLanguage("App.tsx"));
    try std.testing.expectEqualStrings("JavaScript", CodePreview.detectLanguage("app.js"));
    try std.testing.expectEqualStrings("Go", CodePreview.detectLanguage("main.go"));
    try std.testing.expectEqualStrings("JSON", CodePreview.detectLanguage("config.json"));
    try std.testing.expectEqualStrings("Markdown", CodePreview.detectLanguage("README.md"));
    try std.testing.expectEqualStrings("Text", CodePreview.detectLanguage("Makefile"));
    try std.testing.expectEqualStrings("Text", CodePreview.detectLanguage("unknown.xyz"));
}

test "FormatDiff output contains +/- markers" {
    const allocator = std.testing.allocator;

    // Create two temp files with different content
    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const path_a = try std.fmt.bufPrint(&buf_a, "test_diff_a_{}.txt", .{ts});
    const path_b = try std.fmt.bufPrint(&buf_b, "test_diff_b_{}.txt", .{ts});

    const fa = try std.fs.cwd().createFile(path_a, .{});
    fa.writeAll("same line\nold line\ntrailing\n") catch {};
    fa.close();
    const fb = try std.fs.cwd().createFile(path_b, .{});
    fb.writeAll("same line\nnew line\ntrailing\n") catch {};
    fb.close();
    defer std.fs.cwd().deleteFile(path_a) catch {};
    defer std.fs.cwd().deleteFile(path_b) catch {};

    var preview = CodePreview.init(allocator);
    defer preview.deinit();

    const hunks = preview.previewDiff(path_a, path_b) orelse {
        @panic("previewDiff returned null");
    };
    defer {
        for (hunks) |*h| h.deinit(allocator);
        allocator.free(hunks);
    }

    const formatted = try preview.formatDiff(hunks, path_a, path_b);
    defer allocator.free(formatted);

    // Should contain diff header
    try std.testing.expect(std.mem.indexOf(u8, formatted, "diff:") != null);
    // Should contain - marker for removed lines
    try std.testing.expect(std.mem.indexOf(u8, formatted, "- ") != null);
    // Should contain + marker for added lines
    try std.testing.expect(std.mem.indexOf(u8, formatted, "+ ") != null);
}
