const std = @import("std");
const array_list_compat = @import("array_list_compat");

const ArrayList = array_list_compat.ArrayList;

/// LRU cache entry linking a hash key to its token count.
const Entry = struct {
    key: u64,
    value: u32,
    prev: ?usize,
    next: ?usize,
};

/// LRU cache statistics for diagnostics.
pub const CacheStats = struct {
    hits: u64,
    misses: u64,
};

/// Token estimation LRU cache using xxHash64 keys.
/// Avoids re-estimating token counts for previously seen text.
pub const TokenCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, usize),
    entries: ArrayList(Entry),
    head: ?usize,
    tail: ?usize,
    max_entries: u32,
    hits: u64,
    misses: u64,

    /// Initialize a new TokenCache with the given allocator and capacity.
    pub fn init(allocator: std.mem.Allocator, max_entries: u32) TokenCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u64, usize).init(allocator),
            .entries = ArrayList(Entry).init(allocator),
            .head = null,
            .tail = null,
            .max_entries = max_entries,
            .hits = 0,
            .misses = 0,
        };
    }

    /// Release all allocated memory.
    pub fn deinit(self: *TokenCache) void {
        self.map.deinit();
        self.entries.deinit();
    }

    /// Remove all entries and reset statistics.
    pub fn clear(self: *TokenCache) void {
        self.map.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.hits = 0;
        self.misses = 0;
    }

    /// Return cache hit/miss statistics.
    pub fn stats(self: *const TokenCache) CacheStats {
        return .{ .hits = self.hits, .misses = self.misses };
    }

    /// Get cached token count or compute via len/4 heuristic and store.
    pub fn getOrEstimate(self: *TokenCache, text: []const u8) u32 {
        const key = std.hash.XxHash64.hash(0, text);
        if (self.map.get(key)) |idx| {
            self.hits += 1;
            self.moveToFront(idx);
            return self.entries.items[idx].value;
        }

        self.misses += 1;
        const estimate: u32 = @intCast(text.len / 4);
        self.insert(key, estimate);
        return estimate;
    }

    fn insert(self: *TokenCache, key: u64, value: u32) void {
        if (self.entries.items.len >= self.max_entries) {
            self.evictTail();
        }

        const idx = self.entries.items.len;
        self.entries.append(.{
            .key = key,
            .value = value,
            .prev = null,
            .next = self.head,
        }) catch return;

        if (self.head) |h| {
            self.entries.items[h].prev = idx;
        }
        self.head = idx;
        if (self.tail == null) {
            self.tail = idx;
        }
        self.map.put(key, idx) catch {};
    }

    fn evictTail(self: *TokenCache) void {
        const tail_idx = self.tail orelse return;
        const tail_key = self.entries.items[tail_idx].key;
        _ = self.map.remove(tail_key);

        const prev_idx = self.entries.items[tail_idx].prev;
        if (prev_idx) |pi| {
            self.entries.items[pi].next = null;
            self.tail = pi;
        } else {
            self.head = null;
            self.tail = null;
        }
        _ = self.entries.pop();
    }

    fn moveToFront(self: *TokenCache, idx: usize) void {
        if (self.head == idx) return;

        const entry = &self.entries.items[idx];
        if (entry.prev) |p| {
            self.entries.items[p].next = entry.next;
        }
        if (entry.next) |n| {
            self.entries.items[n].prev = entry.prev;
        }
        if (self.tail == idx) {
            self.tail = entry.prev;
        }

        entry.prev = null;
        entry.next = self.head;
        if (self.head) |h| {
            self.entries.items[h].prev = idx;
        }
        self.head = idx;
    }
};

test "init and deinit" {
    var cache = TokenCache.init(std.testing.allocator, 1024);
    defer cache.deinit();

    const s = cache.stats();
    try std.testing.expectEqual(@as(u64, 0), s.hits);
    try std.testing.expectEqual(@as(u64, 0), s.misses);
}

test "cache hit returns same value" {
    var cache = TokenCache.init(std.testing.allocator, 1024);
    defer cache.deinit();

    const text = "hello world test string";
    const first = cache.getOrEstimate(text);
    const second = cache.getOrEstimate(text);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().misses);
}

test "cache miss computes estimate" {
    var cache = TokenCache.init(std.testing.allocator, 1024);
    defer cache.deinit();

    const result = cache.getOrEstimate("a sixteen byte str");
    try std.testing.expectEqual(@as(u32, 4), result);
    try std.testing.expectEqual(@as(u64, 0), cache.stats().hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().misses);
}

test "eviction removes oldest entry" {
    var cache = TokenCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    _ = cache.getOrEstimate("first entry here!!");
    _ = cache.getOrEstimate("second entry here");
    _ = cache.getOrEstimate("third entry here!");

    const s = cache.stats();
    try std.testing.expectEqual(@as(u64, 0), s.hits);
    try std.testing.expectEqual(@as(u64, 3), s.misses);

    _ = cache.getOrEstimate("first entry here!!");
    try std.testing.expectEqual(@as(u64, 0), cache.stats().hits);
    _ = cache.getOrEstimate("second entry here");
    try std.testing.expectEqual(@as(u64, 0), cache.stats().hits);

    _ = cache.getOrEstimate("third entry here!");
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
}

test "clear resets state" {
    var cache = TokenCache.init(std.testing.allocator, 1024);
    defer cache.deinit();

    _ = cache.getOrEstimate("some text");
    _ = cache.getOrEstimate("some text");
    cache.clear();

    const s = cache.stats();
    try std.testing.expectEqual(@as(u64, 0), s.hits);
    try std.testing.expectEqual(@as(u64, 0), s.misses);
}
