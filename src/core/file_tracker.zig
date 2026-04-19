const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

pub const TrackedFile = struct {
    path: []const u8,
    content_hash: u64,
    size: u64,
    mtime: i128,
    read_count: u32,
    last_read_ts: i64,
    cached_content: ?[]const u8 = null,
};

pub const FileTracker = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(TrackedFile),
    total_cache_bytes: usize = 0,
    max_cache_bytes: usize = 512 * 1024,

    pub fn init(allocator: std.mem.Allocator) FileTracker {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(TrackedFile).init(allocator),
        };
    }

    pub fn deinit(self: *FileTracker) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.cached_content) |cached| {
                self.allocator.free(cached);
            }
        }
        self.files.deinit();
        self.* = undefined;
    }

    /// Track a file that was just read. Stores hash, size, mtime, and optionally caches content.
    /// If caching would exceed max_cache_bytes, evicts oldest entries first.
    pub fn track(self: *FileTracker, path: []const u8, content: []const u8, stat: std.fs.File.Stat) !void {
        const hash = std.hash.Fnv1a_64.hash(content);
        const now = std.time.milliTimestamp();

        // If already tracked, free old duped path and cached content
        if (self.files.getPtr(path)) |existing| {
            self.allocator.free(existing.path);
            if (existing.cached_content) |cached| {
                self.total_cache_bytes -= cached.len;
                self.allocator.free(cached);
            }
        }

        // Decide whether to cache content
        const should_cache = content.len <= self.max_cache_bytes;
        var cached_content: ?[]const u8 = null;
        if (should_cache) {
            // Evict until we have room
            while (self.total_cache_bytes + content.len > self.max_cache_bytes) {
                if (!self.evictOldest()) break;
            }
            if (self.total_cache_bytes + content.len <= self.max_cache_bytes) {
                cached_content = try self.allocator.dupe(u8, content);
                self.total_cache_bytes += cached_content.?.len;
            }
        }

        const duped_path = try self.allocator.dupe(u8, path);
        const entry = TrackedFile{
            .path = duped_path,
            .content_hash = hash,
            .size = stat.size,
            .mtime = stat.mtime,
            .read_count = 1,
            .last_read_ts = now,
            .cached_content = cached_content,
        };

        try self.files.put(duped_path, entry);
    }

    /// Check if a file has changed since last tracking.
    /// Returns true if the file is unchanged (same mtime and size).
    /// Returns false if file was never tracked or has changed.
    pub fn isUnchanged(self: *FileTracker, path: []const u8) bool {
        const tracked = self.files.get(path) orelse return false;

        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        const current_stat = file.stat() catch return false;

        // Quick check: if mtime and size match, consider unchanged
        if (current_stat.mtime == tracked.mtime and current_stat.size == tracked.size) {
            return true;
        }
        return false;
    }

    /// Get cached content for a file. Returns null if not cached or changed.
    pub fn getCached(self: *FileTracker, path: []const u8) ?[]const u8 {
        if (!self.isUnchanged(path)) return null;

        const tracked = self.files.getPtr(path) orelse return null;
        tracked.last_read_ts = std.time.milliTimestamp();
        tracked.read_count += 1;
        return tracked.cached_content;
    }

    /// Invalidate a specific file (e.g., after edit). Removes from tracking.
    pub fn invalidate(self: *FileTracker, path: []const u8) void {
        if (self.files.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            if (removed.value.cached_content) |cached| {
                self.total_cache_bytes -= cached.len;
                self.allocator.free(cached);
            }
            self.allocator.free(removed.value.path);
        }
    }

    /// Get number of tracked files
    pub fn trackedCount(self: *FileTracker) u32 {
        return @intCast(self.files.count());
    }

    /// Get total cache size in bytes
    pub fn cacheSize(self: *FileTracker) usize {
        return self.total_cache_bytes;
    }

    /// Evict the entry with the oldest last_read_ts. Returns false if no entries.
    fn evictOldest(self: *FileTracker) bool {
        var iter = self.files.iterator();
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = std.math.maxInt(i64);

        while (iter.next()) |entry| {
            if (entry.value_ptr.last_read_ts < oldest_ts) {
                oldest_ts = entry.value_ptr.last_read_ts;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            self.invalidate(key);
            return true;
        }
        return false;
    }
};
