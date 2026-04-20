/// File reference parser and resolver for @-file syntax in chat input.
/// Detects patterns like @src/main.zig, reads the file, and injects content
/// into the AI context.
const std = @import("std");

/// Maximum file size to read (1 MB)
const max_file_size: usize = 1024 * 1024;

/// A single resolved file reference
pub const FileReference = struct {
    path: []const u8, // The path as written by user — not owned, slice of original message
    resolved_path: []const u8, // Full resolved path (owned, allocator-freed)
    content: []const u8, // File content (owned, allocator-freed)
    found: bool, // Whether the file was found
    line_start: ?usize = null, // Optional line range start (for future :10-20 support)
    line_end: ?usize = null, // Optional line range end
};

/// Error info for a file that could not be resolved
pub const FileError = struct {
    path: []const u8, // Owned copy
    reason: []const u8, // Owned copy
};

/// Result of resolving all @-references in a message
pub const ResolveResult = struct {
    enhanced_message: []const u8, // User message with file contents appended (owned)
    resolved_files: []FileReference, // List of resolved files (owned array)
    errors: []FileError, // Files not found (owned array)

    /// Free all allocated memory
    pub fn deinit(self: *ResolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.enhanced_message);
        for (self.resolved_files) |ref| {
            allocator.free(ref.resolved_path);
            if (ref.found) {
                allocator.free(ref.content);
            }
        }
        allocator.free(self.resolved_files);
        for (self.errors) |err| {
            allocator.free(err.path);
            allocator.free(err.reason);
        }
        allocator.free(self.errors);
    }
};

/// Check if a byte is a valid path character for @-references
fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '-' or c == '_' or c == '~';
}

/// Check if a path contains at least one '/' or '.', to distinguish
/// file references from email addresses or @-mentions
fn hasPathSeparator(path: []const u8) bool {
    for (path) |c| {
        if (c == '/' or c == '.') return true;
    }
    return false;
}

/// A single parsed @-reference from user input
const ParsedRef = struct {
    at_sign_index: usize, // Position of '@' in the original message
    path: []const u8, // The path portion (after '@'), slice into original message
};

/// Parse all @-file references from user input.
/// Returns a slice of ParsedRef entries (caller frees with allocator.free).
fn parseRefs(allocator: std.mem.Allocator, message: []const u8) ![]ParsedRef {
    var refs = try std.ArrayList(ParsedRef).initCapacity(allocator, 4);
    defer refs.deinit(allocator);

    var i: usize = 0;
    while (i < message.len) {
        if (message[i] != '@') {
            i += 1;
            continue;
        }

        // Skip if preceded by an alphanumeric character (part of email or word)
        if (i > 0 and std.ascii.isAlphanumeric(message[i - 1])) {
            i += 1;
            continue;
        }

        // Collect path characters after '@'
        const path_start = i + 1;
        var path_end = path_start;
        while (path_end < message.len and isPathChar(message[path_end])) {
            path_end += 1;
        }

        const path = message[path_start..path_end];

        // Path must be non-empty and contain at least one '/' or '.'
        if (path.len == 0 or !hasPathSeparator(path)) {
            i = path_end;
            continue;
        }

        try refs.append(allocator, .{
            .at_sign_index = i,
            .path = path,
        });
        i = path_end;
    }

    return refs.toOwnedSlice(allocator);
}

/// Resolve a single file path. Returns a FileReference.
/// On failure, resolved_path is still allocated (caller must free on non-found results too).
fn resolveFile(allocator: std.mem.Allocator, raw_path: []const u8) FileReference {
    // Resolve home directory
    var resolved: []const u8 = undefined;
    var needs_free = false;

    if (raw_path.len >= 2 and raw_path[0] == '~' and raw_path[1] == '/') {
        // Resolve ~/ to $HOME
        const home = std.posix.getenv("HOME") orelse {
            const resolved_copy = allocator.dupe(u8, raw_path) catch return .{
                .path = raw_path,
                .resolved_path = raw_path,
                .content = "",
                .found = false,
            };
            return .{
                .path = raw_path,
                .resolved_path = resolved_copy,
                .content = "",
                .found = false,
            };
        };
        const rest = raw_path[2..];
        const full = std.fs.path.join(allocator, &.{ home, rest }) catch return .{
            .path = raw_path,
            .resolved_path = allocator.dupe(u8, raw_path) catch raw_path,
            .content = "",
            .found = false,
        };
        resolved = full;
        needs_free = true;
    } else {
        resolved = raw_path;
        needs_free = false;
    }

    // Try to read the file
    const file_content = std.fs.cwd().readFileAlloc(allocator, resolved, max_file_size) catch {
        // File not found or unreadable
        const path_copy = allocator.dupe(u8, resolved) catch return .{
            .path = raw_path,
            .resolved_path = if (needs_free) resolved else raw_path,
            .content = "",
            .found = false,
        };
        if (needs_free) allocator.free(resolved);
        return .{
            .path = raw_path,
            .resolved_path = path_copy,
            .content = "",
            .found = false,
        };
    };

    if (needs_free) {
        // resolved was allocated for home expansion — make a persistent copy
        const path_copy = allocator.dupe(u8, resolved) catch {
            allocator.free(file_content);
            allocator.free(resolved);
            return .{
                .path = raw_path,
                .resolved_path = raw_path,
                .content = "",
                .found = false,
            };
        };
        allocator.free(resolved);
        return .{
            .path = raw_path,
            .resolved_path = path_copy,
            .content = file_content,
            .found = true,
        };
    } else {
        // resolved points into raw_path, need to dupe it for ownership
        const path_copy = allocator.dupe(u8, resolved) catch {
            allocator.free(file_content);
            return .{
                .path = raw_path,
                .resolved_path = raw_path,
                .content = "",
                .found = false,
            };
        };
        return .{
            .path = raw_path,
            .resolved_path = path_copy,
            .content = file_content,
            .found = true,
        };
    }
}

/// Helper to append a string to an ArrayList(u8)
fn appendStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

/// Resolve all @-file references in a user message.
/// Returns a ResolveResult containing the enhanced message with file contents,
/// a list of resolved files, and any errors.
pub fn resolve(allocator: std.mem.Allocator, user_message: []const u8) !ResolveResult {
    const refs = try parseRefs(allocator, user_message);
    defer allocator.free(refs);

    // If no references found, return a simple copy
    if (refs.len == 0) {
        const msg_copy = try allocator.dupe(u8, user_message);
        return ResolveResult{
            .enhanced_message = msg_copy,
            .resolved_files = &.{},
            .errors = &.{},
        };
    }

    // Resolve each file
    var resolved_files = try std.ArrayList(FileReference).initCapacity(allocator, refs.len);
    errdefer {
        for (resolved_files.items) |ref| {
            allocator.free(ref.resolved_path);
            if (ref.found) allocator.free(ref.content);
        }
        resolved_files.deinit(allocator);
    }

    var file_errors = try std.ArrayList(FileError).initCapacity(allocator, refs.len);
    errdefer {
        for (file_errors.items) |err| {
            allocator.free(err.path);
            allocator.free(err.reason);
        }
        file_errors.deinit(allocator);
    }

    for (refs) |ref| {
        const file_ref = resolveFile(allocator, ref.path);
        if (file_ref.found) {
            try resolved_files.append(allocator, file_ref);
        } else {
            // Create an owned copy of the path for the error
            const path_copy = try allocator.dupe(u8, ref.path);
            const reason = try std.fmt.allocPrint(allocator, "File not found: {s}", .{ref.path});
            // Free the resolved_path from the failed resolveFile call
            allocator.free(file_ref.resolved_path);
            try file_errors.append(allocator, .{
                .path = path_copy,
                .reason = reason,
            });
        }
    }

    // Build the enhanced message
    var buf = try std.ArrayList(u8).initCapacity(allocator, user_message.len + 256);
    errdefer buf.deinit(allocator);

    // Start with original message
    try appendStr(&buf, allocator, user_message);

    // Append each resolved file
    for (resolved_files.items) |file_ref| {
        try appendStr(&buf, allocator, "\n\n--- File: ");
        try appendStr(&buf, allocator, file_ref.path);
        try appendStr(&buf, allocator, " ---\n");
        try appendStr(&buf, allocator, file_ref.content);
        try appendStr(&buf, allocator, "\n--- End of ");
        try appendStr(&buf, allocator, file_ref.path);
        try appendStr(&buf, allocator, " ---");
    }

    // Append error notes
    for (file_errors.items) |err_info| {
        try appendStr(&buf, allocator, "\n\n--- File: ");
        try appendStr(&buf, allocator, err_info.path);
        try appendStr(&buf, allocator, " ---\n[File not found: ");
        try appendStr(&buf, allocator, err_info.path);
        try appendStr(&buf, allocator, "]\n--- End of ");
        try appendStr(&buf, allocator, err_info.path);
        try appendStr(&buf, allocator, " ---");
    }

    const enhanced = try buf.toOwnedSlice(allocator);
    const owned_files = try resolved_files.toOwnedSlice(allocator);
    errdefer {
        for (owned_files) |ref| {
            allocator.free(ref.resolved_path);
            if (ref.found) allocator.free(ref.content);
        }
        allocator.free(owned_files);
    }
    const owned_errors = try file_errors.toOwnedSlice(allocator);
    errdefer {
        for (owned_errors) |err| {
            allocator.free(err.path);
            allocator.free(err.reason);
        }
        allocator.free(owned_errors);
    }

    return ResolveResult{
        .enhanced_message = enhanced,
        .resolved_files = owned_files,
        .errors = owned_errors,
    };
}
