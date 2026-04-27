//! Repository map generator — produces a compact directory tree summary
//! for injection into AI system prompts (aider-style repo map).
//!
//! Walks the project tree (max depth 4), skips noise dirs, sorts entries,
//! and formats a concise text representation suitable for LLM context.

const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Result of repo map generation.
pub const RepoMapResult = struct {
    map_text: []const u8,
    file_count: u32,
    dir_count: u32,

    pub fn deinit(self: *const RepoMapResult, allocator: Allocator) void {
        if (self.map_text.len > 0) allocator.free(self.map_text);
    }
};

/// Directories to skip entirely (case-sensitive, basename match).
const skip_dirs = &[_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "zig-out",
    "zig-cache",
    ".cache",
    "target",
    "__pycache__",
    ".venv",
    "venv",
    ".env",
    "dist",
    "build",
    ".next",
    ".nuxt",
    "vendor",
    "Pods",
    ".dart_tool",
    ".gradle",
    ".idea",
    ".vscode",
    "coverage",
    ".tox",
    "site-packages",
    "bower_components",
    ".terraform",
    ".cargo",
    ".rustup",
};

/// File extensions to skip (binary/noise).
const skip_exts = &[_][]const u8{
    ".o",
    ".so",
    ".dll",
    ".exe",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".ico",
    ".woff",
    ".woff2",
    ".ttf",
    ".eot",
    ".zip",
    ".tar",
    ".gz",
    ".bz2",
    ".xz",
    ".7z",
    ".rar",
    ".pyc",
    ".pyo",
    ".class",
    ".jar",
    ".war",
    ".db",
    ".sqlite",
    ".lock",
    ".wasm",
    ".min.js",
    ".min.css",
    ".map",
};

const max_files_per_dir: u32 = 8;
const max_show_per_dir: u32 = 6;

/// Check if a directory basename should be skipped.
fn shouldSkipDir(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') return true; // hidden dirs
    for (skip_dirs) |sd| {
        if (std.mem.eql(u8, name, sd)) return true;
    }
    return false;
}

/// Check if a file extension should be skipped.
fn shouldSkipFile(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') return true; // hidden files
    for (skip_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// A single directory's collected file names.
const DirEntry = struct {
    rel_path: []const u8,
    files: array_list_compat.ArrayList([]const u8),

    fn deinit(self: *DirEntry, allocator: Allocator) void {
        for (self.files.items) |f| allocator.free(f);
        self.files.deinit();
    }
};

/// Generate a compact repository map string.
/// Caller owns the returned slice.
pub fn generate(allocator: Allocator, max_entries: u32) ![]const u8 {
    const result = try generateWithStats(allocator, max_entries);
    return result.map_text;
}

/// Generate a repository map with statistics.
pub fn generateWithStats(allocator: Allocator, max_entries: u32) !RepoMapResult {
    var dirs = array_list_compat.ArrayList(DirEntry).init(allocator);
    defer {
        for (dirs.items) |*d| d.deinit(allocator);
        dirs.deinit();
    }

    var total_files: u32 = 0;
    var entries_used: u32 = 0;

    // Walk the directory tree using recursive BFS
    try walkDir(allocator, &dirs, ".", 0, 4, max_entries, &total_files, &entries_used);

    if (dirs.items.len == 0 or total_files < 3) {
        return RepoMapResult{
            .map_text = try allocator.dupe(u8, ""),
            .file_count = total_files,
            .dir_count = 0,
        };
    }

    // Sort directories by path
    std.sort.insertion(DirEntry, dirs.items, {}, cmpDirByPath);

    // Format output
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    const w = buf.writer();

    for (dirs.items) |dir| {
        // Sort files alphabetically
        std.sort.insertion([]const u8, dir.files.items, {}, cmpStrings);

        // Print directory path
        if (std.mem.eql(u8, dir.rel_path, ".")) {
            w.print(".\n", .{}) catch {};
        } else {
            w.print("{s}/\n", .{dir.rel_path}) catch {};
        }

        // Print files (compact list)
        if (dir.files.items.len > 0) {
            const show_count = @min(dir.files.items.len, max_show_per_dir);
            w.print("  ", .{}) catch {};
            for (dir.files.items[0..show_count], 0..) |f, i| {
                if (i > 0) w.print(", ", .{}) catch {};
                w.print("{s}", .{f}) catch {};
            }
            if (dir.files.items.len > max_files_per_dir) {
                const remaining = dir.files.items.len - max_show_per_dir;
                w.print(", +{d} more", .{remaining}) catch {};
            }
            w.print("\n", .{}) catch {};
        }
    }

    const dir_count: u32 = @intCast(dirs.items.len);
    return RepoMapResult{
        .map_text = try buf.toOwnedSlice(),
        .file_count = total_files,
        .dir_count = dir_count,
    };
}

/// Recursively walk a directory, collecting file entries.
fn walkDir(
    allocator: Allocator,
    dirs: *array_list_compat.ArrayList(DirEntry),
    path: []const u8,
    depth: u32,
    max_depth: u32,
    max_entries: u32,
    total_files: *u32,
    entries_used: *u32,
) !void {
    if (depth > max_depth) return;
    if (entries_used.* >= max_entries) return;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var dir_entry = DirEntry{
        .rel_path = try allocator.dupe(u8, path),
        .files = array_list_compat.ArrayList([]const u8).init(allocator),
    };
    errdefer {
        allocator.free(dir_entry.rel_path);
        dir_entry.files.deinit();
    }

    // Collect subdirs and files
    var subdirs = array_list_compat.ArrayList([]const u8).init(allocator);
    defer {
        for (subdirs.items) |s| allocator.free(s);
        subdirs.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entries_used.* >= max_entries) break;

        switch (entry.kind) {
            .file => {
                if (!shouldSkipFile(entry.name)) {
                    try dir_entry.files.append(try allocator.dupe(u8, entry.name));
                    total_files.* += 1;
                    entries_used.* += 1;
                }
            },
            .directory => {
                if (!shouldSkipDir(entry.name)) {
                    const subpath = if (std.mem.eql(u8, path, "."))
                        try allocator.dupe(u8, entry.name)
                    else
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                    try subdirs.append(subpath);
                }
            },
            else => {},
        }
    }

    // Only add directory if it has files or we're at root
    if (dir_entry.files.items.len > 0 or std.mem.eql(u8, path, ".")) {
        try dirs.append(dir_entry);
    } else {
        allocator.free(dir_entry.rel_path);
        dir_entry.files.deinit();
    }

    // Sort subdirs for deterministic traversal order
    std.sort.insertion([]const u8, subdirs.items, {}, cmpStrings);

    // Recurse into subdirs
    for (subdirs.items) |sub| {
        walkDir(allocator, dirs, sub, depth + 1, max_depth, max_entries, total_files, entries_used) catch {};
    }
}

fn cmpDirByPath(_: void, a: DirEntry, b: DirEntry) bool {
    return std.mem.lessThan(u8, a.rel_path, b.rel_path);
}

fn cmpStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
