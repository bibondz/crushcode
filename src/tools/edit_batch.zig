const std = @import("std");
const string_utils = @import("string_utils");
const json_helpers = @import("json_helpers");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

pub const EditOperation = enum {
    create,
    replace,
    append,
    delete_content,
};

pub const FileEdit = struct {
    file_path: []const u8,
    operation: EditOperation,
    old_string: ?[]const u8 = null,
    new_string: ?[]const u8 = null,
};

pub const EditDetail = struct {
    file_path: []const u8,
    status: enum { applied, skipped, failed, rolled_back },
    message: []const u8,
};

pub const BatchResult = struct {
    success: bool,
    applied_edits: u32,
    failed_edit_index: ?u32 = null,
    error_message: ?[]const u8 = null,
    rollback_performed: bool = false,
    details: []EditDetail,

    pub fn deinit(self: *const BatchResult, allocator: Allocator) void {
        for (self.details) |d| {
            allocator.free(d.file_path);
            allocator.free(d.message);
        }
        allocator.free(self.details);
        if (self.error_message) |msg| allocator.free(msg);
    }
};

const extractJsonStringField = json_helpers.extractJsonStringField;

/// Parse an operation string into the EditOperation enum.
fn parseOperation(op_str: []const u8) EditOperation {
    if (std.mem.eql(u8, op_str, "create")) return .create;
    if (std.mem.eql(u8, op_str, "replace")) return .replace;
    if (std.mem.eql(u8, op_str, "append")) return .append;
    if (std.mem.eql(u8, op_str, "delete_content")) return .delete_content;
    return .create; // default fallback
}

const countLines = string_utils.countLines;

/// Read entire file content into an allocated slice.
fn readFileContent(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

/// Write content to a file, creating or overwriting.
fn writeFileContent(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Parse the JSON edits array into a list of FileEdit structs.
fn parseEdits(allocator: Allocator, edits_json: []const u8) ![]FileEdit {
    var edits = array_list_compat.ArrayList(FileEdit).init(allocator);
    errdefer {
        for (edits.items) |_| {}
        edits.deinit();
    }

    // Find "edits" key and opening bracket
    const edits_key = "\"edits\"";
    const edits_pos = std.mem.indexOf(u8, edits_json, edits_key) orelse return error.InvalidJson;
    const after_key = edits_json[edits_pos + edits_key.len ..];

    // Find opening [
    var bracket_pos: usize = 0;
    while (bracket_pos < after_key.len and after_key[bracket_pos] != '[') bracket_pos += 1;
    if (bracket_pos >= after_key.len) return error.InvalidJson;

    const array_content = after_key[bracket_pos + 1 ..];

    // Parse each { ... } block
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

        // Extract fields from this block
        const file_path = extractJsonStringField(block, "file_path") orelse continue;
        const op_str = extractJsonStringField(block, "operation") orelse "create";
        const old_string = extractJsonStringField(block, "old_string");
        const new_string = extractJsonStringField(block, "new_string");

        try edits.append(.{
            .file_path = file_path,
            .operation = parseOperation(op_str),
            .old_string = old_string,
            .new_string = new_string,
        });
    }

    return edits.toOwnedSlice() catch |err| {
        edits.deinit();
        return err;
    };
}

/// Backup entry storing original file content for rollback.
const BackupEntry = struct {
    file_path: []const u8,
    content: ?[]const u8, // null means file did not exist
};

/// Apply multiple file edits atomically. All succeed or all roll back.
pub fn applyBatchEdit(allocator: Allocator, edits_json: []const u8) !BatchResult {
    const edits = try parseEdits(allocator, edits_json);
    defer {
        for (edits) |_| {}
        allocator.free(edits);
    }

    if (edits.len == 0) {
        return BatchResult{
            .success = true,
            .applied_edits = 0,
            .details = &.{},
        };
    }

    // Phase 1: Pre-validate all edits
    for (edits, 0..) |edit, idx| {
        switch (edit.operation) {
            .replace => {
                if (edit.old_string == null) {
                    const msg = try std.fmt.allocPrint(allocator, "Edit {d}: replace requires old_string", .{idx});
                    return BatchResult{
                        .success = false,
                        .applied_edits = 0,
                        .failed_edit_index = @intCast(idx),
                        .error_message = msg,
                        .details = &.{},
                    };
                }
                // Check file exists and contains old_string
                const content = readFileContent(allocator, edit.file_path) catch {
                    const msg = try std.fmt.allocPrint(allocator, "Edit {d}: file not found: {s}", .{ idx, edit.file_path });
                    return BatchResult{
                        .success = false,
                        .applied_edits = 0,
                        .failed_edit_index = @intCast(idx),
                        .error_message = msg,
                        .details = &.{},
                    };
                };
                defer allocator.free(content);
                if (std.mem.indexOf(u8, content, edit.old_string.?) == null) {
                    const msg = try std.fmt.allocPrint(allocator, "Edit {d}: old_string not found in {s}", .{ idx, edit.file_path });
                    return BatchResult{
                        .success = false,
                        .applied_edits = 0,
                        .failed_edit_index = @intCast(idx),
                        .error_message = msg,
                        .details = &.{},
                    };
                }
            },
            .append => {
                // File must exist for append
                _ = std.fs.cwd().statFile(edit.file_path) catch {
                    const msg = try std.fmt.allocPrint(allocator, "Edit {d}: file not found for append: {s}", .{ idx, edit.file_path });
                    return BatchResult{
                        .success = false,
                        .applied_edits = 0,
                        .failed_edit_index = @intCast(idx),
                        .error_message = msg,
                        .details = &.{},
                    };
                };
            },
            .delete_content => {
                _ = std.fs.cwd().statFile(edit.file_path) catch {
                    const msg = try std.fmt.allocPrint(allocator, "Edit {d}: file not found: {s}", .{ idx, edit.file_path });
                    return BatchResult{
                        .success = false,
                        .applied_edits = 0,
                        .failed_edit_index = @intCast(idx),
                        .error_message = msg,
                        .details = &.{},
                    };
                };
            },
            .create => {
                // Create parent directories if needed
                if (std.fs.path.dirname(edit.file_path)) |dir_part| {
                    if (dir_part.len > 0) {
                        std.fs.cwd().makePath(dir_part) catch {};
                    }
                }
            },
        }
    }

    // Phase 2: Create backups of all files that will be modified
    var backups = array_list_compat.ArrayList(BackupEntry).init(allocator);
    defer {
        for (backups.items) |b| {
            if (b.content) |c| allocator.free(c);
            allocator.free(b.file_path);
        }
        backups.deinit();
    }

    for (edits) |edit| {
        // Check if we already backed up this file
        var already_backed_up = false;
        for (backups.items) |b| {
            if (std.mem.eql(u8, b.file_path, edit.file_path)) {
                already_backed_up = true;
                break;
            }
        }
        if (already_backed_up) continue;

        const path_copy = try allocator.dupe(u8, edit.file_path);
        const content = std.fs.cwd().readFileAlloc(allocator, edit.file_path, 100 * 1024 * 1024) catch null;
        try backups.append(.{
            .file_path = path_copy,
            .content = content,
        });
    }

    // Phase 3: Apply each edit
    var details = array_list_compat.ArrayList(EditDetail).init(allocator);
    errdefer {
        for (details.items) |d| {
            allocator.free(d.file_path);
            allocator.free(d.message);
        }
        details.deinit();
    }

    var applied_count: u32 = 0;

    for (edits, 0..) |edit, idx| {
        const apply_result = applySingleEdit(allocator, edit) catch |err| {
            // Rollback all previously applied edits
            rollbackBackups(allocator, backups.items);

            // Mark all previously applied edits as rolled_back in details
            var rolled_details = array_list_compat.ArrayList(EditDetail).init(allocator);
            for (details.items) |d| {
                try rolled_details.append(.{
                    .file_path = try allocator.dupe(u8, d.file_path),
                    .status = .rolled_back,
                    .message = try std.fmt.allocPrint(allocator, "Rolled back: {s}", .{d.message}),
                });
            }
            // Add the failed edit
            try rolled_details.append(.{
                .file_path = try allocator.dupe(u8, edit.file_path),
                .status = .failed,
                .message = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}),
            });

            const err_msg = try std.fmt.allocPrint(allocator, "Failed at edit {d}: {s}", .{ idx, @errorName(err) });
            // Free the partial details
            for (details.items) |d| {
                allocator.free(d.file_path);
                allocator.free(d.message);
            }
            details.deinit();

            return BatchResult{
                .success = false,
                .applied_edits = applied_count,
                .failed_edit_index = @intCast(idx),
                .error_message = err_msg,
                .rollback_performed = true,
                .details = rolled_details.toOwnedSlice() catch &.{},
            };
        };

        applied_count += 1;
        try details.append(.{
            .file_path = try allocator.dupe(u8, edit.file_path),
            .status = .applied,
            .message = apply_result,
        });
    }

    return BatchResult{
        .success = true,
        .applied_edits = applied_count,
        .details = details.toOwnedSlice() catch &.{},
    };
}

/// Apply a single edit operation. Returns an allocated message string.
fn applySingleEdit(allocator: Allocator, edit: FileEdit) ![]const u8 {
    switch (edit.operation) {
        .create => {
            const content = edit.new_string orelse "";
            try writeFileContent(edit.file_path, content);
            return std.fmt.allocPrint(allocator, "Created {s} ({d} bytes)", .{ edit.file_path, content.len });
        },
        .replace => {
            const old = edit.old_string orelse return error.MissingOldString;
            const new_str = edit.new_string orelse return error.MissingNewString;
            const content = try readFileContent(allocator, edit.file_path);
            defer allocator.free(content);

            const pos = std.mem.indexOf(u8, content, old) orelse return error.OldStringNotFound;

            var new_content = array_list_compat.ArrayList(u8).init(allocator);
            defer new_content.deinit();
            try new_content.appendSlice(content[0..pos]);
            try new_content.appendSlice(new_str);
            try new_content.appendSlice(content[pos + old.len ..]);

            try writeFileContent(edit.file_path, new_content.items);
            return std.fmt.allocPrint(allocator, "Replaced in {s}: {d} chars → {d} chars", .{ edit.file_path, old.len, new_str.len });
        },
        .append => {
            const append_str = edit.new_string orelse "";
            const content = readFileContent(allocator, edit.file_path) catch |err| {
                if (err == error.FileNotFound) {
                    try writeFileContent(edit.file_path, append_str);
                    return std.fmt.allocPrint(allocator, "Appended to new file {s} ({d} bytes)", .{ edit.file_path, append_str.len });
                }
                return err;
            };
            defer allocator.free(content);

            var new_content = array_list_compat.ArrayList(u8).init(allocator);
            defer new_content.deinit();
            try new_content.appendSlice(content);
            try new_content.appendSlice(append_str);

            try writeFileContent(edit.file_path, new_content.items);
            return std.fmt.allocPrint(allocator, "Appended {d} bytes to {s}", .{ append_str.len, edit.file_path });
        },
        .delete_content => {
            try writeFileContent(edit.file_path, "");
            return std.fmt.allocPrint(allocator, "Cleared content of {s}", .{edit.file_path});
        },
    }
}

/// Restore all backed-up files to their original state.
fn rollbackBackups(allocator: Allocator, backups: []const BackupEntry) void {
    for (backups) |backup| {
        if (backup.content) |content| {
            writeFileContent(backup.file_path, content) catch {};
        } else {
            // File didn't exist before — delete it
            std.fs.cwd().deleteFile(backup.file_path) catch {};
        }
    }
    _ = allocator;
}

/// Generate a preview of batch edits without applying them.
pub fn previewBatchEdit(allocator: Allocator, edits_json: []const u8) ![]const u8 {
    const edits = try parseEdits(allocator, edits_json);
    defer allocator.free(edits);

    if (edits.len == 0) {
        return allocator.dupe(u8, "Batch Edit Preview: 0 edits (empty batch)");
    }

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.print("Batch Edit Preview ({d} edits):\n", .{edits.len});

    var total_added: u32 = 0;
    var total_removed: u32 = 0;

    for (edits, 0..) |edit, idx| {
        const op_name: []const u8 = switch (edit.operation) {
            .create => "create",
            .replace => "replace",
            .append => "append",
            .delete_content => "delete_content",
        };

        var added: u32 = 0;
        var removed: u32 = 0;

        switch (edit.operation) {
            .create => {
                if (edit.new_string) |s| added = countLines(s);
            },
            .replace => {
                if (edit.old_string) |s| removed = countLines(s);
                if (edit.new_string) |s| added = countLines(s);
            },
            .append => {
                if (edit.new_string) |s| added = countLines(s);
            },
            .delete_content => {
                // Read current file to count removed lines
                if (readFileContent(allocator, edit.file_path)) |content| {
                    defer allocator.free(content);
                    removed = countLines(content);
                } else |_| {}
            },
        }

        total_added += added;
        total_removed += removed;

        try writer.print("{d}. {s} — {s}\n", .{ idx + 1, edit.file_path, op_name });
        if (removed > 0 or added > 0) {
            try writer.print("   -{d} lines, +{d} lines\n", .{ removed, added });
        }
    }

    try writer.print("Total: -{d} lines, +{d} lines\n", .{ total_removed, total_added });

    return buf.toOwnedSlice() catch |err| {
        return err;
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseOperation - all variants" {
    try std.testing.expect(parseOperation("create") == .create);
    try std.testing.expect(parseOperation("replace") == .replace);
    try std.testing.expect(parseOperation("append") == .append);
    try std.testing.expect(parseOperation("delete_content") == .delete_content);
    try std.testing.expect(parseOperation("unknown") == .create);
}

test "countLines - basic" {
    try std.testing.expect(countLines("") == 0);
    try std.testing.expect(countLines("hello") == 1);
    try std.testing.expect(countLines("hello\nworld") == 2);
    try std.testing.expect(countLines("a\nb\nc\n") == 4);
}

test "extractJsonStringField - basic" {
    const json = "{\"file_path\":\"test.zig\",\"operation\":\"replace\"}";
    const fp = extractJsonStringField(json, "file_path").?;
    try std.testing.expect(std.mem.eql(u8, fp, "test.zig"));
    const op = extractJsonStringField(json, "operation").?;
    try std.testing.expect(std.mem.eql(u8, op, "replace"));
}

test "applyBatchEdit - create single file" {
    const tmp_path = "/tmp/crushcode_test_batch_create.txt";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const json = "\\{\"edits\":[\\{\"file_path\":\"/tmp/crushcode_test_batch_create.txt\",\"operation\":\"create\",\"new_string\":\"hello batch\"}\\]}";
    const result = try applyBatchEdit(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(result.applied_edits == 1);
}
