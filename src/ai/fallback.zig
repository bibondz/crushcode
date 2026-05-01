const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A single fallback entry: provider + model pair
pub const FallbackEntry = struct {
    provider: []const u8,
    model: []const u8,
};

/// Result of a fallback chain execution
pub const FallbackResult = struct {
    provider: []const u8,
    model: []const u8,
    attempt: u32,
    success: bool,
    error_message: []const u8,
};

/// Model fallback chain — tries models in order until one succeeds
///
/// Configured in config.toml:
///   [fallback]
///   chain = [
///     { provider = "openai", model = "gpt-4o" },
///     { provider = "anthropic", model = "claude-3.5-sonnet" },
///     { provider = "ollama", model = "llama3" },
///   ]
///   retry_delay_ms = 1000
///   max_retries = 2
pub const FallbackChain = struct {
    allocator: Allocator,
    chain: array_list_compat.ArrayList(FallbackEntry),
    retry_delay_ms: u64,
    max_retries: u32,

    pub fn init(allocator: Allocator) FallbackChain {
        return FallbackChain{
            .allocator = allocator,
            .chain = array_list_compat.ArrayList(FallbackEntry).init(allocator),
            .retry_delay_ms = 1000,
            .max_retries = 2,
        };
    }

    /// Add a fallback entry to the chain
    pub fn addEntry(self: *FallbackChain, provider: []const u8, model: []const u8) !void {
        try self.chain.append(FallbackEntry{
            .provider = try self.allocator.dupe(u8, provider),
            .model = try self.allocator.dupe(u8, model),
        });
    }

    /// Set retry delay between attempts
    pub fn setRetryDelay(self: *FallbackChain, delay_ms: u64) void {
        self.retry_delay_ms = delay_ms;
    }

    /// Set maximum retries per model
    pub fn setMaxRetries(self: *FallbackChain, max: u32) void {
        self.max_retries = max;
    }

    /// Get the chain entries
    pub fn getEntries(self: *const FallbackChain) []const FallbackEntry {
        return self.chain.items;
    }

    /// Check if the chain has any entries
    pub fn isEmpty(self: *const FallbackChain) bool {
        return self.chain.items.len == 0;
    }

    /// Get the first (primary) entry in the chain
    pub fn getPrimary(self: *const FallbackChain) ?FallbackEntry {
        if (self.chain.items.len == 0) return null;
        return self.chain.items[0];
    }

    /// Get the next fallback after the given provider+model
    pub fn getNext(self: *const FallbackChain, provider: []const u8, model: []const u8) ?FallbackEntry {
        for (self.chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.provider, provider) and
                std.mem.eql(u8, entry.model, model))
            {
                if (i + 1 < self.chain.items.len) {
                    return self.chain.items[i + 1];
                }
                return null;
            }
        }
        // If not found, return first entry
        if (self.chain.items.len > 0) return self.chain.items[0];
        return null;
    }

    /// Get a fallback entry by index
    pub fn getAtIndex(self: *const FallbackChain, index: usize) ?FallbackEntry {
        if (index >= self.chain.items.len) return null;
        return self.chain.items[index];
    }

    /// Get the number of fallback entries
    pub fn count(self: *const FallbackChain) usize {
        return self.chain.items.len;
    }

    /// Print the fallback chain configuration
    pub fn printChain(self: *const FallbackChain) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("=== Fallback Chain ===\n", .{}) catch {};
        for (self.chain.items, 1..) |entry, i| {
            stdout.print("  {d}. {s}/{s}\n", .{ i, entry.provider, entry.model }) catch {};
        }
        stdout.print("  Retry delay: {d}ms\n", .{self.retry_delay_ms}) catch {};
        stdout.print("  Max retries: {d}\n", .{self.max_retries}) catch {};
    }

    /// Sleep before retry (called between fallback attempts)
    pub fn waitBeforeRetry(self: *const FallbackChain) void {
        std.Thread.sleep(self.retry_delay_ms * std.time.ns_per_ms);
    }

    pub fn deinit(self: *FallbackChain) void {
        for (self.chain.items) |entry| {
            self.allocator.free(entry.provider);
            self.allocator.free(entry.model);
        }
        self.chain.deinit();
    }
};

// ------------------------------------------------------------
// Tests for fallback.zig
// ------------------------------------------------------------
test "FallbackChain - empty on init" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try std.testing.expect(chain.isEmpty());
    try std.testing.expect(chain.count() == 0);
}

test "FallbackChain - addEntry and primary" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try chain.addEntry("openai", "gpt-4");
    try std.testing.expect(!chain.isEmpty());
    const primary = chain.getPrimary();
    if (primary) |p| {
        try std.testing.expect(std.mem.eql(u8, p.provider, "openai"));
        try std.testing.expect(std.mem.eql(u8, p.model, "gpt-4"));
    } else {
        try std.testing.expect(false);
    }
}

test "FallbackChain - multiple entries and getNext/getAtIndex" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try chain.addEntry("openai", "gpt-4");
    try chain.addEntry("anthropic", "claude-3");
    try chain.addEntry("ollama", "llama-3");

    try std.testing.expect(chain.count() == 3);
    // Next after first should be second
    const next1 = chain.getNext("openai", "gpt-4");
    if (next1) |n1| {
        try std.testing.expect(std.mem.eql(u8, n1.provider, "anthropic"));
        try std.testing.expect(std.mem.eql(u8, n1.model, "claude-3"));
    } else {
        try std.testing.expect(false);
    }
    // Next after last should be null
    const next3 = chain.getNext("ollama", "llama-3");
    try std.testing.expect(next3 == null);
    // Unknown provider returns first
    const nextUnknown = chain.getNext("unknown", "x");
    if (nextUnknown) |nu| {
        try std.testing.expect(std.mem.eql(u8, nu.provider, "openai"));
    } else {
        try std.testing.expect(false);
    }
}

test "FallbackChain - getAtIndex" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try chain.addEntry("a", "m1");
    try chain.addEntry("b", "m2");
    const e0 = chain.getAtIndex(0);
    const e1 = chain.getAtIndex(1);
    try std.testing.expect(e0 != null);
    try std.testing.expect(e1 != null);
    try std.testing.expect(e0.?.provider == "a");
    try std.testing.expect(e1.?.model == "m2");
    const eInvalid = chain.getAtIndex(5);
    try std.testing.expect(eInvalid == null);
}

test "FallbackChain - setRetryDelay and setMaxRetries" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    chain.setRetryDelay(2500);
    chain.setMaxRetries(5);
    // Access internal fields to validate (allowed in test scope)
    try std.testing.expect(chain.retry_delay_ms == 2500);
    try std.testing.expect(chain.max_retries == 5);
}

test "FallbackChain - getEntries correctness" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try chain.addEntry("p1", "m1");
    try chain.addEntry("p2", "m2");
    const entries = chain.getEntries();
    try std.testing.expect(entries.len == 2);
    try std.testing.expect(std.mem.eql(u8, entries[0].provider, "p1"));
    try std.testing.expect(std.mem.eql(u8, entries[0].model, "m1"));
}

test "FallbackChain - empty getPrimary" {
    const alloc = std.testing.allocator;
    var chain = FallbackChain.init(alloc);
    defer chain.deinit();
    try std.testing.expect(chain.getPrimary() == null);
}
