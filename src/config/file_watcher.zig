//! Context file watcher — polls loaded context files (CLAUDE.md, AGENTS.md, etc.)
//! for changes and triggers reload when mtime changes.
//!
//! Uses simple polling (no inotify/kqueue) for cross-platform compatibility.
//! Called once per draw frame from the TUI event loop.

const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A watched file with its last-known modification time.
const WatchedFile = struct {
    path: []const u8,
    last_mtime: i128, // nanosecond timestamp from stat()

    pub fn deinit(self: *WatchedFile, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

/// File watcher that tracks a set of files for changes.
pub const FileWatcher = struct {
    allocator: Allocator,
    files: array_list_compat.ArrayList(WatchedFile),
    changed_paths: array_list_compat.ArrayList([]const u8),

    pub fn init(allocator: Allocator) FileWatcher {
        return .{
            .allocator = allocator,
            .files = array_list_compat.ArrayList(WatchedFile).init(allocator),
            .changed_paths = array_list_compat.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        for (self.files.items) |*f| f.deinit(self.allocator);
        self.files.deinit();
        self.freeChanged();
        self.changed_paths.deinit();
    }

    /// Add a file to watch. Records current mtime.
    pub fn addFile(self: *FileWatcher, path: []const u8) void {
        // Skip if already watching
        for (self.files.items) |f| {
            if (std.mem.eql(u8, f.path, path)) return;
        }

        const mtime = getFileMtime(path) catch 0;
        const owned_path = self.allocator.dupe(u8, path) catch return;
        self.files.append(.{ .path = owned_path, .last_mtime = mtime }) catch {
            self.allocator.free(owned_path);
        };
    }

    /// Poll all watched files. Returns paths that changed since last poll.
    /// Caller must call freeChanged() after processing results.
    pub fn poll(self: *FileWatcher) []const []const u8 {
        self.freeChanged();

        for (self.files.items) |*f| {
            const current_mtime = getFileMtime(f.path) catch continue;
            if (current_mtime != f.last_mtime and f.last_mtime != 0) {
                // File changed
                const path_copy = self.allocator.dupe(u8, f.path) catch continue;
                self.changed_paths.append(path_copy) catch {
                    self.allocator.free(path_copy);
                    continue;
                };
            }
            f.last_mtime = current_mtime;
        }

        return self.changed_paths.items;
    }

    /// Free the changed paths list from last poll.
    pub fn freeChanged(self: *FileWatcher) void {
        for (self.changed_paths.items) |p| self.allocator.free(p);
        self.changed_paths.clearRetainingCapacity();
    }

    /// Get the number of watched files.
    pub fn count(self: *const FileWatcher) usize {
        return self.files.items.len;
    }
};

/// Get file modification time as nanosecond timestamp.
fn getFileMtime(path: []const u8) !i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const stat = file.stat() catch return error.StatFailed;
    return stat.mtime;
}
