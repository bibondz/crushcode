/// Apply Patch tool — unified patch format for adding, updating, deleting, and moving files.
///
/// Supports four operations:
/// - add: create file with content (error if exists)
/// - update: find old_content in file, replace with new_content
/// - delete: delete the file
/// - move: rename/move file from path to destination
///
/// All operations are independent (non-atomic — partial success is reported).
const std = @import("std");
const json_helpers = @import("json_helpers");
const array_list_compat = @import("array_list_compat");
const core = @import("core_api");

const Allocator = std.mem.Allocator;

pub const PatchOperation = enum {
    add,
    update,
    delete,
    move,
};

pub const PatchEntry = struct {
    operation: PatchOperation,
    path: []const u8,
    content: ?[]const u8 = null,
    old_content: ?[]const u8 = null,
    new_content: ?[]const u8 = null,
    destination: ?[]const u8 = null,
};

pub const PatchResult = struct {
    operation: PatchOperation,
    path: []const u8,
    success: bool,
    message: []const u8,
};

/// Parse operation string into PatchOperation enum.
fn parseOperation(str: []const u8) PatchOperation {
    if (std.mem.eql(u8, str, "add")) return .add;
    if (std.mem.eql(u8, str, "update")) return .update;
    if (std.mem.eql(u8, str, "delete")) return .delete;
    if (std.mem.eql(u8, str, "move")) return .move;
    return .add;
}

const extractJsonStringField = json_helpers.extractJsonStringField;

/// Normalize whitespace in a string for fuzzy matching: collapse runs of
/// whitespace to a single space and trim leading/trailing whitespace.
fn normalizeWhitespace(allocator: Allocator, text: []const u8) ![]const u8 {
    var result = array_list_compat.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var last_was_space = false;
    var first_non_space = true;

    for (text) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!first_non_space) {
                last_was_space = true;
            }
        } else {
            if (last_was_space) {
                try result.append(' ');
                last_was_space = false;
            }
            try result.append(ch);
            first_non_space = false;
        }
    }

    return result.toOwnedSlice();
}

/// Try to find old_content in file content, using exact match first,
/// then falling back to whitespace-normalized fuzzy match.
fn findContentMatch(file_content: []const u8, old_content: []const u8, allocator: Allocator) ?usize {
    // Try exact match first
    if (std.mem.indexOf(u8, file_content, old_content)) |pos| {
        return pos;
    }

    // Fuzzy match: normalize both strings and find position
    const normalized_file = normalizeWhitespace(allocator, file_content) catch return null;
    defer allocator.free(normalized_file);
    const normalized_old = normalizeWhitespace(allocator, old_content) catch return null;
    defer allocator.free(normalized_old);

    if (std.mem.indexOf(u8, normalized_file, normalized_old)) |normalized_pos| {
        // Map normalized position back to original position (approximate)
        // Count non-space characters to find the rough original position
        var char_count: usize = 0;
        var orig_pos: usize = 0;
        var in_run: bool = false;

        for (file_content, 0..) |ch, idx| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                in_run = true;
            } else {
                if (in_run) {
                    char_count += 1;
                    in_run = false;
                } else {
                    char_count += 1;
                }
                if (char_count >= normalized_pos) {
                    orig_pos = idx;
                    break;
                }
            }
        }

        // For fuzzy match, find the exact old_content region by looking for
        // the first character of old_content near orig_pos
        const search_start = if (orig_pos > 10) orig_pos - 10 else 0;
        if (search_start < file_content.len and old_content.len > 0) {
            // Search for the first non-whitespace char of old_content
            var old_start: usize = 0;
            while (old_start < old_content.len and (old_content[old_start] == ' ' or old_content[old_start] == '\t' or old_content[old_start] == '\n' or old_content[old_start] == '\r')) {
                old_start += 1;
            }
            if (old_start < old_content.len) {
                // Search near estimated position for the start of old_content
                const first_char = old_content[old_start];
                var search_idx = search_start;
                while (search_idx < file_content.len and search_idx < orig_pos + old_content.len + 20) {
                    if (file_content[search_idx] == first_char) {
                        // Check if from this position the content roughly matches
                        return search_idx;
                    }
                    search_idx += 1;
                }
            }
        }

        // Last resort: return the approximate position
        return if (orig_pos > 0) orig_pos else 0;
    }

    return null;
}

/// Execute the Apply Patch tool.
pub fn executeApplyPatchTool(allocator: Allocator, parsed: core.ParsedToolCall) anyerror!struct { display: []const u8, result: []const u8 } {
    const args = parsed.arguments;

    // Find the "patch" array in the arguments JSON
    const patch_key = "\"patch\"";
    const patch_pos = std.mem.indexOf(u8, args, patch_key) orelse
        return error.InvalidJson;

    const after_key = args[patch_pos + patch_key.len ..];

    // Find opening [
    var bracket_pos: usize = 0;
    while (bracket_pos < after_key.len and after_key[bracket_pos] != '[') bracket_pos += 1;
    if (bracket_pos >= after_key.len) return error.InvalidJson;

    const array_content = after_key[bracket_pos + 1 ..];

    // Parse each { ... } block
    var entries = array_list_compat.ArrayList(PatchEntry).init(allocator);
    defer {
        entries.deinit();
    }

    var i: usize = 0;
    while (i < array_content.len) {
        // Find next {
        while (i < array_content.len and array_content[i] != '{') {
            if (array_content[i] == ']') break;
            i += 1;
        }
        if (i >= array_content.len or array_content[i] == ']') break;

        const block_start = i;
        var depth: u32 = 1;
        i += 1;
        while (i < array_content.len and depth > 0) {
            if (array_content[i] == '{') depth += 1;
            if (array_content[i] == '}') depth -= 1;
            if (array_content[i] == '"') {
                i += 1;
                while (i < array_content.len and array_content[i] != '"') {
                    if (array_content[i] == '\\' and i + 1 < array_content.len) i += 1;
                    i += 1;
                }
            }
            i += 1;
        }
        const block = array_content[block_start..i];

        // Extract fields
        const path_str = extractJsonStringField(block, "path") orelse continue;
        const op_str = extractJsonStringField(block, "operation") orelse "add";
        const content_str = extractJsonStringField(block, "content");
        const old_content_str = extractJsonStringField(block, "old_content");
        const new_content_str = extractJsonStringField(block, "new_content");
        const dest_str = extractJsonStringField(block, "destination");

        try entries.append(.{
            .operation = parseOperation(op_str),
            .path = path_str,
            .content = content_str,
            .old_content = old_content_str,
            .new_content = new_content_str,
            .destination = dest_str,
        });
    }

    if (entries.items.len == 0) {
        return .{
            .display = try allocator.dupe(u8, "\xf0\x9f\x94\xa7 apply_patch → no operations\n"),
            .result = try allocator.dupe(u8, "No patch operations provided"),
        };
    }

    // Execute all operations and collect results
    var results = array_list_compat.ArrayList(PatchResult).init(allocator);
    defer results.deinit();

    for (entries.items) |entry| {
        const result = executePatchOperation(allocator, entry) catch |err| PatchResult{
            .operation = entry.operation,
            .path = entry.path,
            .success = false,
            .message = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch "unknown error",
        };
        try results.append(result);
    }

    // Build summary
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    var success_count: u32 = 0;
    for (results.items) |res| {
        const indicator = if (res.success) "\xe2\x9c\x85" else "\xe2\x9d\x8c";
        const op_name: []const u8 = switch (res.operation) {
            .add => "add",
            .update => "update",
            .delete => "delete",
            .move => "move",
        };
        try writer.print("{s} {s} {s} ({s})\n", .{ indicator, op_name, res.path, res.message });
        if (res.success) success_count += 1;
    }

    const summary_header = try std.fmt.allocPrint(allocator, "Patch applied ({d}/{d} operations succeeded):\n", .{ success_count, results.items.len });
    const full_result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary_header, buf.items });

    const display = try std.fmt.allocPrint(allocator, "\xf0\x9f\x94\xa7 apply_patch → {d}/{d} operations succeeded\n", .{ success_count, results.items.len });

    return .{
        .display = display,
        .result = full_result,
    };
}

/// Execute a single patch operation.
fn executePatchOperation(allocator: Allocator, entry: PatchEntry) !PatchResult {
    switch (entry.operation) {
        .add => {
            const content = entry.content orelse "";
            // Check if file already exists
            if (std.fs.cwd().openFile(entry.path, .{})) |_| {
                return PatchResult{
                    .operation = .add,
                    .path = entry.path,
                    .success = false,
                    .message = try std.fmt.allocPrint(allocator, "file already exists", .{}),
                };
            } else |_| {}

            // Create parent directories if needed
            if (std.fs.path.dirname(entry.path)) |dir_part| {
                if (dir_part.len > 0) {
                    std.fs.cwd().makePath(dir_part) catch {};
                }
            }

            const file = try std.fs.cwd().createFile(entry.path, .{});
            defer file.close();
            try file.writeAll(content);

            return PatchResult{
                .operation = .add,
                .path = entry.path,
                .success = true,
                .message = try std.fmt.allocPrint(allocator, "created ({d} bytes)", .{content.len}),
            };
        },
        .update => {
            const old_content = entry.old_content orelse
                return PatchResult{
                    .operation = .update,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "missing old_content"),
                };
            const new_content = entry.new_content orelse
                return PatchResult{
                    .operation = .update,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "missing new_content"),
                };

            // Read current file
            const file = std.fs.cwd().openFile(entry.path, .{}) catch
                return PatchResult{
                    .operation = .update,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "file not found"),
                };
            defer file.close();
            const stat = try file.stat();
            const content = try file.readToEndAlloc(allocator, stat.size);
            defer allocator.free(content);

            // Find old_content (exact, then fuzzy)
            const match_pos = findContentMatch(content, old_content, allocator) orelse
                return PatchResult{
                    .operation = .update,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "old_content not found"),
                };

            // Build new file content
            var new_file_content = array_list_compat.ArrayList(u8).init(allocator);
            defer new_file_content.deinit();

            // Find the actual end position of old_content in the file
            // For fuzzy match, we need to determine the exact span
            const exact_pos = std.mem.indexOf(u8, content, old_content);
            const actual_pos = exact_pos orelse match_pos;
            const actual_end = if (exact_pos != null) actual_pos + old_content.len else blk: {
                // For fuzzy match, try to find a reasonable end position
                // Search forward from match_pos for the last character of old_content
                var end_pos = match_pos;
                var chars_remaining: usize = 0;
                for (old_content) |ch| {
                    if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
                        chars_remaining += 1;
                    }
                }
                var found: usize = 0;
                for (content[match_pos..], 0..) |ch, idx| {
                    if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
                        found += 1;
                        if (found >= chars_remaining) {
                            end_pos = match_pos + idx + 1;
                            break;
                        }
                    }
                }
                break :blk end_pos;
            };

            try new_file_content.appendSlice(content[0..actual_pos]);
            try new_file_content.appendSlice(new_content);
            try new_file_content.appendSlice(content[actual_end..]);

            // Write back
            const out_file = try std.fs.cwd().createFile(entry.path, .{});
            defer out_file.close();
            try out_file.writeAll(new_file_content.items);

            // Count replacements
            const replace_count: u32 = 1;

            return PatchResult{
                .operation = .update,
                .path = entry.path,
                .success = true,
                .message = try std.fmt.allocPrint(allocator, "replaced {d} section(s)", .{replace_count}),
            };
        },
        .delete => {
            std.fs.cwd().deleteFile(entry.path) catch
                return PatchResult{
                    .operation = .delete,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "file not found or cannot delete"),
                };

            return PatchResult{
                .operation = .delete,
                .path = entry.path,
                .success = true,
                .message = try allocator.dupe(u8, "deleted"),
            };
        },
        .move => {
            const dest = entry.destination orelse
                return PatchResult{
                    .operation = .move,
                    .path = entry.path,
                    .success = false,
                    .message = try allocator.dupe(u8, "missing destination"),
                };

            // Create parent directories for destination if needed
            if (std.fs.path.dirname(dest)) |dir_part| {
                if (dir_part.len > 0) {
                    std.fs.cwd().makePath(dir_part) catch {};
                }
            }

            // Try atomic rename first
            std.fs.cwd().rename(entry.path, dest) catch {
                // Fallback: copy + delete for cross-device moves
                const src_file = std.fs.cwd().openFile(entry.path, .{}) catch
                    return PatchResult{
                        .operation = .move,
                        .path = entry.path,
                        .success = false,
                        .message = try allocator.dupe(u8, "source file not found"),
                    };
                defer src_file.close();
                const src_stat = try src_file.stat();
                const content = try src_file.readToEndAlloc(allocator, src_stat.size);
                defer allocator.free(content);

                const dst_file = try std.fs.cwd().createFile(dest, .{});
                defer dst_file.close();
                try dst_file.writeAll(content);

                try std.fs.cwd().deleteFile(entry.path);
            };

            return PatchResult{
                .operation = .move,
                .path = entry.path,
                .success = true,
                .message = try std.fmt.allocPrint(allocator, "moved to {s}", .{dest}),
            };
        },
    }
}
