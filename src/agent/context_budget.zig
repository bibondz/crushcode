const std = @import("std");

/// Model-specific context window budgets.
///
/// Provides per-model context limits so the interactive chat can:
///   1. Display a token usage bar in the header
///   2. Auto-trigger compaction before overflow
pub const ContextBudget = struct {
    max_context_tokens: u64,
    reserve_output_tokens: u64,
    compact_threshold: f64,

    /// Known model context sizes — first match wins (partial match via indexOf).
    const ModelBudget = struct {
        pattern: []const u8,
        max_tokens: u64,
    };

    const known_budgets = [_]ModelBudget{
        .{ .pattern = "MiniMax-M2.7", .max_tokens = 204_800 },
        .{ .pattern = "glm-5", .max_tokens = 128_000 },
        .{ .pattern = "claude", .max_tokens = 200_000 },
        .{ .pattern = "gpt-4o", .max_tokens = 128_000 },
        .{ .pattern = "deepseek", .max_tokens = 128_000 },
        .{ .pattern = "gemini", .max_tokens = 1_048_576 },
        .{ .pattern = "llama", .max_tokens = 128_000 },
        .{ .pattern = "grok", .max_tokens = 131_072 },
    };

    const default_max_tokens: u64 = 128_000;
    const default_reserve_output: u64 = 4096;
    const default_compact_threshold: f64 = 0.8;

    /// Return a `ContextBudget` matching the given model name (case-insensitive).
    pub fn forModel(model_name: []const u8) ContextBudget {
        // We need a lowercase copy for case-insensitive matching.
        // Use a fixed-size buffer — model names are always short.
        var buf: [256]u8 = undefined;
        if (model_name.len >= buf.len) {
            return defaultBudget();
        }
        const lower = std.ascii.lowerString(&buf, model_name);

        for (known_budgets) |kb| {
            var pat_buf: [256]u8 = undefined;
            if (kb.pattern.len >= pat_buf.len) continue;
            const lower_pat = std.ascii.lowerString(&pat_buf, kb.pattern);

            if (std.mem.indexOf(u8, lower, lower_pat) != null) {
                return ContextBudget{
                    .max_context_tokens = kb.max_tokens,
                    .reserve_output_tokens = default_reserve_output,
                    .compact_threshold = default_compact_threshold,
                };
            }
        }
        return defaultBudget();
    }

    /// Tokens available for input context after reserving output space.
    pub fn availableTokens(self: *const ContextBudget, used: u64) u64 {
        const usable = self.max_context_tokens -| self.reserve_output_tokens;
        return usable -| used;
    }

    /// True when used tokens exceed the compaction threshold.
    pub fn needsCompaction(self: *const ContextBudget, used: u64) bool {
        return self.usagePercent(used) >= self.compact_threshold;
    }

    /// Fraction of usable context consumed (0.0 – 1.0+).
    pub fn usagePercent(self: *const ContextBudget, used: u64) f64 {
        const usable = self.max_context_tokens -| self.reserve_output_tokens;
        if (usable == 0) return 1.0;
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(usable));
    }

    fn defaultBudget() ContextBudget {
        return ContextBudget{
            .max_context_tokens = default_max_tokens,
            .reserve_output_tokens = default_reserve_output,
            .compact_threshold = default_compact_threshold,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ContextBudget - default for unknown model" {
    const b = ContextBudget.forModel("unknown-model");
    try testing.expectEqual(@as(u64, 128_000), b.max_context_tokens);
    try testing.expectEqual(@as(u64, 4096), b.reserve_output_tokens);
    try testing.expect(b.compact_threshold > 0.79 and b.compact_threshold < 0.81);
}

test "ContextBudget - claude match" {
    const b = ContextBudget.forModel("claude-3.5-sonnet");
    try testing.expectEqual(@as(u64, 200_000), b.max_context_tokens);
}

test "ContextBudget - case insensitive match" {
    const b = ContextBudget.forModel("Claude-3-Opus");
    try testing.expectEqual(@as(u64, 200_000), b.max_context_tokens);
}

test "ContextBudget - gemini match" {
    const b = ContextBudget.forModel("gemini-2.0-flash");
    try testing.expectEqual(@as(u64, 1_048_576), b.max_context_tokens);
}

test "ContextBudget - MiniMax match" {
    const b = ContextBudget.forModel("MiniMax-M2.7");
    try testing.expectEqual(@as(u64, 204_800), b.max_context_tokens);
}

test "ContextBudget - glm-5 match" {
    const b = ContextBudget.forModel("glm-5");
    try testing.expectEqual(@as(u64, 128_000), b.max_context_tokens);
}

test "ContextBudget - gpt-4o match" {
    const b = ContextBudget.forModel("gpt-4o-2024-08-06");
    try testing.expectEqual(@as(u64, 128_000), b.max_context_tokens);
}

test "ContextBudget - deepseek match" {
    const b = ContextBudget.forModel("deepseek-chat");
    try testing.expectEqual(@as(u64, 128_000), b.max_context_tokens);
}

test "ContextBudget - llama match" {
    const b = ContextBudget.forModel("llama-3.3-70b");
    try testing.expectEqual(@as(u64, 128_000), b.max_context_tokens);
}

test "ContextBudget - grok match" {
    const b = ContextBudget.forModel("grok-3");
    try testing.expectEqual(@as(u64, 131_072), b.max_context_tokens);
}

test "ContextBudget - availableTokens" {
    const b = ContextBudget.forModel("claude-3.5-sonnet");
    // usable = 200_000 - 4096 = 195_904
    try testing.expectEqual(@as(u64, 195_904), b.availableTokens(0));
    try testing.expectEqual(@as(u64, 95_904), b.availableTokens(100_000));
    try testing.expectEqual(@as(u64, 0), b.availableTokens(300_000));
}

test "ContextBudget - needsCompaction false when low usage" {
    const b = ContextBudget.forModel("claude-3.5-sonnet");
    try testing.expect(!b.needsCompaction(10_000));
}

test "ContextBudget - needsCompaction true when at threshold" {
    const b = ContextBudget.forModel("claude-3.5-sonnet");
    // usable = 195_904, 80% = 156_723.2
    try testing.expect(b.needsCompaction(157_000));
}

test "ContextBudget - usagePercent" {
    const b = ContextBudget.forModel("gpt-4o");
    // usable = 128_000 - 4096 = 123_904
    const pct = b.usagePercent(61_952);
    try testing.expect(pct > 0.49 and pct < 0.51);
}
