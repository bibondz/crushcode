const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Model swap event for tracking hot-swap history
pub const ModelSwapEvent = struct {
    from_model: []const u8,
    to_model: []const u8,
    from_provider: []const u8,
    to_provider: []const u8,
    reason: SwapReason,
    timestamp: i64,

    pub const SwapReason = enum {
        manual, // User explicitly requested swap
        fallback, // Model unavailable, falling back
        cost, // Switching for cost optimization
        capability, // Switching for specific capability (e.g., vision)
    };

    pub fn deinit(self: *ModelSwapEvent, allocator: Allocator) void {
        allocator.free(self.from_model);
        allocator.free(self.to_model);
        allocator.free(self.from_provider);
        allocator.free(self.to_provider);
    }
};

/// Current active model configuration
pub const ActiveModel = struct {
    provider: []const u8,
    model: []const u8,
    swapped_at: i64,

    pub fn deinit(self: *ActiveModel, allocator: Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
    }
};

/// Model Hot-Swap manager — allows changing the active model mid-session
/// without restarting the conversation.
///
/// Usage:
///   1. Initialize with default model
///   2. Call `swap()` to change model at any time
///   3. Get current model with `active()`
///   4. Check history with `swapHistory()`
///
/// Reference: Crush model hot-swap (F13)
pub const ModelHotSwap = struct {
    allocator: Allocator,
    current: ActiveModel,
    history: array_list_compat.ArrayList(ModelSwapEvent),

    pub fn init(allocator: Allocator, provider: []const u8, model: []const u8) !ModelHotSwap {
        return ModelHotSwap{
            .allocator = allocator,
            .current = ActiveModel{
                .provider = try allocator.dupe(u8, provider),
                .model = try allocator.dupe(u8, model),
                .swapped_at = std.time.timestamp(),
            },
            .history = array_list_compat.ArrayList(ModelSwapEvent).init(allocator),
        };
    }

    pub fn deinit(self: *ModelHotSwap) void {
        self.current.deinit(self.allocator);
        for (self.history.items) |*e| {
            e.deinit(self.allocator);
        }
        self.history.deinit();
    }

    /// Swap to a new model. Records the swap event in history.
    pub fn swap(self: *ModelHotSwap, new_provider: []const u8, new_model: []const u8, reason: ModelSwapEvent.SwapReason) !void {
        const event = ModelSwapEvent{
            .from_model = try self.allocator.dupe(u8, self.current.model),
            .to_model = try self.allocator.dupe(u8, new_model),
            .from_provider = try self.allocator.dupe(u8, self.current.provider),
            .to_provider = try self.allocator.dupe(u8, new_provider),
            .reason = reason,
            .timestamp = std.time.timestamp(),
        };

        // Update current
        self.allocator.free(self.current.provider);
        self.allocator.free(self.current.model);
        self.current.provider = try self.allocator.dupe(u8, new_provider);
        self.current.model = try self.allocator.dupe(u8, new_model);
        self.current.swapped_at = std.time.timestamp();

        try self.history.append(event);
    }

    /// Get the currently active model
    pub fn active(self: *const ModelHotSwap) ActiveModel {
        return .{
            .provider = self.current.provider,
            .model = self.current.model,
            .swapped_at = self.current.swapped_at,
        };
    }

    /// Get the model name
    pub fn modelName(self: *const ModelHotSwap) []const u8 {
        return self.current.model;
    }

    /// Get the provider name
    pub fn providerName(self: *const ModelHotSwap) []const u8 {
        return self.current.provider;
    }

    /// Get the swap history
    pub fn swapHistory(self: *const ModelHotSwap) []const ModelSwapEvent {
        return self.history.items;
    }

    /// Number of swaps performed
    pub fn swapCount(self: *const ModelHotSwap) u32 {
        return @intCast(self.history.items.len);
    }

    /// Time since last swap in seconds
    pub fn timeSinceLastSwap(self: *const ModelHotSwap) u64 {
        const now = std.time.timestamp();
        const elapsed = now - self.current.swapped_at;
        return if (elapsed > 0) @intCast(elapsed) else 0;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "ModelHotSwap - init with default model" {
    var hs = try ModelHotSwap.init(testing.allocator, "ollama", "llama3");
    defer hs.deinit();

    try testing.expectEqualStrings("ollama", hs.providerName());
    try testing.expectEqualStrings("llama3", hs.modelName());
    try testing.expectEqual(@as(u32, 0), hs.swapCount());
}

test "ModelHotSwap - swap to new model" {
    var hs = try ModelHotSwap.init(testing.allocator, "ollama", "llama3");
    defer hs.deinit();

    try hs.swap("openrouter", "claude-3-opus", .manual);

    try testing.expectEqualStrings("openrouter", hs.providerName());
    try testing.expectEqualStrings("claude-3-opus", hs.modelName());
    try testing.expectEqual(@as(u32, 1), hs.swapCount());
}

test "ModelHotSwap - multiple swaps with history" {
    var hs = try ModelHotSwap.init(testing.allocator, "ollama", "llama3");
    defer hs.deinit();

    try hs.swap("openrouter", "claude-3-opus", .manual);
    try hs.swap("openrouter", "gpt-4", .capability);
    try hs.swap("ollama", "llama3", .cost);

    try testing.expectEqualStrings("ollama", hs.providerName());
    try testing.expectEqualStrings("llama3", hs.modelName());
    try testing.expectEqual(@as(u32, 3), hs.swapCount());

    const history = hs.swapHistory();
    try testing.expectEqual(ModelSwapEvent.SwapReason.manual, history[0].reason);
    try testing.expectEqual(ModelSwapEvent.SwapReason.capability, history[1].reason);
    try testing.expectEqual(ModelSwapEvent.SwapReason.cost, history[2].reason);
}

test "ModelHotSwap - timeSinceLastSwap" {
    var hs = try ModelHotSwap.init(testing.allocator, "ollama", "llama3");
    defer hs.deinit();

    // Should be 0 or very small right after init
    const elapsed = hs.timeSinceLastSwap();
    try testing.expect(elapsed < 5); // Less than 5 seconds
}
