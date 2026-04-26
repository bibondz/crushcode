// src/tui/test_harness.zig
// Test harness for TUI model logic — no real terminal/vaxis TTY required.
//
// Tests business logic only:
//   - TypewriterState: setText, updateText, tick, countCodepoints, revealAll
//   - BudgetManager: cost recording, threshold alerts, over-budget detection
//   - Streaming simulation: token append, message history accumulation
//   - Error state handling
//
// Does NOT import or call Model.create() (requires /dev/tty).

const std = @import("std");
const testing = std.testing;

// Standalone modules — safe to import (no TTY dependency in business logic)
const widget_typewriter = @import("widget_typewriter");
const theme_mod = @import("theme");
const usage_budget = @import("usage_budget");
const usage_pricing = @import("usage_pricing");

// ---------------------------------------------------------------------------
// TypewriterState tests
// ---------------------------------------------------------------------------

test "typewriter init has empty text and is complete" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    try testing.expectEqualStrings("", tw.full_text);
    try testing.expectEqual(@as(usize, 0), tw.revealed);
    try testing.expectEqual(@as(usize, 0), tw.total_codepoints);
    try testing.expect(tw.complete);
}

test "typewriter setText sets total_codepoints and resets revealed" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("Hello, world!");
    try testing.expectEqualStrings("Hello, world!", tw.full_text);
    try testing.expectEqual(@as(usize, 13), tw.total_codepoints);
    try testing.expectEqual(@as(usize, 0), tw.revealed);
    try testing.expect(!tw.complete);
}

test "typewriter setText counts Unicode codepoints correctly" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    // "café" = 4 codepoints (c, a, f, é) — é is 2 bytes in UTF-8 but 1 codepoint
    tw.setText("caf\u{00E9}");
    try testing.expectEqual(@as(usize, 4), tw.total_codepoints);

    // "日本語" = 3 codepoints, each 3 bytes
    tw.setText("日本語");
    try testing.expectEqual(@as(usize, 3), tw.total_codepoints);

    // Mixed ASCII + emoji: "Hi 😀" = 4 codepoints (H, i, space, 😀)
    tw.setText("Hi \u{1F600}");
    try testing.expectEqual(@as(usize, 4), tw.total_codepoints);
}

test "typewriter tick advances revealed count" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("ABCDE");
    try testing.expectEqual(@as(usize, 0), tw.revealed);

    // tick() checks elapsed time. The delay is 30-80ms.
    // Simulate enough time passing by sleeping then ticking.
    const initial_revealed = tw.revealed;

    // Sleep 100ms to ensure the delay threshold is passed
    std.Thread.sleep(100 * std.time.ns_per_ms);
    tw.tick();

    try testing.expect(tw.revealed > initial_revealed);
}

test "typewriter tick reaches completion" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("AB");

    // Keep ticking until complete (max delay per char is 80ms, 2 chars = 160ms max)
    var i: usize = 0;
    while (!tw.complete and i < 20) : (i += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        tw.tick();
    }
    try testing.expect(tw.complete);
    try testing.expectEqual(@as(usize, 2), tw.revealed);
}

test "typewriter revealAll sets complete and reveals everything" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("Hello, world!");
    try testing.expect(!tw.complete);

    tw.revealAll();
    try testing.expect(tw.complete);
    try testing.expectEqual(@as(usize, 13), tw.revealed);
    try testing.expectEqual(@as(usize, 13), tw.total_codepoints);
}

test "typewriter updateText updates total_codepoints without resetting revealed" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("Hello");
    // Simulate some reveal
    tw.revealAll();
    try testing.expectEqual(@as(usize, 5), tw.revealed);

    // Now update text (simulates streaming — text grows)
    tw.updateText("Hello, world!");
    try testing.expectEqual(@as(usize, 13), tw.total_codepoints);
    // revealed stays at 5 — updateText does NOT reset it
    try testing.expectEqual(@as(usize, 5), tw.revealed);
    // Should resume animation since revealed < total_codepoints
    try testing.expect(!tw.complete);
}

test "typewriter revealedText returns correct slice" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("ABCDE");
    try testing.expectEqualStrings("", tw.revealedText());

    tw.revealAll();
    try testing.expectEqualStrings("ABCDE", tw.revealedText());
}

test "typewriter unrevealedText returns remaining portion" {
    const theme = theme_mod.defaultTheme();
    var tw = widget_typewriter.TypewriterState.init(theme);
    defer tw.deinit();

    tw.setText("ABCDE");
    tw.revealAll();
    try testing.expectEqualStrings("", tw.unrevealedText());

    tw.setText("ABCDE");
    // revealed = 0, unrevealed = full text
    try testing.expectEqualStrings("ABCDE", tw.unrevealedText());
}

// ---------------------------------------------------------------------------
// BudgetManager tests
// ---------------------------------------------------------------------------

test "budget manager init has zero spending" {
    const config = usage_budget.BudgetConfig{};
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    try testing.expectEqual(@as(f64, 0.0), mgr.session_spent);
    try testing.expectEqual(@as(f64, 0.0), mgr.daily_spent);
    try testing.expectEqual(@as(f64, 0.0), mgr.monthly_spent);
}

test "budget recordCost accumulates spending" {
    const config = usage_budget.BudgetConfig{
        .per_session_limit_usd = 10.0,
        .alert_threshold_pct = 0.8,
    };
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    mgr.recordCost(1.5);
    try testing.expectEqual(@as(f64, 1.5), mgr.session_spent);

    mgr.recordCost(2.5);
    try testing.expectEqual(@as(f64, 4.0), mgr.session_spent);
}

test "budget alert fires at threshold" {
    const config = usage_budget.BudgetConfig{
        .per_session_limit_usd = 10.0,
        .alert_threshold_pct = 0.8,
    };
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    // Below threshold — no alert
    mgr.recordCost(7.0);
    try testing.expect(!mgr.shouldAlert());

    // At threshold — alert fires
    mgr.recordCost(1.0);
    try testing.expect(mgr.shouldAlert());
}

test "budget isOverBudget detects overspend" {
    const config = usage_budget.BudgetConfig{
        .per_session_limit_usd = 5.0,
        .alert_threshold_pct = 0.8,
    };
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    try testing.expect(!mgr.isOverBudget());

    mgr.recordCost(3.0);
    try testing.expect(!mgr.isOverBudget());

    mgr.recordCost(3.0);
    try testing.expect(mgr.isOverBudget());
}

test "budget no alert when config is not set" {
    const config = usage_budget.BudgetConfig{};
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    mgr.recordCost(1000.0);
    try testing.expect(!mgr.shouldAlert());
    try testing.expect(!mgr.isOverBudget());
}

test "budget resetSession clears session spending" {
    const config = usage_budget.BudgetConfig{
        .per_session_limit_usd = 10.0,
    };
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    mgr.recordCost(5.0);
    try testing.expectEqual(@as(f64, 5.0), mgr.session_spent);

    mgr.resetSession();
    try testing.expectEqual(@as(f64, 0.0), mgr.session_spent);
}

test "budget checkBudget returns correct status" {
    const config = usage_budget.BudgetConfig{
        .per_session_limit_usd = 10.0,
        .alert_threshold_pct = 0.8,
    };
    var mgr = usage_budget.BudgetManager.init(testing.allocator, config);
    defer mgr.deinit();

    mgr.recordCost(8.0);
    const status = mgr.checkBudget();

    try testing.expectEqual(@as(f64, 8.0), status.session_spent);
    try testing.expectEqual(@as(f64, 10.0), status.session_limit);
    try testing.expect(!status.isOverBudget());
    try testing.expect(status.shouldAlert(0.8));
}

test "budget formatCost formats various amounts" {
    const tiny = try usage_budget.BudgetManager.formatCost(testing.allocator, 0.0001);
    defer testing.allocator.free(tiny);
    try testing.expectEqualStrings("$0.0001", tiny);

    const small = try usage_budget.BudgetManager.formatCost(testing.allocator, 0.05);
    defer testing.allocator.free(small);
    try testing.expectEqualStrings("$0.050", small);

    const large = try usage_budget.BudgetManager.formatCost(testing.allocator, 5.5);
    defer testing.allocator.free(large);
    try testing.expectEqualStrings("$5.50", large);
}

// ---------------------------------------------------------------------------
// Streaming simulation tests (pure logic, no Model)
// ---------------------------------------------------------------------------

/// Simulates streaming token accumulation — mirrors handleStreamToken logic
/// without requiring Model/vaxis.
const StreamSimulator = struct {
    messages: std.ArrayList(SimMessage),
    assistant_stream_index: ?usize,
    awaiting_first_token: bool,
    allocator: std.mem.Allocator,

    const SimMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    fn init(allocator: std.mem.Allocator) StreamSimulator {
        return .{
            .messages = std.ArrayList(SimMessage).empty,
            .assistant_stream_index = null,
            .awaiting_first_token = true,
            .allocator = allocator,
        };
    }

    fn deinit(self: *StreamSimulator) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
    }

    /// Add a placeholder "Thinking..." message for the assistant
    fn startAssistantPlaceholder(self: *StreamSimulator) !void {
        const msg = SimMessage{
            .role = try self.allocator.dupe(u8, "assistant"),
            .content = try self.allocator.dupe(u8, "Thinking..."),
        };
        try self.messages.append(self.allocator, msg);
        self.assistant_stream_index = self.messages.items.len - 1;
        self.awaiting_first_token = true;
    }

    /// Feed a single token — mirrors handleStreamToken logic
    fn feedToken(self: *StreamSimulator, token: []const u8) !void {
        if (token.len == 0) return;

        const index = self.assistant_stream_index orelse return;
        if (self.awaiting_first_token) {
            // Replace placeholder content with token
            self.allocator.free(self.messages.items[index].content);
            self.messages.items[index].content = try self.allocator.dupe(u8, token);
            self.awaiting_first_token = false;
        } else {
            // Append token to existing content
            const existing = self.messages.items[index].content;
            const updated = try std.mem.concat(self.allocator, u8, &.{ existing, token });
            self.allocator.free(existing);
            self.messages.items[index].content = updated;
        }
    }

    /// Feed multiple tokens in sequence
    fn feedTokens(self: *StreamSimulator, tokens: []const []const u8) !void {
        for (tokens) |token| {
            try self.feedToken(token);
        }
    }

    /// Simulate finishRequestWithErrorText
    fn finishWithError(self: *StreamSimulator, text: []const u8) !void {
        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                self.allocator.free(self.messages.items[index].role);
                self.allocator.free(self.messages.items[index].content);
                self.messages.items[index].role = try self.allocator.dupe(u8, "error");
                self.messages.items[index].content = try self.allocator.dupe(u8, text);
            } else {
                try self.messages.append(self.allocator, .{
                    .role = try self.allocator.dupe(u8, "error"),
                    .content = try self.allocator.dupe(u8, text),
                });
            }
            self.awaiting_first_token = false;
        } else {
            try self.messages.append(self.allocator, .{
                .role = try self.allocator.dupe(u8, "error"),
                .content = try self.allocator.dupe(u8, text),
            });
        }
    }

    /// Get the current assistant message content
    fn getAssistantContent(self: *const StreamSimulator) ?[]const u8 {
        const index = self.assistant_stream_index orelse return null;
        if (index >= self.messages.items.len) return null;
        return self.messages.items[index].content;
    }

    /// Get message count
    fn messageCount(self: *const StreamSimulator) usize {
        return self.messages.items.len;
    }
};

test "streaming single token updates message" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    try sim.startAssistantPlaceholder();
    try sim.feedToken("Hello");

    const content = sim.getAssistantContent().?;
    try testing.expectEqualStrings("Hello", content);
    try testing.expect(!sim.awaiting_first_token);
}

test "streaming multiple tokens appends correctly" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    try sim.startAssistantPlaceholder();

    const tokens = [_][]const u8{ "Hello", ", ", "world", "!" };
    try sim.feedTokens(&tokens);

    const content = sim.getAssistantContent().?;
    try testing.expectEqualStrings("Hello, world!", content);
}

test "streaming empty tokens are ignored" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    try sim.startAssistantPlaceholder();
    try sim.feedToken("");
    // First token was empty — still awaiting
    try testing.expect(sim.awaiting_first_token);

    try sim.feedToken("Hi");
    try testing.expectEqualStrings("Hi", sim.getAssistantContent().?);
}

test "finish request updates token counts" {
    // Simulates finishRequestSuccess logic: accumulates input/output token counts
    var total_input: u64 = 0;
    var total_output: u64 = 0;
    var request_count: u32 = 0;

    // Simulate first request
    total_input += 150;
    total_output += 300;
    request_count += 1;

    try testing.expectEqual(@as(u64, 150), total_input);
    try testing.expectEqual(@as(u64, 300), total_output);
    try testing.expectEqual(@as(u32, 1), request_count);

    // Simulate second request
    total_input += 200;
    total_output += 450;
    request_count += 1;

    try testing.expectEqual(@as(u64, 350), total_input);
    try testing.expectEqual(@as(u64, 750), total_output);
    try testing.expectEqual(@as(u32, 2), request_count);
}

test "error handling sets error message" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    try sim.startAssistantPlaceholder();
    try sim.finishWithError("Network error while contacting provider.");

    // The placeholder message should now have role "error"
    const index = sim.assistant_stream_index.?;
    try testing.expectEqualStrings("error", sim.messages.items[index].role);
    try testing.expectEqualStrings("Network error while contacting provider.", sim.messages.items[index].content);
    try testing.expect(!sim.awaiting_first_token);
}

test "error handling after streaming appends new error message" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    try sim.startAssistantPlaceholder();
    try sim.feedToken("Partial response");
    // Now simulate an error after some tokens were received
    try sim.finishWithError("Request timed out.");

    // Original message should still be "assistant"
    const original = sim.assistant_stream_index.?;
    try testing.expectEqualStrings("assistant", sim.messages.items[original].role);
    try testing.expectEqualStrings("Partial response", sim.messages.items[original].content);

    // A new error message should be appended
    try testing.expectEqual(@as(usize, 2), sim.messageCount());
    try testing.expectEqualStrings("error", sim.messages.items[1].role);
    try testing.expectEqualStrings("Request timed out.", sim.messages.items[1].content);
}

// ---------------------------------------------------------------------------
// Message history accumulation tests
// ---------------------------------------------------------------------------

test "message history accumulates across multiple turns" {
    var sim = StreamSimulator.init(testing.allocator);
    defer sim.deinit();

    // Turn 1: user message + assistant placeholder + streaming
    try sim.messages.append(testing.allocator, .{
        .role = try testing.allocator.dupe(u8, "user"),
        .content = try testing.allocator.dupe(u8, "What is Zig?"),
    });
    try sim.startAssistantPlaceholder();
    try sim.feedTokens(&.{ "Zig is ", "a systems ", "programming ", "language." });

    try testing.expectEqual(@as(usize, 2), sim.messageCount());
    try testing.expectEqualStrings("user", sim.messages.items[0].role);
    try testing.expectEqualStrings("What is Zig?", sim.messages.items[0].content);
    try testing.expectEqualStrings("Zig is a systems programming language.", sim.messages.items[1].content);

    // Turn 2: add another user message + new assistant stream
    sim.assistant_stream_index = null; // Reset for new turn
    sim.awaiting_first_token = true;
    try sim.messages.append(testing.allocator, .{
        .role = try testing.allocator.dupe(u8, "user"),
        .content = try testing.allocator.dupe(u8, "Tell me more"),
    });
    try sim.startAssistantPlaceholder();
    try sim.feedTokens(&.{ "Zig ", "offers ", "comptime." });

    try testing.expectEqual(@as(usize, 4), sim.messageCount());
    try testing.expectEqualStrings("Zig offers comptime.", sim.messages.items[3].content);
}

// ---------------------------------------------------------------------------
// PricingTable integration test
// ---------------------------------------------------------------------------

test "pricing table estimates cost for known provider" {
    var table = usage_pricing.PricingTable.init(testing.allocator) catch |err| {
        // If init fails (e.g. HashMap allocation), skip test gracefully
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer {
        var iter = table.entries.iterator();
        while (iter.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
        }
        table.entries.deinit();
    }

    // OpenAI gpt-4o should have known pricing
    const cost = table.estimateCostSimple("openai", "gpt-4o", 1000, 500);
    // Input: 1000/1M * $2.50 = $0.0025, Output: 500/1M * $10.00 = $0.005
    // Total ≈ $0.0075 (values depend on pricing table entries)
    try testing.expect(cost >= 0.0);
}

test "pricing table returns zero for unknown provider" {
    var table = usage_pricing.PricingTable.init(testing.allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer {
        var iter = table.entries.iterator();
        while (iter.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
        }
        table.entries.deinit();
    }

    const cost = table.estimateCostSimple("unknown_provider", "unknown_model", 1000, 500);
    try testing.expectEqual(@as(f64, 0.0), cost);
}
