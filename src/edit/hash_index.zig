const std = @import("std");
const array_list_compat = @import("array_list_compat");
const hashline_mod = @import("hashline.zig");

const Allocator = std.mem.Allocator;
const Hashline = hashline_mod.Hashline;

/// A single entry in the hash index
pub const HashlineEntry = struct {
    line_number: u32,
    content_hash: u32,
    content_offset: usize, // Byte offset in original content
    content_len: usize, // Length of original line content
};

/// Result of validating a line against the hash index
pub const ValidationResult = union(enum) {
    valid,
    stale_line: StaleLineInfo,
    line_not_found,
    index_empty,
};

/// Information about a stale (modified) line
pub const StaleLineInfo = struct {
    line_number: u32,
    expected_hash: u32,
    actual_hash: u32,
};

/// Per-file hash index for fast line validation
pub const HashIndex = struct {
    allocator: Allocator,
    file_path: []const u8,
    entries: array_list_compat.ArrayList(HashlineEntry),
    file_hash: u32, // FNV-1a hash of entire file for quick staleness check
    line_count: u32,

    pub fn init(allocator: Allocator, file_path: []const u8) HashIndex {
        return HashIndex{
            .allocator = allocator,
            .file_path = file_path,
            .entries = array_list_compat.ArrayList(HashlineEntry).init(allocator),
            .file_hash = 0,
            .line_count = 0,
        };
    }

    /// Build a hash index from file content
    pub fn buildFromContent(self: *HashIndex, content: []const u8) !void {
        self.entries.clearRetainingCapacity();

        // Hash the entire file for quick staleness check
        self.file_hash = Hashline.hash(content);

        var offset: usize = 0;
        var line_num: u32 = 1;

        while (offset < content.len) {
            // Find end of this line
            const line_end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
            const line_content = content[offset..line_end];

            // Generate hash for this line
            const hl = Hashline.hashLine(line_num, line_content);

            try self.entries.append(HashlineEntry{
                .line_number = hl.line_number,
                .content_hash = hl.content_hash,
                .content_offset = offset,
                .content_len = line_content.len,
            });

            offset = line_end + 1;
            line_num += 1;
        }

        self.line_count = line_num - 1;
    }

    /// Validate a specific line against its expected hash
    pub fn validateLine(self: *HashIndex, line_number: u32, expected_hash: u32, current_content: []const u8) ValidationResult {
        if (self.entries.items.len == 0) return .index_empty;

        // Find the entry for this line
        const entry = self.findEntry(line_number) orelse return .line_not_found;

        // Check if the whole file hash still matches (quick check)
        const current_file_hash = Hashline.hash(current_content);
        if (current_file_hash == self.file_hash) {
            // File unchanged — guaranteed valid
            if (entry.content_hash == expected_hash) {
                return .valid;
            }
            return .stale_line;
        }

        // File changed — check specific line
        const actual = self.getLineContent(line_number, current_content) orelse return .line_not_found;
        const actual_hash = Hashline.hash(actual);

        if (actual_hash == expected_hash) {
            return .valid;
        }
        return .stale_line;
    }

    /// Get the hash for a specific line number
    pub fn getHash(self: *HashIndex, line_number: u32) ?u32 {
        const entry = self.findEntry(line_number) orelse return null;
        return entry.content_hash;
    }

    /// Get line content from current file content by line number
    pub fn getLineContent(self: *HashIndex, line_number: u32, content: []const u8) ?[]const u8 {
        _ = self;
        if (line_number == 0) return null;

        var offset: usize = 0;
        var current_line: u32 = 1;

        while (offset < content.len and current_line < line_number) {
            const end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
            offset = end + 1;
            current_line += 1;
        }

        if (offset >= content.len) return null;

        const line_end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
        return content[offset..line_end];
    }

    /// Check if the index is stale (file has changed)
    pub fn isStale(self: *HashIndex, current_content: []const u8) bool {
        return Hashline.hash(current_content) != self.file_hash;
    }

    /// Find a hashline entry by line number (linear search, fine for typical file sizes)
    fn findEntry(self: *HashIndex, line_number: u32) ?HashlineEntry {
        if (line_number == 0 or line_number > self.entries.items.len) return null;
        // Line numbers are 1-based, entries are 0-based
        return self.entries.items[line_number - 1];
    }

    pub fn deinit(self: *HashIndex) void {
        self.entries.deinit();
    }
};

/// Global hash index cache for multiple files
pub const HashCache = struct {
    allocator: Allocator,
    cache: std.StringHashMap(HashIndex),
    max_entries: usize,

    pub fn init(allocator: Allocator, max_entries: usize) HashCache {
        return HashCache{
            .allocator = allocator,
            .cache = std.StringHashMap(HashIndex).init(allocator),
            .max_entries = max_entries,
        };
    }

    /// Get or build a hash index for a file
    pub fn getIndex(self: *HashCache, file_path: []const u8, content: []const u8) !*HashIndex {
        // Check cache
        if (self.cache.getPtr(file_path)) |existing| {
            // Check if still valid
            if (!existing.isStale(content)) {
                return existing;
            }
            // Stale — rebuild
            existing.buildFromContent(content) catch |err| {
                std.log.warn("HashCache: failed to rebuild stale index for '{s}': {}", .{ file_path, err });
                return existing;
            };
            return existing;
        }

        // Evict oldest if at capacity
        if (self.cache.count() >= self.max_entries) {
            var iter = self.cache.keyIterator();
            if (iter.next()) |oldest_key| {
                const key_copy = oldest_key.*;
                if (self.cache.getPtr(key_copy)) |old_idx| {
                    old_idx.deinit();
                }
                _ = self.cache.remove(key_copy);
                self.allocator.free(key_copy);
            }
        }

        // Build new index
        const path_copy = try self.allocator.dupe(u8, file_path);
        var index = HashIndex.init(self.allocator, path_copy);
        try index.buildFromContent(content);
        try self.cache.put(path_copy, index);

        return self.cache.getPtr(file_path).?;
    }

    /// Invalidate a specific file's cache entry
    pub fn invalidate(self: *HashCache, file_path: []const u8) void {
        if (self.cache.fetchPtr(file_path)) |entry| {
            entry.deinit();
            _ = self.cache.remove(file_path);
        }
    }

    pub fn deinit(self: *HashCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();
    }
};
