const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DiffLineKind = enum { equal, insert, delete };

pub const DiffLine = struct {
    kind: DiffLineKind,
    content: []const u8,
    old_line_num: ?u32,
    new_line_num: ?u32,
};

pub const DiffHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []DiffLine,
};

pub const DiffResult = struct {
    hunks: []DiffHunk,
    allocator: Allocator,

    pub fn deinit(self: *DiffResult) void {
        for (self.hunks) |hunk| {
            self.allocator.free(hunk.lines);
        }
        self.allocator.free(self.hunks);
    }
};

const EditStep = struct {
    kind: DiffLineKind,
    old_idx: usize,
    new_idx: usize,
};

/// Split text into lines. Trailing newline does not create an empty last line.
fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    if (text.len == 0) return allocator.alloc([]const u8, 0);

    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        try lines.append(allocator, line);
    }

    // Remove trailing empty element produced by trailing newline
    if (text[text.len - 1] == '\n') {
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
            lines.items.len -= 1;
        }
    }

    return lines.toOwnedSlice(allocator);
}

/// Compute the shortest edit script using Myers O(ND) algorithm.
fn computeEditScript(allocator: Allocator, a: []const []const u8, b: []const []const u8) ![]EditStep {
    const n = a.len;
    const m = b.len;

    if (n == 0 and m == 0) return allocator.alloc(EditStep, 0);

    const max_d = n + m;
    const offset: isize = @intCast(max_d);

    // V array indexed by diagonal k: v[offset + k] = furthest-reaching x
    var v = try allocator.alloc(isize, 2 * max_d + 1);
    defer allocator.free(v);
    @memset(v, -1);
    v[@intCast(offset + 1)] = 0;

    // Snapshots of V at each step for backtracking
    var trace = std.ArrayList([]isize).empty;
    defer {
        for (trace.items) |snap| allocator.free(snap);
        trace.deinit(allocator);
    }

    var edit_distance: usize = 0;

    outer: for (0..max_d + 1) |d| {
        const snap = try allocator.dupe(isize, v);
        try trace.append(allocator, snap);

        const d_signed: isize = @intCast(d);
        var k: isize = -d_signed;
        while (k <= d_signed) : (k += 2) {
            var x: isize = blk: {
                if (k == -d_signed or (k != d_signed and
                    v[@intCast(offset + k - 1)] < v[@intCast(offset + k + 1)]))
                {
                    break :blk v[@intCast(offset + k + 1)]; // down / insert
                } else {
                    break :blk v[@intCast(offset + k - 1)] + 1; // right / delete
                }
            };

            var y = x - k;

            // Snake: extend along diagonal while lines are equal
            while (x >= 0 and x < n and y >= 0 and y < m and
                std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }

            v[@intCast(offset + k)] = x;

            if (x >= n and y >= m) {
                edit_distance = d;
                break :outer;
            }
        }
    }

    // Backtrack through trace to build edit script (collected in reverse)
    var steps = std.ArrayList(EditStep).empty;
    errdefer steps.deinit(allocator);

    var x: isize = @intCast(n);
    var y: isize = @intCast(m);

    var d: isize = @intCast(edit_distance);
    while (d > 0) : (d -= 1) {
        const k = x - y;
        const v_prev = trace.items[@intCast(d)];

        const prev_k: isize = if (k == -d or (k != d and
            v_prev[@intCast(offset + k - 1)] < v_prev[@intCast(offset + k + 1)]))
            k + 1
        else
            k - 1;

        const prev_x = v_prev[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;

        // Start of the snake on diagonal k after the edit step
        const start_x: isize = if (prev_k == k - 1) prev_x + 1 else prev_x;
        const start_y = start_x - k;
        _ = start_y; // used only for documentation clarity

        // Snake (equal) in reverse
        while (x > start_x) {
            x -= 1;
            y -= 1;
            try steps.append(allocator, .{ .kind = .equal, .old_idx = @intCast(x), .new_idx = @intCast(y) });
        }

        // The edit step itself
        if (prev_k == k - 1) {
            // Moved right → delete from old
            try steps.append(allocator, .{ .kind = .delete, .old_idx = @intCast(prev_x), .new_idx = @intCast(y) });
        } else {
            // Moved down → insert from new
            try steps.append(allocator, .{ .kind = .insert, .old_idx = @intCast(x), .new_idx = @intCast(prev_y) });
        }

        x = prev_x;
        y = prev_y;
    }

    // Remaining diagonal at d=0 (all equal)
    while (x > 0) {
        x -= 1;
        y -= 1;
        try steps.append(allocator, .{ .kind = .equal, .old_idx = @intCast(x), .new_idx = @intCast(y) });
    }

    std.mem.reverse(EditStep, steps.items);

    return steps.toOwnedSlice(allocator);
}

/// Convert edit steps into DiffLines with correct 1-based line numbers.
fn buildDiffLines(
    allocator: Allocator,
    steps: []const EditStep,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]DiffLine {
    var result = std.ArrayList(DiffLine).empty;
    errdefer result.deinit(allocator);

    for (steps) |step| {
        const line: DiffLine = switch (step.kind) {
            .equal => .{
                .kind = .equal,
                .content = old_lines[step.old_idx],
                .old_line_num = @intCast(step.old_idx + 1),
                .new_line_num = @intCast(step.new_idx + 1),
            },
            .delete => .{
                .kind = .delete,
                .content = old_lines[step.old_idx],
                .old_line_num = @intCast(step.old_idx + 1),
                .new_line_num = null,
            },
            .insert => .{
                .kind = .insert,
                .content = new_lines[step.new_idx],
                .old_line_num = null,
                .new_line_num = @intCast(step.new_idx + 1),
            },
        };
        try result.append(allocator, line);
    }

    return result.toOwnedSlice(allocator);
}

/// Group DiffLines into hunks with 3 lines of context before/after each change.
fn groupIntoHunks(allocator: Allocator, diff_lines: []DiffLine) !DiffResult {
    if (diff_lines.len == 0) {
        return DiffResult{ .hunks = try allocator.alloc(DiffHunk, 0), .allocator = allocator };
    }

    // Early exit if no changes
    var has_changes = false;
    for (diff_lines) |dl| {
        if (dl.kind != .equal) {
            has_changes = true;
            break;
        }
    }
    if (!has_changes) {
        return DiffResult{ .hunks = try allocator.alloc(DiffHunk, 0), .allocator = allocator };
    }

    const context_lines: usize = 3;

    // Mark lines to include in hunks
    var included = try allocator.alloc(bool, diff_lines.len);
    defer allocator.free(included);
    @memset(included, false);

    for (diff_lines, 0..) |dl, i| {
        if (dl.kind != .equal) {
            const start = if (i >= context_lines) i - context_lines else 0;
            const end = @min(i + context_lines + 1, diff_lines.len);
            for (start..end) |j| {
                included[j] = true;
            }
        }
    }

    // Build hunks from consecutive included lines
    var hunks = std.ArrayList(DiffHunk).empty;
    errdefer {
        for (hunks.items) |hunk| allocator.free(hunk.lines);
        hunks.deinit(allocator);
    }

    var i: usize = 0;
    while (i < diff_lines.len) {
        if (!included[i]) {
            i += 1;
            continue;
        }

        const hunk_start = i;
        while (i < diff_lines.len and included[i]) : (i += 1) {}
        const hunk_end = i;

        const hunk_lines = try allocator.alloc(DiffLine, hunk_end - hunk_start);
        @memcpy(hunk_lines, diff_lines[hunk_start..hunk_end]);

        // Compute hunk header values
        var old_count: u32 = 0;
        var new_count: u32 = 0;
        var old_start: u32 = 0;
        var new_start: u32 = 0;

        for (hunk_lines, 0..) |line, idx| {
            switch (line.kind) {
                .equal => {
                    old_count += 1;
                    new_count += 1;
                    if (idx == 0) {
                        old_start = line.old_line_num orelse 0;
                        new_start = line.new_line_num orelse 0;
                    }
                },
                .delete => {
                    old_count += 1;
                    if (old_start == 0) old_start = line.old_line_num orelse 0;
                },
                .insert => {
                    new_count += 1;
                    if (new_start == 0) new_start = line.new_line_num orelse 0;
                },
            }
        }

        try hunks.append(allocator, .{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .lines = hunk_lines,
        });
    }

    return DiffResult{
        .hunks = try hunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Myers diff engine. Content slices reference the input texts — caller must
/// keep old_text / new_text alive for the lifetime of the DiffResult.
pub const MyersDiff = struct {
    pub fn diff(allocator: Allocator, old_text: []const u8, new_text: []const u8) !DiffResult {
        const old_lines = try splitLines(allocator, old_text);
        defer allocator.free(old_lines);
        const new_lines = try splitLines(allocator, new_text);
        defer allocator.free(new_lines);

        const steps = try computeEditScript(allocator, old_lines, new_lines);
        defer allocator.free(steps);

        const diff_lines = try buildDiffLines(allocator, steps, old_lines, new_lines);
        defer allocator.free(diff_lines);

        return groupIntoHunks(allocator, diff_lines);
    }
};

/// Format a DiffResult as a unified diff string.
/// Output matches the format parsed by src/tui/diff.zig parseDiff.
pub fn formatUnifiedDiff(
    allocator: Allocator,
    result: *DiffResult,
    old_path: []const u8,
    new_path: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // File headers
    try buf.appendSlice(allocator, "--- a/");
    try buf.appendSlice(allocator, old_path);
    try buf.appendSlice(allocator, "\n+++ b/");
    try buf.appendSlice(allocator, new_path);
    try buf.appendSlice(allocator, "\n");

    var tmp: [256]u8 = undefined;

    for (result.hunks) |hunk| {
        const header = std.fmt.bufPrint(&tmp, "@@ -{d},{d} +{d},{d} @@\n", .{
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count,
        }) catch |err| {
            // Hunk header formatting failed - return error to caller
            return err;
        };
        try buf.appendSlice(allocator, header);

        for (hunk.lines) |line| {
            const prefix: u8 = switch (line.kind) {
                .equal => ' ',
                .delete => '-',
                .insert => '+',
            };
            try buf.append(allocator, prefix);
            try buf.appendSlice(allocator, line.content);
            try buf.append(allocator, '\n');
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Compute a flat edit script (no hunk grouping) with line numbers.
pub fn diffToEditScript(allocator: Allocator, old_text: []const u8, new_text: []const u8) ![]DiffLine {
    const old_lines = try splitLines(allocator, old_text);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new_text);
    defer allocator.free(new_lines);

    const steps = try computeEditScript(allocator, old_lines, new_lines);
    defer allocator.free(steps);

    return buildDiffLines(allocator, steps, old_lines, new_lines);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "identical strings produce empty diff" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "abc\n", "abc\n");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.hunks.len);
}

test "simple insertion — one line changed" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "abc\n", "abcd\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    var deletes: usize = 0;
    var inserts: usize = 0;
    for (result.hunks[0].lines) |line| {
        switch (line.kind) {
            .delete => {
                deletes += 1;
                try std.testing.expectEqualStrings("abc", line.content);
            },
            .insert => {
                inserts += 1;
                try std.testing.expectEqualStrings("abcd", line.content);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), deletes);
    try std.testing.expectEqual(@as(usize, 1), inserts);
}

test "simple deletion — one line changed" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "abcd\n", "abc\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    var deletes: usize = 0;
    var inserts: usize = 0;
    for (result.hunks[0].lines) |line| {
        switch (line.kind) {
            .delete => {
                deletes += 1;
                try std.testing.expectEqualStrings("abcd", line.content);
            },
            .insert => {
                inserts += 1;
                try std.testing.expectEqualStrings("abc", line.content);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), deletes);
    try std.testing.expectEqual(@as(usize, 1), inserts);
}

test "multi-line replacement" {
    const allocator = std.testing.allocator;
    const old = "line1\nline2\nline3\n";
    const new = "line1\nreplaced\nline3\n";
    var result = try MyersDiff.diff(allocator, old, new);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    var deletes: usize = 0;
    var inserts: usize = 0;
    for (result.hunks[0].lines) |line| {
        if (line.kind == .delete) {
            deletes += 1;
            try std.testing.expectEqualStrings("line2", line.content);
        }
        if (line.kind == .insert) {
            inserts += 1;
            try std.testing.expectEqualStrings("replaced", line.content);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), deletes);
    try std.testing.expectEqual(@as(usize, 1), inserts);
}

test "mixed changes with context" {
    const allocator = std.testing.allocator;
    const old = "a\nb\nc\nd\ne\nf\ng\n";
    const new = "a\nb\nc\nX\nY\ne\nf\ng\n";
    var result = try MyersDiff.diff(allocator, old, new);
    defer result.deinit();

    try std.testing.expect(result.hunks.len >= 1);
    // Verify there are context lines surrounding the changes
    var has_context = false;
    for (result.hunks[0].lines) |line| {
        if (line.kind == .equal) has_context = true;
    }
    try std.testing.expect(has_context);
}

test "empty old text produces all inserts" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "", "a\nb\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    try std.testing.expectEqual(@as(usize, 2), result.hunks[0].lines.len);
    for (result.hunks[0].lines) |line| {
        try std.testing.expectEqual(DiffLineKind.insert, line.kind);
    }
    // Check new_start is 1 and new_count is 2
    try std.testing.expectEqual(@as(u32, 1), result.hunks[0].new_start);
    try std.testing.expectEqual(@as(u32, 2), result.hunks[0].new_count);
    try std.testing.expectEqual(@as(u32, 0), result.hunks[0].old_start);
}

test "empty new text produces all deletes" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "a\nb\n", "");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    try std.testing.expectEqual(@as(usize, 2), result.hunks[0].lines.len);
    for (result.hunks[0].lines) |line| {
        try std.testing.expectEqual(DiffLineKind.delete, line.kind);
    }
    try std.testing.expectEqual(@as(u32, 1), result.hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 2), result.hunks[0].old_count);
    try std.testing.expectEqual(@as(u32, 0), result.hunks[0].new_start);
}

test "large file with scattered changes produces multiple hunks" {
    const allocator = std.testing.allocator;

    var old_text = std.ArrayList(u8).empty;
    var new_text = std.ArrayList(u8).empty;
    defer old_text.deinit(allocator);
    defer new_text.deinit(allocator);

    for (0..100) |i| {
        var tmp: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "line{d}\n", .{i}); // 32-byte buffer sufficient for i<100
        try old_text.appendSlice(allocator, line);

        if (i == 10 or i == 50 or i == 90) {
            const changed = try std.fmt.bufPrint(&tmp, "changed{d}\n", .{i}); // 32-byte buffer sufficient for i<100
            try new_text.appendSlice(allocator, changed);
        } else {
            try new_text.appendSlice(allocator, line);
        }
    }

    var result = try MyersDiff.diff(allocator, old_text.items, new_text.items);
    defer result.deinit();

    // Three separate changes should produce at least 3 hunks (they're far apart)
    try std.testing.expect(result.hunks.len >= 3);

    for (result.hunks) |hunk| {
        try std.testing.expect(hunk.old_start > 0);
        try std.testing.expect(hunk.old_count > 0);
        try std.testing.expect(hunk.new_count > 0);
    }
}

test "formatUnifiedDiff produces valid headers" {
    const allocator = std.testing.allocator;
    var result = try MyersDiff.diff(allocator, "a\nb\nc\n", "a\nX\nc\n");
    defer result.deinit();

    const formatted = try formatUnifiedDiff(allocator, &result, "old.txt", "new.txt");
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.startsWith(u8, formatted, "--- a/old.txt\n"));
    try std.testing.expect(std.mem.indexOf(u8, formatted, "+++ b/new.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "@@ -") != null);
}

test "hunk context lines — 3 before and after" {
    const allocator = std.testing.allocator;
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
    const new = "1\n2\n3\n4\nX\n6\n7\n8\n9\n10\n";
    var result = try MyersDiff.diff(allocator, old, new);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    const hunk = result.hunks[0];

    // 3 context before + 1 delete + 1 insert + 3 context after = 8 lines
    try std.testing.expectEqual(@as(usize, 8), hunk.lines.len);

    // First 3 are context
    for (0..3) |i| {
        try std.testing.expectEqual(DiffLineKind.equal, hunk.lines[i].kind);
    }
    // Middle 2 are change
    try std.testing.expectEqual(DiffLineKind.delete, hunk.lines[3].kind);
    try std.testing.expectEqualStrings("5", hunk.lines[3].content);
    try std.testing.expectEqual(DiffLineKind.insert, hunk.lines[4].kind);
    try std.testing.expectEqualStrings("X", hunk.lines[4].content);
    // Last 3 are context
    for (5..8) |i| {
        try std.testing.expectEqual(DiffLineKind.equal, hunk.lines[i].kind);
    }
}
