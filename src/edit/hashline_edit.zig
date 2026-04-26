//! Hashline Edit — hash-anchored editing system for Crushcode.
//!
//! Every Read output is tagged with LINE#ID content hashes:
//!   11#VK| function hello() {
//!   22#XJ|   return "world";
//!   33#MB| }
//!
//! Edit references line by `{lineNumber}#{hash}` — if file changed,
//! hash won't match → edit rejected. This prevents AI model errors
//! from corrupting files when whitespace, encoding, or concurrent
//! changes would cause standard edit tools to fail.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 1. Hash computation
// ---------------------------------------------------------------------------

/// 16-character dictionary for 2-char hash encoding.
/// Characters chosen to be visually distinct and avoid common ambiguous pairs.
const HASHLINE_DICT = "ZPMQVRWSNKTXJBYH";

/// Compute a 2-byte hash for a line of content using XxHash32.
///
/// The hash is derived from the line content with trailing whitespace stripped.
/// If the line contains alphanumeric characters, seed=0 is used; otherwise
/// the line_number is used as seed (so blank/whitespace-only lines at
/// different positions produce different hashes).
pub fn computeLineHash(line_number: u32, content: []const u8) [2]u8 {
    const stripped = std.mem.trimRight(u8, content, " \t\r\n");

    // Determine seed: use line_number as seed for lines without alphanumeric content
    var has_alnum = false;
    for (stripped) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            has_alnum = true;
            break;
        }
    }
    const seed: u32 = if (has_alnum) 0 else line_number;

    const hash = std.hash.XxHash32.hash(seed, stripped);
    const idx: u32 = hash % 256;
    return .{ HASHLINE_DICT[idx / 16], HASHLINE_DICT[idx % 16] };
}

// ---------------------------------------------------------------------------
// 2. Read output format
// ---------------------------------------------------------------------------

/// Format a single line with hash for Read output.
///
/// Returns a string in the format: `{line_num}#{h0}{h1}| {content}`
/// Caller owns the returned slice.
pub fn formatLineWithHash(allocator: Allocator, line_num: u32, content: []const u8) ![]const u8 {
    const hash = computeLineHash(line_num, content);
    return std.fmt.allocPrint(allocator, "{d}#{c}{c}| {s}", .{
        line_num,
        hash[0],
        hash[1],
        content,
    });
}

/// Format an entire file's content with hashline annotations.
///
/// Each line becomes: `{line_num}#{h0}{h1}| {line_content}\n`
/// Caller owns the returned slice.
pub fn formatFileWithHashlineEdit(allocator: Allocator, content: []const u8) ![]const u8 {
    var output = array_list_compat.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 1;

    while (lines.next()) |line| {
        const hash = computeLineHash(line_num, line);
        try output.writer().print("{d}#{c}{c}| {s}\n", .{
            line_num,
            hash[0],
            hash[1],
            line,
        });
        line_num += 1;
    }

    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// 3. Parse line references from edit commands
// ---------------------------------------------------------------------------

/// A parsed line reference in the format `{lineNumber}#{hash}`.
pub const LineRef = struct {
    line: u32,
    hash: [2]u8,
};

/// Parse a line reference string like "42#VK" into its components.
///
/// Returns null if the string is not in the expected format.
pub fn parseLineRef(ref: []const u8) ?LineRef {
    const hash_idx = std.mem.indexOfScalar(u8, ref, '#') orelse return null;
    const line_num = std.fmt.parseInt(u32, ref[0..hash_idx], 10) catch return null;
    // Need at least 2 characters after '#'
    if (ref.len < hash_idx + 3) return null;
    return LineRef{
        .line = line_num,
        .hash = .{ ref[hash_idx + 1], ref[hash_idx + 2] },
    };
}

// ---------------------------------------------------------------------------
// 4. Validate edit against current file content
// ---------------------------------------------------------------------------

/// Validate that the hash at a given line number matches the expected hash.
///
/// Splits `lines` by newline and checks line `line_num` (1-indexed).
/// Returns true if the computed hash matches `expected_hash`.
pub fn validateLineHash(lines: []const u8, line_num: u32, expected_hash: [2]u8) bool {
    var line_iter = std.mem.splitScalar(u8, lines, '\n');
    var current: u32 = 1;
    while (line_iter.next()) |line| {
        if (current == line_num) {
            const actual = computeLineHash(line_num, line);
            return actual[0] == expected_hash[0] and actual[1] == expected_hash[1];
        }
        current += 1;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 5. Edit operations
// ---------------------------------------------------------------------------

/// The type of edit operation to perform.
pub const HashlineOperation = enum {
    replace,
    append,
    prepend,
};

/// A single hashline edit operation.
pub const HashlineEdit = struct {
    line_ref: LineRef,
    operation: HashlineOperation,
    content: []const u8,
};

// ---------------------------------------------------------------------------
// 6. Apply pipeline
// ---------------------------------------------------------------------------

/// Result of applying hashline edits to file content.
pub const HashlineEditResult = struct {
    success: bool,
    applied_count: u32,
    failed_index: ?u32,
    error_message: ?[]const u8,
    new_content: ?[]const u8,

    pub fn deinit(self: *const HashlineEditResult, allocator: Allocator) void {
        if (self.error_message) |msg| allocator.free(msg);
        if (self.new_content) |nc| allocator.free(nc);
    }
};

/// Internal representation for sorted/deduplicated edits.
const InternalEdit = struct {
    line_num: u32,
    hash: [2]u8,
    operation: HashlineOperation,
    content: []const u8,
    original_index: u32,
};

/// Apply hashline edits to file content.
///
/// Pipeline:
///   1. Parse all edits from JSON
///   2. Validate all hashes against current content
///   3. Order edits bottom-up (higher line numbers first) to preserve positions
///   4. Deduplicate (same line reference → keep last)
///   5. Apply each edit
///   6. Return result with new content
pub fn applyHashlineEdits(allocator: Allocator, file_content: []const u8, edits_json: []const u8) !HashlineEditResult {
    // Parse JSON edits
    const ParsedEdit = struct {
        line_ref: []const u8,
        operation: []const u8,
        content: []const u8,
    };
    const EditsContainer = struct {
        edits: []const ParsedEdit,
    };

    var parsed = std.json.parseFromSlice(EditsContainer, allocator, edits_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        return failResult(allocator, 0, "Failed to parse edits JSON");
    };
    defer parsed.deinit();

    const raw_edits = parsed.value.edits;
    if (raw_edits.len == 0) {
        return failResult(allocator, 0, "No edits provided");
    }

    // Parse each edit into InternalEdit
    var edits = array_list_compat.ArrayList(InternalEdit).init(allocator);
    defer edits.deinit();

    for (raw_edits, 0..) |raw, i| {
        const line_ref = parseLineRef(raw.line_ref) orelse {
            return failResult(allocator, @intCast(i), "Invalid line reference format");
        };

        const op = parseOperation(raw.operation) orelse {
            return failResult(allocator, @intCast(i), "Invalid operation");
        };

        try edits.append(.{
            .line_num = line_ref.line,
            .hash = line_ref.hash,
            .operation = op,
            .content = raw.content,
            .original_index = @intCast(i),
        });
    }

    // Deduplicate: same line reference → keep last occurrence
    // Sort by original_index descending, then deduplicate by (line_num, hash)
    const sortByOriginalDesc = struct {
        fn lessThan(_: void, a: InternalEdit, b: InternalEdit) bool {
            return a.original_index > b.original_index;
        }
    }.lessThan;
    std.sort.insertion(InternalEdit, edits.items, {}, sortByOriginalDesc);

    var deduped = array_list_compat.ArrayList(InternalEdit).init(allocator);
    defer deduped.deinit();

    // Track seen (line_num, hash0, hash1) to deduplicate
    var seen = array_list_compat.ArrayList(struct { line: u32, h0: u8, h1: u8 }).init(allocator);
    defer seen.deinit();

    for (edits.items) |edit| {
        var is_dup = false;
        for (seen.items) |s| {
            if (s.line == edit.line_num and s.h0 == edit.hash[0] and s.h1 == edit.hash[1]) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try seen.append(.{ .line = edit.line_num, .h0 = edit.hash[0], .h1 = edit.hash[1] });
            try deduped.append(edit);
        }
    }

    // Validate all hashes against current content
    for (deduped.items) |edit| {
        if (!validateLineHash(file_content, edit.line_num, edit.hash)) {
            return failResult(allocator, edit.original_index, "Hash mismatch — file has changed");
        }
    }

    // Sort bottom-up (higher line numbers first) to preserve positions
    const sortByLineDesc = struct {
        fn lessThan(_: void, a: InternalEdit, b: InternalEdit) bool {
            return a.line_num > b.line_num;
        }
    }.lessThan;
    std.sort.insertion(InternalEdit, deduped.items, {}, sortByLineDesc);

    // Split content into lines
    var lines = array_list_compat.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    var line_iter = std.mem.splitScalar(u8, file_content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(line);
    }

    // Apply each edit
    var applied: u32 = 0;
    for (deduped.items) |edit| {
        const idx = if (edit.line_num > 0) edit.line_num - 1 else 0;

        switch (edit.operation) {
            .replace => {
                if (idx < lines.items.len) {
                    lines.items[idx] = edit.content;
                    applied += 1;
                }
            },
            .append => {
                if (idx < lines.items.len) {
                    // Insert after the referenced line
                    try lines.insert(edit.content, idx + 1);
                    applied += 1;
                }
            },
            .prepend => {
                // Insert before the referenced line
                const insert_idx = if (idx < lines.items.len) idx else lines.items.len;
                try lines.insert(edit.content, insert_idx);
                applied += 1;
            },
        }
    }

    // Rebuild content
    var output = array_list_compat.ArrayList(u8).init(allocator);
    for (lines.items, 0..) |line, i| {
        if (i > 0) try output.append('\n');
        try output.appendSlice(line);
    }

    const new_content = try output.toOwnedSlice();
    const msg = try std.fmt.allocPrint(allocator, "Applied {d} edit(s)", .{applied});
    return HashlineEditResult{
        .success = true,
        .applied_count = applied,
        .failed_index = null,
        .error_message = msg,
        .new_content = new_content,
    };
}

/// Parse operation string into HashlineOperation enum.
fn parseOperation(op_str: []const u8) ?HashlineOperation {
    if (std.mem.eql(u8, op_str, "replace")) return .replace;
    if (std.mem.eql(u8, op_str, "append")) return .append;
    if (std.mem.eql(u8, op_str, "prepend")) return .prepend;
    return null;
}

/// Helper to create a failure result.
fn failResult(allocator: Allocator, failed_index: u32, message: []const u8) HashlineEditResult {
    const msg = allocator.dupe(u8, message) catch @constCast(message);
    return HashlineEditResult{
        .success = false,
        .applied_count = 0,
        .failed_index = failed_index,
        .error_message = msg,
        .new_content = null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "computeLineHash — basic content" {
    const hash = computeLineHash(1, "function hello() {\n");
    // Same content with different line numbers should produce same hash (has alnum)
    const hash2 = computeLineHash(2, "function hello() {\n");
    try testing.expectEqual(hash[0], hash2[0]);
    try testing.expectEqual(hash[1], hash2[1]);
    // Verify the hash characters are from the dictionary
    try testing.expect(std.mem.indexOfScalar(u8, HASHLINE_DICT, hash[0]) != null);
    try testing.expect(std.mem.indexOfScalar(u8, HASHLINE_DICT, hash[1]) != null);
}

test "computeLineHash — empty/whitespace lines use line number as seed" {
    const hash1 = computeLineHash(1, "   \n");
    const hash2 = computeLineHash(2, "   \n");
    // Different line numbers with no alnum → different hashes
    try testing.expect(hash1[0] != hash2[0] or hash1[1] != hash2[1]);
}

test "computeLineHash — consistent for same content" {
    const hash1 = computeLineHash(10, "const x = 42;");
    const hash2 = computeLineHash(10, "const x = 42;");
    try testing.expectEqual(hash1[0], hash2[0]);
    try testing.expectEqual(hash1[1], hash2[1]);
}

test "formatLineWithHash — produces expected format" {
    const result = try formatLineWithHash(testing.allocator, 42, "hello world");
    defer testing.allocator.free(result);
    // Should start with "42#" and contain "| hello world"
    try testing.expect(std.mem.startsWith(u8, result, "42#"));
    try testing.expect(std.mem.indexOf(u8, result, "| hello world") != null);
    // Hash should be exactly 2 characters between '#' and '|'
    const hash_start = std.mem.indexOfScalar(u8, result, '#').? + 1;
    const hash_end = std.mem.indexOfScalar(u8, result, '|').?;
    try testing.expectEqual(@as(usize, 2), hash_end - hash_start);
}

test "parseLineRef — valid reference" {
    const ref = parseLineRef("42#VK");
    try testing.expect(ref != null);
    const r = ref.?;
    try testing.expectEqual(@as(u32, 42), r.line);
    try testing.expectEqual(@as(u8, 'V'), r.hash[0]);
    try testing.expectEqual(@as(u8, 'K'), r.hash[1]);
}

test "parseLineRef — missing hash" {
    try testing.expect(parseLineRef("42#") == null);
    try testing.expect(parseLineRef("42#V") == null);
}

test "parseLineRef — missing hash separator" {
    try testing.expect(parseLineRef("42VK") == null);
}

test "parseLineRef — invalid line number" {
    try testing.expect(parseLineRef("abc#VK") == null);
}

test "validateLineHash — matching hash" {
    const content = "line one\nline two\nline three\n";
    const hash = computeLineHash(2, "line two");
    try testing.expect(validateLineHash(content, 2, hash));
}

test "validateLineHash — mismatched hash" {
    const content = "line one\nline two\nline three\n";
    const hash = computeLineHash(2, "line two");
    // Use wrong hash
    const wrong: [2]u8 = .{ 'X', 'X' };
    if (hash[0] == wrong[0] and hash[1] == wrong[1]) return; // skip if collision
    try testing.expect(!validateLineHash(content, 2, wrong));
}

test "validateLineHash — line out of range" {
    const content = "line one\nline two\n";
    try testing.expect(!validateLineHash(content, 10, .{ 'V', 'K' }));
}

test "applyHashlineEdits — single replace" {
    const content = "first line\nsecond line\nthird line\n";
    const hash = computeLineHash(2, "second line");

    const hash_str = try std.fmt.allocPrint(testing.allocator, "2#{c}{c}", .{ hash[0], hash[1] });
    defer testing.allocator.free(hash_str);

    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"edits": [{{"line_ref": "{s}", "operation": "replace", "content": "REPLACED"}}]}}
    , .{hash_str});
    defer testing.allocator.free(json);

    var result = try applyHashlineEdits(testing.allocator, content, json);
    defer result.deinit(testing.allocator);
    try testing.expect(result.success);
    try testing.expectEqual(@as(u32, 1), result.applied_count);
    try testing.expect(result.new_content != null);
    try testing.expect(std.mem.indexOf(u8, result.new_content.?, "REPLACED") != null);
    try testing.expect(std.mem.indexOf(u8, result.new_content.?, "second line") == null);
}

test "applyHashlineEdits — hash mismatch rejection" {
    const content = "first line\nsecond line\nthird line\n";
    // Use a wrong hash
    const json =
        \\{"edits": [{"line_ref": "2#XX", "operation": "replace", "content": "REPLACED"}]}
    ;

    var result = try applyHashlineEdits(testing.allocator, content, json);
    defer result.deinit(testing.allocator);
    try testing.expect(!result.success);
    try testing.expect(result.error_message != null);
}

test "applyHashlineEdits — append after line" {
    const content = "line one\nline two\n";
    const hash = computeLineHash(1, "line one");

    const hash_str = try std.fmt.allocPrint(testing.allocator, "1#{c}{c}", .{ hash[0], hash[1] });
    defer testing.allocator.free(hash_str);

    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"edits": [{{"line_ref": "{s}", "operation": "append", "content": "INSERTED"}}]}}
    , .{hash_str});
    defer testing.allocator.free(json);

    var result = try applyHashlineEdits(testing.allocator, content, json);
    defer result.deinit(testing.allocator);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.new_content.?, "INSERTED") != null);
}

test "applyHashlineEdits — prepend before line" {
    const content = "line one\nline two\n";
    const hash = computeLineHash(2, "line two");

    const hash_str = try std.fmt.allocPrint(testing.allocator, "2#{c}{c}", .{ hash[0], hash[1] });
    defer testing.allocator.free(hash_str);

    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"edits": [{{"line_ref": "{s}", "operation": "prepend", "content": "BEFORE"}}]}}
    , .{hash_str});
    defer testing.allocator.free(json);

    var result = try applyHashlineEdits(testing.allocator, content, json);
    defer result.deinit(testing.allocator);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.new_content.?, "BEFORE") != null);
}

test "formatFileWithHashlineEdit — annotates all lines" {
    const content = "hello\nworld\n";
    const result = try formatFileWithHashlineEdit(testing.allocator, content);
    defer testing.allocator.free(result);

    // Should have hash annotations for both lines
    try testing.expect(std.mem.startsWith(u8, result, "1#"));
    try testing.expect(std.mem.indexOf(u8, result, "| hello\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "2#") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| world\n") != null);
}
