const std = @import("std");
const array_list_compat = @import("array_list_compat");
const fs = std.fs;

pub const FileOperationResult = struct {
    success: bool,
    files_written: usize,
    errors: []const u8,
};

/// Write content to a file
pub fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Write content to multiple files (for glob patterns)
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

/// Append content to a file
pub fn appendFile(path: []const u8, content: []const u8) !void {
    const file = try fs.cwd().openFile(path, .{
        .mode = .read_write,
    });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

/// Create directory if it doesn't exist
pub fn ensureDir(path: []const u8) !void {
    try fs.cwd().makeDir(path);
}

/// Check if file exists
pub fn fileExists(path: []const u8) bool {
    const file = fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Handle write command from CLI
pub fn handleWrite(args: [][]const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: crushcode write <path> <content>\n", .{});
        std.debug.print("       crushcode write <path> --content <content>\n", .{});
        std.debug.print("       crushcode write \"*.txt\" --content <content>\n", .{});
        return;
    }

    var path: ?[]const u8 = null;
    var content: ?[]const u8 = null;
    var glob_pattern: ?[]const u8 = null;

    // Parse arguments
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
            // First non-flag argument is the path
            path = args[i];
            // Check if it's a glob pattern
            if (std.mem.indexOf(u8, args[i], "*") != null) {
                glob_pattern = args[i];
            }
        } else if (content == null) {
            // Second non-flag argument is the content
            content = args[i];
        }
    }

    // Handle glob pattern
    if (path) |p| {
        // Check if path contains glob pattern
        const is_glob = std.mem.indexOf(u8, p, "*") != null;

        // Need content for both single file and glob
        if (content == null) {
            std.debug.print("Error: No content specified\n", .{});
            return;
        }

        if (is_glob) {
            std.debug.print("Glob pattern: {s}\n", .{p});
            // Basic glob implementation - write to all files matching extension
            const wildcard_pos = std.mem.lastIndexOfScalar(u8, p, '*') orelse {
                std.debug.print("Error: Pattern must contain wildcard (*)\n", .{});
                return;
            };
            const extension = p[wildcard_pos + 1 ..];

            var files_written: usize = 0;
            var dir = fs.cwd().openDir(".", .{}) catch |err| {
                std.debug.print("Error opening directory: {}\n", .{err});
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
                std.debug.print("Written to {d} file(s) matching {s}\n", .{ files_written, extension });
            } else {
                std.debug.print("No files found matching {s}\n", .{extension});
            }
        } else {
            // Single file
            try writeFile(p, content.?);
            std.debug.print("Written to: {s}\n", .{p});
        }
    }
}

/// Handle edit command - read file, let user edit, write back
pub fn handleEdit(args: [][]const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: crushcode edit <file> [--create]\n", .{});
        return;
    }

    const path = args[0];
    const create = if (args.len > 1 and std.mem.eql(u8, args[1], "--create")) true else false;

    if (!create and !fileExists(path)) {
        std.debug.print("Error: File does not exist: {s}\n", .{path});
        std.debug.print("Use --create to create a new file\n", .{});
        return;
    }

    // For now, just print the file path - full edit would need editor integration
    std.debug.print("Edit file: {s}\n", .{path});
    std.debug.print("(Full editor integration coming soon)\n", .{});
}
