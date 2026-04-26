// src/tui/model/token_tracking.zig
// Token tracking and cost estimation methods extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const usage_pricing = @import("usage_pricing");
const compaction_mod = @import("compaction");
const context_limits = @import("context_limits");
const helpers = @import("helpers.zig");

pub fn estimatedCostUsd(self: *const Model) f64 {
    const input_tokens: u32 = @intCast(@min(self.total_input_tokens, std.math.maxInt(u32)));
    const output_tokens: u32 = @intCast(@min(self.total_output_tokens, std.math.maxInt(u32)));
    return self.pricing_table.estimateCostSimple(self.provider_name, helpers.resolvedPricingModel(self), input_tokens, output_tokens);
}

pub fn estimateContextTokens(self: *const Model) u64 {
    var total: u64 = 0;
    if (self.effective_system_prompt) |prompt| {
        total += compaction_mod.ContextCompactor.estimateTokens(prompt);
    }
    for (self.history.items) |msg| {
        if (msg.content) |content| {
            total += compaction_mod.ContextCompactor.estimateTokens(content);
        }
    }
    return total;
}

pub fn contextPercent(self: *const Model) u8 {
    const total_tokens = self.total_input_tokens + self.total_output_tokens;
    const max_tokens = context_limits.getContextWindow(self.provider_name, self.model_name);
    const percent = @min((total_tokens * 100) / max_tokens, 100);
    return @intCast(percent);
}
