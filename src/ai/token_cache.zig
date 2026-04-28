const std = @import("std");
const array_list_compat = @import("array_list_compat");
const Allocator = std.mem.Allocator;

/// Simple token estimate cache. Stores text→token_count mappings
/// using a HashMap. When capacity is exceeded, evicts the oldest entries.
pub const TokenCache = struct {
    allocator: Allocator,
    cache: std.StringHashMap(u32),
    capacity: usize,
    insertion_order: array_list_compat.ArrayList([]const u8),

    pub fn init(allocator: Allocator, capacity: usize) TokenCache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(u32).init(allocator),
            .capacity = capacity,
            .insertion_order = array_list_compat.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TokenCache) void {
        // Free all owned keys
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
        self.insertion_order.deinit();
    }

    /// Get cached token count for text, or estimate it.
    /// Estimation heuristic: len / 4 (approximation for English text).
    pub fn getOrEstimate(self: *TokenCache, text: []const u8) u32 {
        if (self.cache.get(text)) |count| {
            return count;
        }
        const estimate: u32 = @intCast(text.len / 4);
        // Store in cache
        const key = self.allocator.dupe(u8, text) catch return estimate;
        self.cache.put(key, estimate) catch {
            self.allocator.free(key);
            return estimate;
        };
        self.insertion_order.append(key) catch {};
        // Evict oldest if over capacity
        while (self.insertion_order.items.len > self.capacity) {
            const oldest = self.insertion_order.orderedRemove(0);
            _ = self.cache.fetchRemove(oldest);
            self.allocator.free(oldest);
        }
        return estimate;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TokenCache - init/deinit no crash" {
    const allocator = std.testing.allocator;
    var cache = TokenCache.init(allocator, 10);
    defer cache.deinit();
    try testing.expectEqual(@as(usize, 0), cache.cache.count());
    try testing.expectEqual(@as(usize, 0), cache.insertion_order.items.len);
}

test "TokenCache - getOrEstimate returns len/4 for uncached text" {
    const allocator = std.testing.allocator;
    var cache = TokenCache.init(allocator, 10);
    defer cache.deinit();

    const text = "Hello, world!"; // 13 chars => 13/4 = 3
    const tokens = cache.getOrEstimate(text);
    try testing.expectEqual(@as(u32, 3), tokens);
}

test "TokenCache - getOrEstimate returns cached value on second call" {
    const allocator = std.testing.allocator;
    var cache = TokenCache.init(allocator, 10);
    defer cache.deinit();

    const text = "Hello, world!";
    const tokens1 = cache.getOrEstimate(text);
    const tokens2 = cache.getOrEstimate(text);
    try testing.expectEqual(tokens1, tokens2);
    try testing.expectEqual(@as(usize, 1), cache.cache.count());
}

test "TokenCache - capacity eviction works" {
    const allocator = std.testing.allocator;
    var cache = TokenCache.init(allocator, 3); // Capacity of 3
    defer cache.deinit();

    // Add 5 items
    _ = cache.getOrEstimate("one");
    _ = cache.getOrEstimate("two");
    _ = cache.getOrEstimate("three");
    _ = cache.getOrEstimate("four");
    _ = cache.getOrEstimate("five");

    // Should only have 3 items (capacity)
    try testing.expectEqual(@as(usize, 3), cache.cache.count());
    try testing.expectEqual(@as(usize, 3), cache.insertion_order.items.len);

    // First item should be evicted
    try testing.expect(cache.cache.get("one") == null);
    try testing.expect(cache.cache.get("two") != null); // Still in cache
    try testing.expect(cache.cache.get("five") != null); // New item
}

test "TokenCache - empty text returns 0" {
    const allocator = std.testing.allocator;
    var cache = TokenCache.init(allocator, 10);
    defer cache.deinit();

    const tokens = cache.getOrEstimate("");
    try testing.expectEqual(@as(u32, 0), tokens);
}
