// src/tui/model/helpers.zig
// Free helper functions extracted from chat_tui_app.zig
// These functions have minimal coupling to the Model struct.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;
const Message = chat_tui_app.Message;
const SurfaceWidget = chat_tui_app.SurfaceWidget;

// Import dependencies used by the extracted functions
const core = @import("core_api");
const theme_mod = @import("theme");
const widget_types = @import("widget_types");
const ToolCallStatus = widget_types.ToolCallStatus;
const tool_executors = @import("chat_tool_executors");

// Constants from widget_types
const recent_files_display_max = widget_types.recent_files_display_max;
const tool_diff_max_lines = widget_types.tool_diff_max_lines;
const recent_file_tool_names = widget_types.recent_file_tool_names;

pub fn shouldRenderMessageContent(message: *const Message) bool {
    return message.content.len > 0 or message.tool_calls == null;
}

pub fn toolCallStatusIcon(status: ToolCallStatus) []const u8 {
    return switch (status) {
        .pending => "●",
        .success => "✓",
        .failed => "×",
    };
}

pub fn toolCallStatusStyle(theme: *const theme_mod.Theme, status: ToolCallStatus) vaxis.Style {
    return switch (status) {
        .pending => .{ .fg = theme.tool_pending, .bold = true },
        .success => .{ .fg = theme.tool_success, .bold = true },
        .failed => .{ .fg = theme.tool_error, .bold = true },
    };
}

pub fn toolCallStatusForMessage(message: ?*const Message) ToolCallStatus {
    const result = message orelse return .pending;
    if (std.mem.eql(u8, result.role, "error")) return .failed;

    const trimmed = std.mem.trim(u8, result.content, " \t\r\n");
    if (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "error:")) {
        return .failed;
    }
    return .success;
}

pub fn toolCallOutputText(allocator: std.mem.Allocator, output: ?[]const u8, status: ToolCallStatus) ![]const u8 {
    const text = output orelse {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    };
    if (text.len == 0) {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    }

    var builder = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    var remaining: usize = 0;
    while (lines.next()) |line| {
        if (line_count < 5) {
            if (line_count > 0) try builder.append(allocator, '\n');
            try builder.appendSlice(allocator, "  ");
            try builder.appendSlice(allocator, line);
        } else {
            remaining += 1;
        }
        line_count += 1;
    }
    if (remaining > 0) {
        if (builder.items.len > 0) try builder.append(allocator, '\n');
        try builder.writer(allocator).print("  and {d} more lines...", .{remaining});
    }
    return builder.toOwnedSlice(allocator);
}

pub fn findToolCallBefore(messages: []const Message, before_index: usize, tool_call_id: []const u8) ?core.client.ToolCallInfo {
    var idx = before_index;
    while (idx > 0) {
        idx -= 1;
        if (messages[idx].tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.id, tool_call_id)) return tool_call;
            }
        }
    }
    return null;
}

pub fn findToolResultMessageAfter(messages: []const Message, after_index: usize, tool_call_id: []const u8) ?*const Message {
    var idx = after_index + 1;
    while (idx < messages.len) : (idx += 1) {
        const message = &messages[idx];
        if (message.tool_call_id) |message_tool_call_id| {
            if (std.mem.eql(u8, message_tool_call_id, tool_call_id)) return message;
        }
    }
    return null;
}

pub fn visibleMessageCount(messages: []const Message) usize {
    var count: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
        count += 1;
    }
    return count;
}

pub fn messageRoleStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.assistant_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .bold = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .bold = true };
    }
    return .{ .fg = theme.dimmed, .bold = true };
}

pub fn messageBodyStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.header_fg };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .dim = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .dim = true };
    }
    return .{ .fg = theme.dimmed, .dim = true };
}

pub fn messageRoleLabel(theme: *const theme_mod.Theme, role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return theme.user_label;
    if (std.mem.eql(u8, role, "assistant")) return theme.assistant_label;
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return role;
}

pub fn estimateContentHeight(model: *const Model) ?u32 {
    var total: u32 = 0;
    const messages = model.messages.items;
    const visible_count = visibleMessageCount(messages);
    var visible_index: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;

        if (shouldRenderMessageContent(&message)) {
            total += @intCast(1 + std.mem.count(u8, message.content, "\n"));
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += 1;
                if (tool_call.arguments.len > 0) total += @intCast(std.mem.count(u8, tool_call.arguments, "\n"));
                const result = findToolResultMessageAfter(messages, idx, tool_call.id);
                const output = result orelse null;
                const output_text = if (output) |message_result| message_result.content else if (toolCallStatusForMessage(result) == .pending) "running..." else "";
                if (isDiffRenderableTool(tool_call.name) and extractToolDiffText(output_text) != null) {
                    total += @as(u32, @intCast(@min(std.mem.count(u8, output_text, "\n") + 4, tool_diff_max_lines + 4)));
                } else if (output_text.len > 0) {
                    total += @intCast(@min(std.mem.count(u8, output_text, "\n") + 1, 6));
                }
            }
        }

        visible_index += 1;
        if (visible_index < visible_count) total += 2;
    }
    return total;
}

pub fn drawBorder(surface: *vxfw.Surface, style: vaxis.Style) void {
    const width = surface.size.width;
    const height = surface.size.height;
    if (width == 0 or height == 0) return;

    const horizontal: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style };
    const vertical: vaxis.Cell = .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style };
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    surface.writeCell(0, height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(width - 1, height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });

    if (width > 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), 0, horizontal);
            surface.writeCell(@intCast(col), height - 1, horizontal);
        }
    }
    if (height > 2) {
        for (1..height - 1) |row| {
            surface.writeCell(0, @intCast(row), vertical);
            surface.writeCell(width - 1, @intCast(row), vertical);
        }
    }
}

pub fn estimateTextTokens(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return @intCast(@divFloor(text.len + 3, 4));
}

pub fn estimateMessageTokens(messages: []const core.ChatMessage) u64 {
    var total: u64 = 0;
    for (messages) |message| {
        total += estimateTextTokens(message.role);
        if (message.content) |content| {
            total += estimateTextTokens(content);
        }
        if (message.tool_call_id) |tool_call_id| {
            total += estimateTextTokens(tool_call_id);
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += estimateTextTokens(tool_call.id);
                total += estimateTextTokens(tool_call.name);
                total += estimateTextTokens(tool_call.arguments);
            }
        }
    }
    return total;
}

pub fn repeated(allocator: std.mem.Allocator, token: []const u8, count: u16) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try buffer.ensureTotalCapacity(allocator, token.len * count);
    for (0..count) |_| {
        try buffer.appendSlice(allocator, token);
    }
    return buffer.toOwnedSlice(allocator);
}

pub fn recentFilesDisplay(files: []const []const u8) []const []const u8 {
    return files[0..@min(files.len, recent_files_display_max)];
}

pub fn isRecentFileTool(name: []const u8) bool {
    for (recent_file_tool_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub fn isDiffRenderableTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit");
}

pub fn extractToolDiffText(output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "```diff")) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "@@")) return trimmed;
    return null;
}

pub fn extractToolFilePath(arguments: []const u8) ?[]const u8 {
    inline for (.{ "path", "file_path" }) |key| {
        if (std.mem.indexOf(u8, arguments, std.fmt.comptimePrint("\"{s}\"", .{key}))) |key_index| {
            const colon = std.mem.indexOfPos(u8, arguments, key_index, ":") orelse return null;
            var start = colon + 1;
            while (start < arguments.len and std.ascii.isWhitespace(arguments[start])) : (start += 1) {}
            if (start >= arguments.len or arguments[start] != '"') return null;
            start += 1;
            const end = std.mem.indexOfScalarPos(u8, arguments, start, '"') orelse return null;
            return arguments[start..end];
        }
    }
    return null;
}

pub fn recentFilesVisibleCount(files: []const []const u8) usize {
    return @min(files.len, recent_files_display_max);
}

pub fn contentSurfaceWidget(allocator: std.mem.Allocator, surface: vxfw.Surface) !vxfw.Widget {
    const widget_holder = try allocator.create(SurfaceWidget);
    widget_holder.* = .{ .surface = surface };
    return widget_holder.widget();
}

pub fn resolvedPricingModel(model: *const Model) []const u8 {
    if (model.pricing_table.getPrice(model.provider_name, model.model_name) != null) {
        return model.model_name;
    }
    return "default";
}

pub fn spinnerFrame() []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const tick = @divFloor(std.time.milliTimestamp(), 120);
    return frames[@as(usize, @intCast(@mod(tick, frames.len)))];
}

pub fn estimateResponseOutputTokens(content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) u64 {
    var total = estimateTextTokens(content);
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            total += estimateTextTokens(tool_call.name);
            total += estimateTextTokens(tool_call.arguments);
        }
    }
    return total;
}

pub fn isRetryableProviderError(err: anyerror) bool {
    return switch (err) {
        error.NetworkError, error.TimeoutError, error.ServerError, error.RetryExhausted => true,
        else => false,
    };
}

pub fn executeInlineTool(allocator: std.mem.Allocator, tool_call: core.client.ToolCallInfo) ![]const u8 {
    const parsed = core.ParsedToolCall{
        .id = tool_call.id,
        .name = tool_call.name,
        .arguments = tool_call.arguments,
    };
    const execution = try tool_executors.executeBuiltinTool(allocator, parsed);
    defer allocator.free(execution.display);
    return allocator.dupe(u8, execution.result);
}

pub fn freeToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

pub fn cloneToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) !?[]const core.client.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(core.client.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

pub fn freeDisplayMessage(allocator: std.mem.Allocator, message: Message) void {
    allocator.free(message.role);
    allocator.free(message.content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

pub fn freeChatMessage(allocator: std.mem.Allocator, message: core.ChatMessage) void {
    allocator.free(message.role);
    if (message.content) |content| allocator.free(content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

pub fn freeChatResponse(allocator: std.mem.Allocator, response: *core.ChatResponse) void {
    allocator.free(response.id);
    allocator.free(response.object);
    allocator.free(response.model);
    for (response.choices) |choice| {
        freeChatMessage(allocator, choice.message);
        if (choice.finish_reason) |finish_reason| allocator.free(finish_reason);
    }
    allocator.free(response.choices);
    if (response.provider) |provider| allocator.free(provider);
    if (response.cost) |cost| allocator.free(cost);
    if (response.system_fingerprint) |system_fingerprint| allocator.free(system_fingerprint);
}

/// Find the first occurrence of `symbol` in file content as a whole word, returning 0-based line/character.
pub fn findSymbolPosition(content: []const u8, symbol: []const u8) ?struct { line: u32, character: u32 } {
    if (symbol.len == 0 or content.len == 0) return null;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line += 1;
            col = 0;
            continue;
        }
        if (i + symbol.len <= content.len and std.mem.eql(u8, content[i .. i + symbol.len], symbol)) {
            const before_ok = i == 0 or !std.ascii.isAlphanumeric(content[i - 1]) and content[i - 1] != '_';
            const after_idx = i + symbol.len;
            const after_ok = after_idx >= content.len or !std.ascii.isAlphanumeric(content[after_idx]) and content[after_idx] != '_';
            if (before_ok and after_ok) {
                return .{ .line = line, .character = col };
            }
        }
        col += 1;
    }
    return null;
}

/// Strip "file://" or "file:///" prefix from a URI for display.
pub fn stripFileUriPrefix(uri: []const u8) []const u8 {
    if (std.mem.startsWith(u8, uri, "file:///")) {
        return uri["file:///".len..];
    }
    if (std.mem.startsWith(u8, uri, "file://")) {
        return uri["file://".len..];
    }
    return uri;
}
