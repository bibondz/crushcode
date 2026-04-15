const std = @import("std");
const hashline = @import("hashline");
const hash_index = @import("hash_index");
const validated_edit = @import("validated_edit");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const fs = std.fs;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub const FileOperationResult = struct {
    success: bool,
    files_written: usize,
    errors: []const u8,
};

pub fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);

    const allocator = std.heap.page_allocator;
    const hashlines = hashline.formatFileWithHashlines(allocator, content) catch return;
    defer allocator.free(hashlines);
    const hashlines_path = std.fmt.allocPrint(allocator, "{s}.hashlines", .{path}) catch return;
    defer allocator.free(hashlines_path);
    const hashlines_file = fs.cwd().createFile(hashlines_path, .{}) catch return;
    hashlines_file.writeAll(hashlines) catch {};
    hashlines_file.close();
}

pub fn writeFileValidated(path: []const u8, content: []const u8, hashlines_content: ?[]const u8) !void {
    if (hashlines_content) |hc| {
        const allocator = std.heap.page_allocator;
        const current_file = fs.cwd().openFile(path, .{ .read = true }) catch return;
        defer current_file.close();
        const file_size = current_file.getEndPos() catch return;
        if (file_size == 0) return;
        const current_content = try allocator.alloc(u8, file_size);
        defer allocator.free(current_content);
        try current_file.readAll(current_content);

        var file_lines = std.ArrayList([]const u8).init(allocator);
        defer file_lines.deinit();
        var line_iter = std.mem.splitScalar(u8, current_content, '\n');
        while (line_iter.next()) |line| {
            try file_lines.append(line);
        }

        var valid = true;
        var hl_lines = std.mem.splitScalar(u8, hc, '\n');
        while (hl_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const pipe_sep = std.mem.indexOf(u8, trimmed, " | ") orelse continue;
            const hashline_str = std.mem.trim(u8, trimmed[0..pipe_sep], " ");
            const parsed = hashline.Hashline.parse(hashline_str) catch continue;

            if (parsed.line_number == 0 or parsed.line_number > file_lines.items.len) continue;
            const actual_line = file_lines.items[parsed.line_number - 1];
            if (!parsed.validate(actual_line)) {
                valid = false;
                out("Warning: Stale hashline at line {d} in {s}\n", .{ parsed.line_number, path });
            }
        }
        if (!valid) return error.StaleReference;
    }

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn writeFileWithValidation(path: []const u8, content: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const hashlines_path = std.fmt.allocPrint(allocator, "{s}.hashlines", .{path}) catch return;
    defer allocator.free(hashlines_path);

    var hashlines_content: ?[]const u8 = null;
    if (fs.cwd().openFile(hashlines_path, .{ .read = true })) |file| {
        defer file.close();
        const file_size = file.getEndPos() catch 0;
        if (file_size > 0) {
            const buffer = try allocator.alloc(u8, file_size);
            defer allocator.free(buffer);
            _ = file.readAll(buffer) catch 0;
            hashlines_content = buffer;
        }
    } else |_| {}

    try writeFileValidated(path, content, hashlines_content);
}

pub fn handleEditValidated(path: []const u8, old_content: []const u8, new_content: []const u8) !void {
    _ = old_content;
    try writeFileWithValidation(path, new_content);
}

pub fn writeFiles(paths: []const []const u8, content: []const u8) FileOperationResult {
    var errors_buf = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    defer errors_buf.deinit();

    var files_written: usize = 0;

    for (paths) |path| {
        writeFile(path, content) catch |err| {
            errors_buf.appendSlice("Failed to write ") catch {};
            errors_buf.appendSlice(path) catch {};
            errors_buf.appendSlice(": ") catch {};
            errors_buf.appendSlice(@errorName(err)) catch {};
            errors_buf.append('\n') catch {};
            continue;
        };
        files_written += 1;
    }

    return FileOperationResult{
        .success = files_written > 0,
        .files_written = files_written,
        .errors = if (errors_buf.items.len > 0) errors_buf.items else "",
    };
}

pub fn appendFile(path: []const u8, content: []const u8) !void {
    const file = try fs.cwd().openFile(path, .{
        .mode = .read_write,
    });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

pub fn ensureDir(path: []const u8) !void {
    try fs.cwd().makeDir(path);
}

pub fn fileExists(path: []const u8) bool {
    const file = fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

pub fn handleWrite(args: [][]const u8) !void {
    if (args.len < 2) {
        out("Usage: crushcode write <path> <content>\n", .{});
        out("       crushcode write <path> --content <content>\n", .{});
        out("       crushcode write \"*.txt\" --content <content>\n", .{});
        return;
    }

    var path: ?[]const u8 = null;
    var content: ?[]const u8 = null;
    var glob_pattern: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--content") or std.mem.eql(u8, args[i], "-c")) {
            if (i + 1 < args.len) {
                content = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--path") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                path = args[i + 1];
                i += 1;
            }
        } else if (path == null) {
            path = args[i];
            if (std.mem.indexOf(u8, args[i], "*") != null) {
                glob_pattern = args[i];
            }
        } else if (content == null) {
            content = args[i];
        }
    }

    if (path) |p| {
        const is_glob = std.mem.indexOf(u8, p, "*") != null;

        if (content == null) {
            out("Error: No content specified\n", .{});
            return;
        }

        if (is_glob) {
            out("Glob pattern: {s}\n", .{p});
            const wildcard_pos = std.mem.lastIndexOfScalar(u8, p, '*') orelse {
                out("Error: Pattern must contain wildcard (*)\n", .{});
                return;
            };
            const extension = p[wildcard_pos + 1 ..];

            var files_written: usize = 0;
            var dir = fs.cwd().openDir(".", .{}) catch |err| {
                out("Error opening directory: {}\n", .{err});
                return;
            };
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.endsWith(u8, entry.name, extension)) {
                    try writeFile(entry.name, content.?);
                    files_written += 1;
                }
            }

            if (files_written > 0) {
                out("Written to {d} file(s) matching {s}\n", .{ files_written, extension });
            } else {
                out("No files found matching {s}\n", .{extension});
            }
        } else {
            try writeFile(p, content.?);
            out("Written to: {s}\n", .{p});
        }
    }
}

pub fn handleEdit(args: [][]const u8) !void {
    if (args.len < 1) {
        out("Usage: crushcode edit <file> [--create]\n", .{});
        return;
    }

    const path = args[0];
    const create = if (args.len > 1 and std.mem.eql(u8, args[1], "--create")) true else false;

    if (!create and !fileExists(path)) {
        out("Error: File does not exist: {s}\n", .{path});
        out("Use --create to create a new file\n", .{});
        return;
    }

    out("Edit file: {s}\n", .{path});
    out("(Full editor integration coming soon)\n", .{});
}
