/// Side Chains — lightweight detour conversations that don't pollute the main thread.
///
/// A side chain is a temporary context forked from the main conversation.
/// It captures the context snapshot at the point of creation, runs an
/// independent Q&A exchange, and returns a compact summary to the main thread.
///
/// Usage:
///   /btw <question>   — create side chain, get compact summary
///   /btw history      — list all side chains
///   /btw promote <N>  — promote side chain N's full content to main thread
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Status of a side chain.
pub const SideChainStatus = enum {
    active,
    completed,
    promoted,
};

/// A single message within a side chain conversation.
pub const SideChainMessage = struct {
    role: []const u8,
    content: []const u8,

    pub fn deinit(self: *SideChainMessage, allocator: Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
    }
};

/// A side chain — an independent conversation forked from the main thread.
pub const SideChain = struct {
    id: u32,
    parent_message_index: u32,
    question: []const u8,
    messages: std.ArrayList(SideChainMessage),
    summary: ?[]const u8,
    token_usage: u64,
    status: SideChainStatus,

    pub fn deinit(self: *SideChain, allocator: Allocator) void {
        allocator.free(self.question);
        if (self.summary) |s| allocator.free(s);
        for (self.messages.items) |*msg| {
            var m = msg;
            m.deinit(allocator);
        }
        self.messages.deinit(allocator);
    }
};

/// Manages all side chains for a session.
pub const SideChainManager = struct {
    allocator: Allocator,
    chains: std.ArrayList(SideChain),
    next_id: u32,

    /// Initialize a new SideChainManager.
    pub fn init(allocator: Allocator) SideChainManager {
        return .{
            .allocator = allocator,
            .chains = std.ArrayList(SideChain).empty,
            .next_id = 1,
        };
    }

    /// Free all resources owned by the manager.
    pub fn deinit(self: *SideChainManager) void {
        for (self.chains.items) |*chain| {
            chain.deinit(self.allocator);
        }
        self.chains.deinit(self.allocator);
    }

    /// Create a new side chain with a context snapshot.
    /// Adds a system message with the context and a user message with the question.
    /// Returns a pointer to the newly created chain.
    pub fn createChain(self: *SideChainManager, parent_message_index: u32, question: []const u8, context_snapshot: []const u8) !*SideChain {
        const id = self.next_id;
        self.next_id += 1;

        var chain = SideChain{
            .id = id,
            .parent_message_index = parent_message_index,
            .question = try self.allocator.dupe(u8, question),
            .messages = try std.ArrayList(SideChainMessage).initCapacity(self.allocator, 4),
            .summary = null,
            .token_usage = 0,
            .status = .active,
        };

        // Add system message with context snapshot
        const system_msg = SideChainMessage{
            .role = try self.allocator.dupe(u8, "system"),
            .content = try std.fmt.allocPrint(self.allocator, "You are answering a quick side question. Use the following context to answer concisely.\n\n=== Context ===\n{s}", .{context_snapshot}),
        };
        try chain.messages.append(self.allocator, system_msg);

        // Add user message with the question
        const user_msg = SideChainMessage{
            .role = try self.allocator.dupe(u8, "user"),
            .content = try self.allocator.dupe(u8, question),
        };
        try chain.messages.append(self.allocator, user_msg);

        try self.chains.append(self.allocator, chain);
        return &self.chains.items[self.chains.items.len - 1];
    }

    /// Record an AI response in the side chain and generate a summary.
    pub fn executeChain(self: *SideChainManager, chain_id: u32, ai_response: []const u8) !void {
        const chain = self.getChain(chain_id) orelse return error.ChainNotFound;

        const assistant_msg = SideChainMessage{
            .role = try self.allocator.dupe(u8, "assistant"),
            .content = try self.allocator.dupe(u8, ai_response),
        };
        try chain.messages.append(self.allocator, assistant_msg);

        // Estimate tokens (rough: 4 chars per token)
        chain.token_usage += @intCast(ai_response.len / 4);
        chain.status = .completed;

        // Generate summary
        const summary = try self.summarizeChain(chain_id);
        if (chain.summary) |old| self.allocator.free(old);
        chain.summary = summary;
    }

    /// Generate a compact summary of a side chain.
    /// Uses the last assistant message content, truncated to 500 chars.
    pub fn summarizeChain(self: *SideChainManager, chain_id: u32) ![]const u8 {
        const chain = self.getChain(chain_id) orelse return error.ChainNotFound;

        // Find the last assistant message
        var last_assistant: ?[]const u8 = null;
        var i: usize = chain.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, chain.messages.items[i].role, "assistant")) {
                last_assistant = chain.messages.items[i].content;
                break;
            }
        }

        const content = last_assistant orelse "(no response)";

        // Truncate to 500 chars for compactness
        const max_len = 500;
        if (content.len <= max_len) {
            return try std.fmt.allocPrint(self.allocator, "[btw #{d}: {s} → {s}]", .{ chain.id, chain.question, content });
        }
        // Find a good break point (sentence end, newline, or space)
        var end = max_len;
        while (end > max_len / 2) : (end -= 1) {
            if (content[end] == '.' or content[end] == '\n' or content[end] == ' ') {
                break;
            }
        }
        if (end <= max_len / 2) end = max_len;

        return try std.fmt.allocPrint(self.allocator, "[btw #{d}: {s} → {s}...]", .{ chain.id, chain.question, content[0..end] });
    }

    /// Promote a side chain — return its full content for injection into main thread.
    pub fn promoteChain(self: *SideChainManager, chain_id: u32) ![]const u8 {
        const chain = self.getChain(chain_id) orelse return error.ChainNotFound;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);
        try writer.print("=== Side Chain #{d} (promoted) ===\n", .{chain.id});
        try writer.print("Question: {s}\n\n", .{chain.question});

        for (chain.messages.items) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) continue;
            try writer.print("[{s}]: {s}\n\n", .{ msg.role, msg.content });
        }

        chain.status = .promoted;
        return buf.toOwnedSlice(self.allocator);
    }

    /// Get a side chain by ID.
    pub fn getChain(self: *SideChainManager, chain_id: u32) ?*SideChain {
        for (self.chains.items) |*chain| {
            if (chain.id == chain_id) return chain;
        }
        return null;
    }

    /// List all side chains as a formatted string.
    pub fn listChains(self: *SideChainManager) ![]const u8 {
        if (self.chains.items.len == 0) {
            return try self.allocator.dupe(u8, "No side chains in this session.");
        }

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);
        try writer.print("Side Chains ({d}):\n", .{self.chains.items.len});

        for (self.chains.items) |chain| {
            const status_str = switch (chain.status) {
                .active => "active",
                .completed => "completed",
                .promoted => "promoted",
            };
            const preview = if (chain.question.len > 50) chain.question[0..50] else chain.question;
            try writer.print("  #{d}  [{s}]  '{s}'  ({d} msgs, {d} tokens)\n", .{
                chain.id,
                status_str,
                preview,
                chain.messages.items.len,
                chain.token_usage,
            });
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Format a compact summary suitable for injection into the main conversation.
    pub fn formatCompactSummary(self: *SideChainManager, chain_id: u32) ![]const u8 {
        const chain = self.getChain(chain_id) orelse return error.ChainNotFound;
        if (chain.summary) |s| return try self.allocator.dupe(u8, s);
        return try self.summarizeChain(chain_id);
    }

    /// Build an array of ChatMessage-compatible structs from a side chain.
    /// Returns messages suitable for sending to the AI client.
    pub fn buildChatMessages(self: *SideChainManager, chain_id: u32) ![]const ChatMessageLike {
        const chain = self.getChain(chain_id) orelse return error.ChainNotFound;

        const messages = try self.allocator.alloc(ChatMessageLike, chain.messages.items.len);
        for (chain.messages.items, 0..) |msg, i| {
            messages[i] = .{
                .role = msg.role,
                .content = msg.content,
            };
        }
        return messages;
    }
};

/// Lightweight message struct compatible with AI client expectations.
/// Used to pass side chain messages to the AI without importing client.zig.
pub const ChatMessageLike = struct {
    role: []const u8,
    content: []const u8,
};

// ── Tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "SideChainManager init/deinit" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();
    try testing.expectEqual(@as(usize, 0), mgr.chains.items.len);
    try testing.expectEqual(@as(u32, 1), mgr.next_id);
}

test "SideChainManager createChain adds system and user messages" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    const chain = try mgr.createChain(5, "How does auth work?", "some context here");
    try testing.expectEqual(@as(u32, 1), chain.id);
    try testing.expectEqual(@as(u32, 5), chain.parent_message_index);
    try testing.expectEqual(@as(usize, 2), chain.messages.items.len);
    try testing.expectEqual(SideChainStatus.active, chain.status);
    try testing.expect(std.mem.eql(u8, chain.messages.items[0].role, "system"));
    try testing.expect(std.mem.eql(u8, chain.messages.items[1].role, "user"));
    try testing.expect(std.mem.eql(u8, chain.messages.items[1].content, "How does auth work?"));
}

test "SideChainManager executeChain records response and generates summary" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "What is Zig?", "Zig context");
    try mgr.executeChain(1, "Zig is a systems programming language designed to be a better C.");

    const chain = mgr.getChain(1).?;
    try testing.expectEqual(@as(usize, 3), chain.messages.items.len);
    try testing.expectEqual(SideChainStatus.completed, chain.status);
    try testing.expect(chain.summary != null);
    if (chain.summary) |s| {
        try testing.expect(std.mem.indexOf(u8, s, "btw #1") != null);
        try testing.expect(std.mem.indexOf(u8, s, "What is Zig?") != null);
    }
}

test "SideChainManager summarizeChain truncates long responses" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "Explain everything", "context");
    const long_response = "A" ** 1000;
    try mgr.executeChain(1, long_response);

    const chain = mgr.getChain(1).?;
    try testing.expect(chain.summary != null);
    if (chain.summary) |s| {
        try testing.expect(s.len < 700); // summary should be truncated
    }
}

test "SideChainManager promoteChain returns full content" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "Test question", "context");
    try mgr.executeChain(1, "Test answer");

    const promoted = try mgr.promoteChain(1);
    defer testing.allocator.free(promoted);
    try testing.expect(std.mem.indexOf(u8, promoted, "Side Chain #1") != null);
    try testing.expect(std.mem.indexOf(u8, promoted, "Test question") != null);
    try testing.expect(std.mem.indexOf(u8, promoted, "Test answer") != null);

    const chain = mgr.getChain(1).?;
    try testing.expectEqual(SideChainStatus.promoted, chain.status);
}

test "SideChainManager getChain returns null for unknown id" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    try testing.expect(mgr.getChain(99) == null);
}

test "SideChainManager listChains formats output" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    const listing1 = try mgr.listChains();
    defer testing.allocator.free(listing1);
    try testing.expect(std.mem.indexOf(u8, listing1, "No side chains") != null);

    _ = try mgr.createChain(0, "First question", "ctx");
    _ = try mgr.createChain(1, "Second question", "ctx");

    const listing2 = try mgr.listChains();
    defer testing.allocator.free(listing2);
    try testing.expect(std.mem.indexOf(u8, listing2, "#1") != null);
    try testing.expect(std.mem.indexOf(u8, listing2, "#2") != null);
    try testing.expect(std.mem.indexOf(u8, listing2, "active") != null);
}

test "SideChainManager formatCompactSummary returns summary" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "Quick question", "ctx");
    try mgr.executeChain(1, "Quick answer");

    const summary = try mgr.formatCompactSummary(1);
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "btw #1") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "Quick question") != null);
}

test "SideChainManager auto-increments IDs" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    const c1 = try mgr.createChain(0, "Q1", "ctx");
    const c2 = try mgr.createChain(1, "Q2", "ctx");
    const c3 = try mgr.createChain(2, "Q3", "ctx");

    try testing.expectEqual(@as(u32, 1), c1.id);
    try testing.expectEqual(@as(u32, 2), c2.id);
    try testing.expectEqual(@as(u32, 3), c3.id);
    try testing.expectEqual(@as(u32, 4), mgr.next_id);
}

test "SideChainManager multiple chains tracked" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "Q1", "ctx1");
    _ = try mgr.createChain(1, "Q2", "ctx2");

    try testing.expectEqual(@as(usize, 2), mgr.chains.items.len);
    try testing.expect(mgr.getChain(1) != null);
    try testing.expect(mgr.getChain(2) != null);
}

test "SideChainManager buildChatMessages returns message array" {
    var mgr = SideChainManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createChain(0, "Test", "ctx");
    const messages = try mgr.buildChatMessages(1);
    defer testing.allocator.free(messages);
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expect(std.mem.eql(u8, messages[0].role, "system"));
    try testing.expect(std.mem.eql(u8, messages[1].role, "user"));
}
