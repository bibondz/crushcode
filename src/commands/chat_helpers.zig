const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const core = @import("core_api");
const color_mod = @import("color");
const summarizer_mod = @import("session_summarizer");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

const Style = color_mod.Style;

pub fn clampUsizeToU32(value: usize) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

pub fn clampU64ToU32(value: u64) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

pub fn freeLastMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator) void {
    const removed = messages.pop().?;
    freeChatMessage(removed, allocator);
}

pub fn freeToolCallInfos(tool_calls: ?[]const ai_types.ToolCallInfo, allocator: std.mem.Allocator) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

pub fn freeChatMessage(message: core.ChatMessage, allocator: std.mem.Allocator) void {
    allocator.free(message.role);
    if (message.content) |content| {
        allocator.free(content);
    }
    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }
    freeToolCallInfos(message.tool_calls, allocator);
}

pub fn rollbackMessagesTo(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, target_len: usize) void {
    while (messages.items.len > target_len) {
        freeLastMessage(messages, allocator);
    }
}

pub fn clearInteractiveHistory(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, total_input_tokens: *u64, total_output_tokens: *u64, request_count: *u32) void {
    for (messages.items) |msg| {
        freeChatMessage(msg, allocator);
    }
    messages.clearRetainingCapacity();
    total_input_tokens.* = 0;
    total_output_tokens.* = 0;
    request_count.* = 0;
}

pub fn printInteractiveSessionSummary(messages: []const core.ChatMessage, allocator: std.mem.Allocator, total_input_tokens: u64, total_output_tokens: u64) void {
    var summarizer = summarizer_mod.SessionSummarizer.init(allocator, 100);
    defer summarizer.deinit();

    for (messages) |msg| {
        const role: summarizer_mod.SessionEntry.Role = if (std.mem.eql(u8, msg.role, "user"))
            .user
        else if (std.mem.eql(u8, msg.role, "assistant"))
            .assistant
        else if (std.mem.eql(u8, msg.role, "system"))
            .system
        else
            .tool;
        summarizer.addEntry(role, msg.content orelse "", null) catch {};
    }

    if (summarizer.getEntries().len == 0) {
        return;
    }

    var summary = summarizer.summarize() catch return;
    defer summary.deinit();

    const total_tokens = if (summary.total_tokens > 0)
        summary.total_tokens
    else
        total_input_tokens + total_output_tokens;

    out("\n--- Session Summary ---\n", .{});
    out("  Messages: {d} user, {d} assistant, {d} tool calls\n", .{ summary.user_messages, summary.assistant_messages, summary.tool_calls });
    out("  Tokens: {d} total\n", .{total_tokens});
    out("  Duration: {d}s\n", .{summary.duration_seconds});
}

pub fn duplicateToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const ai_types.ToolCallInfo) !?[]const ai_types.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(ai_types.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

pub fn appendResponseMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, message: core.ChatMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, message.role),
        .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
        .tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = try duplicateToolCallInfos(allocator, message.tool_calls),
    });
}

pub fn elapsedMillis(start_ms: i64) u64 {
    const end_ms = std.time.milliTimestamp();
    if (end_ms <= start_ms) {
        return 0;
    }
    return @as(u64, @intCast(end_ms - start_ms));
}
