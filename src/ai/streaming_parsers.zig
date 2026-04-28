const std = @import("std");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const registry_mod = @import("registry");

pub const ChatMessage = ai_types.ChatMessage;
pub const ToolCallInfo = ai_types.ToolCallInfo;
pub const ChatResponse = ai_types.ChatResponse;
pub const ChatChoice = ai_types.ChatChoice;
pub const Usage = ai_types.Usage;
pub const StreamCallback = ai_types.StreamCallback;
pub const ApiFormat = registry_mod.ApiFormat;

pub threadlocal var active_show_thinking: bool = false;

pub const StreamingToolCall = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_fragments: array_list_compat.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) StreamingToolCall {
        return .{
            .id = null,
            .name = null,
            .arguments_fragments = array_list_compat.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StreamingToolCall, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.name) |name| allocator.free(name);
        for (self.arguments_fragments.items) |fragment| {
            allocator.free(fragment);
        }
        self.arguments_fragments.deinit();
    }
};

pub const StreamFormat = enum {
    ndjson,
    sse,
};

pub fn detectStreamingFormat(api_format: ApiFormat) StreamFormat {
    return switch (api_format) {
        .ollama => .ndjson,
        .openai, .anthropic, .google => .sse,
    };
}

pub fn jsonU32(value: ?std.json.Value) u32 {
    if (value) |v| {
        switch (v) {
            .integer => |n| {
                if (n > 0) {
                    return @intCast(n);
                }
            },
            else => {},
        }
    }
    return 0;
}

pub fn setFinishReason(allocator: std.mem.Allocator, finish_reason: *?[]const u8, reason: []const u8) !void {
    if (finish_reason.*) |existing| {
        allocator.free(existing);
    }
    finish_reason.* = try allocator.dupe(u8, reason);
}

pub fn appendStreamingToken(full_content: *array_list_compat.ArrayList(u8), token: []const u8, callback: StreamCallback) !void {
    if (token.len == 0) {
        return;
    }
    try full_content.appendSlice(token);
    callback(token, false);
}

pub fn appendThinkingToken(token: []const u8, callback: StreamCallback) void {
    if (!active_show_thinking or token.len == 0) {
        return;
    }

    callback("\x1b[2m", false);
    callback(token, false);
    callback("\x1b[0m", false);
}

pub fn markStreamDone(
    allocator: std.mem.Allocator,
    finish_reason: *?[]const u8,
    usage: *?Usage,
    reason: []const u8,
    maybe_usage: ?Usage,
    callback: StreamCallback,
    saw_done: *bool,
) !void {
    try setFinishReason(allocator, finish_reason, reason);
    if (maybe_usage) |stream_usage| {
        usage.* = stream_usage;
    }
    if (!saw_done.*) {
        saw_done.* = true;
        callback("", true);
    }
}

pub fn parseUsage(usage_value: std.json.Value) ?Usage {
    if (usage_value != .object) {
        return null;
    }

    const prompt_tokens = jsonU32(usage_value.object.get("prompt_tokens"));
    const completion_tokens = jsonU32(usage_value.object.get("completion_tokens"));

    return Usage{
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .total_tokens = prompt_tokens + completion_tokens,
    };
}

pub fn processOpenAIStreamingPayload(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    full_content: *array_list_compat.ArrayList(u8),
    finish_reason: *?[]const u8,
    usage: *?Usage,
    callback: StreamCallback,
    saw_done: *bool,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    if (root != .object) {
        return;
    }

    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) {
        return;
    }

    const first_choice = choices.array.items[0];
    if (first_choice != .object) {
        return;
    }

    if (first_choice.object.get("finish_reason")) |finish_value| {
        const reason = switch (finish_value) {
            .string => |s| s,
            .null => "",
            else => "",
        };

        if (reason.len > 0 and !std.mem.eql(u8, reason, "null")) {
            const parsed_usage = if (root.object.get("usage")) |usage_value|
                parseUsage(usage_value)
            else
                null;
            try markStreamDone(allocator, finish_reason, usage, reason, parsed_usage, callback, saw_done);
            return;
        }
    }

    const delta = first_choice.object.get("delta") orelse return;
    if (delta != .object) {
        return;
    }

    if (delta.object.get("tool_calls")) |tool_calls_value| {
        try processOpenAIToolCallDelta(allocator, tool_calls_value, streaming_tool_calls);
    }

    if (delta.object.get("content")) |content_value| {
        const token = switch (content_value) {
            .string => |s| s,
            else => return,
        };
        try appendStreamingToken(full_content, token, callback);
    }

    if (delta.object.get("reasoning_content")) |reasoning_value| {
        const token = switch (reasoning_value) {
            .string => |s| s,
            else => return,
        };
        appendThinkingToken(token, callback);
    }
}

pub fn processOpenAIToolCallDelta(
    allocator: std.mem.Allocator,
    tool_calls_value: std.json.Value,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    if (tool_calls_value != .array) {
        return;
    }

    for (tool_calls_value.array.items) |tool_call_value| {
        if (tool_call_value != .object) {
            continue;
        }

        const index_value = tool_call_value.object.get("index") orelse continue;
        const index = switch (index_value) {
            .integer => |value| if (value >= 0) @as(usize, @intCast(value)) else continue,
            else => continue,
        };

        while (streaming_tool_calls.items.len <= index) {
            try streaming_tool_calls.append(StreamingToolCall.init(allocator));
        }

        const slot = &streaming_tool_calls.items[index];

        if (tool_call_value.object.get("id")) |id_value| {
            if (id_value == .string) {
                if (slot.id) |existing| {
                    allocator.free(existing);
                }
                slot.id = try allocator.dupe(u8, id_value.string);
            }
        }

        if (tool_call_value.object.get("function")) |function_value| {
            if (function_value != .object) {
                continue;
            }

            if (function_value.object.get("name")) |name_value| {
                if (name_value == .string) {
                    if (slot.name) |existing| {
                        allocator.free(existing);
                    }
                    slot.name = try allocator.dupe(u8, name_value.string);
                }
            }

            if (function_value.object.get("arguments")) |arguments_value| {
                if (arguments_value == .string and arguments_value.string.len > 0) {
                    try slot.arguments_fragments.append(try allocator.dupe(u8, arguments_value.string));
                }
            }
        }
    }
}

pub fn processNDJSONLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    full_content: *array_list_compat.ArrayList(u8),
    finish_reason: *?[]const u8,
    usage: *?Usage,
    callback: StreamCallback,
    saw_done: *bool,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return;
    }

    const message_value = root.object.get("message");
    const done_value = root.object.get("done");
    if (message_value != null and done_value != null) {
        const is_done = switch (done_value.?) {
            .bool => |done| done,
            else => false,
        };

        if (is_done) {
            const prompt_tokens = jsonU32(root.object.get("prompt_eval_count"));
            const completion_tokens = jsonU32(root.object.get("eval_count"));
            const stream_usage = if (prompt_tokens > 0 or completion_tokens > 0)
                Usage{
                    .prompt_tokens = prompt_tokens,
                    .completion_tokens = completion_tokens,
                    .total_tokens = prompt_tokens + completion_tokens,
                }
            else
                null;
            try markStreamDone(allocator, finish_reason, usage, "stop", stream_usage, callback, saw_done);
            return;
        }

        if (message_value.? == .object) {
            if (message_value.?.object.get("content")) |content_value| {
                const token = switch (content_value) {
                    .string => |s| s,
                    else => return,
                };
                try appendStreamingToken(full_content, token, callback);
            }
        }
        return;
    }

    try processOpenAIStreamingPayload(allocator, root, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
}

pub fn processSSELine(
    allocator: std.mem.Allocator,
    line: []const u8,
    full_content: *array_list_compat.ArrayList(u8),
    finish_reason: *?[]const u8,
    usage: *?Usage,
    callback: StreamCallback,
    saw_done: *bool,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    const data = if (std.mem.startsWith(u8, line, "data: "))
        line["data: ".len..]
    else if (std.mem.startsWith(u8, line, "data:"))
        line["data:".len..]
    else
        return;

    if (std.mem.eql(u8, data, "[DONE]")) {
        try markStreamDone(allocator, finish_reason, usage, "stop", null, callback, saw_done);
        return;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return;
    }

    if (root.object.get("type")) |type_value| {
        if (type_value == .string) {
            const event_type = type_value.string;
            if (std.mem.eql(u8, event_type, "content_block_delta")) {
                const delta = root.object.get("delta") orelse return;
                if (delta != .object) {
                    return;
                }

                const delta_type = delta.object.get("type") orelse return;
                if (delta_type != .string) {
                    return;
                }

                if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                    const text = delta.object.get("text") orelse return;
                    const token = switch (text) {
                        .string => |s| s,
                        else => return,
                    };
                    try appendStreamingToken(full_content, token, callback);
                } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                    const thinking = delta.object.get("thinking") orelse return;
                    const token = switch (thinking) {
                        .string => |s| s,
                        else => return,
                    };
                    appendThinkingToken(token, callback);
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_start")) {
                const content_block = root.object.get("content_block") orelse return;
                if (content_block != .object) {
                    return;
                }

                const block_type = content_block.object.get("type") orelse return;
                if (block_type != .string or !std.mem.eql(u8, block_type.string, "thinking")) {
                    return;
                }

                const thinking = content_block.object.get("thinking") orelse return;
                const token = switch (thinking) {
                    .string => |s| s,
                    else => return,
                };
                appendThinkingToken(token, callback);
                return;
            }

            if (std.mem.eql(u8, event_type, "message_delta")) {
                const delta = root.object.get("delta") orelse return;
                if (delta != .object) {
                    return;
                }

                const stop_reason_value = delta.object.get("stop_reason") orelse return;
                const reason = switch (stop_reason_value) {
                    .string => |s| s,
                    else => return,
                };

                const stream_usage = if (root.object.get("usage")) |usage_value|
                    Usage{
                        .prompt_tokens = 0,
                        .completion_tokens = jsonU32(usage_value.object.get("output_tokens")),
                        .total_tokens = jsonU32(usage_value.object.get("output_tokens")),
                    }
                else
                    null;

                try markStreamDone(allocator, finish_reason, usage, reason, stream_usage, callback, saw_done);
                return;
            }
        }
    }

    try processOpenAIStreamingPayload(allocator, root, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
}

pub fn processStreamLine(
    allocator: std.mem.Allocator,
    api_format: ApiFormat,
    line: []const u8,
    full_content: *array_list_compat.ArrayList(u8),
    finish_reason: *?[]const u8,
    usage: *?Usage,
    callback: StreamCallback,
    saw_done: *bool,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    if (line.len == 0) {
        return;
    }

    const trimmed = std.mem.trimRight(u8, line, "\r");
    if (trimmed.len == 0) {
        return;
    }

    switch (detectStreamingFormat(api_format)) {
        .ndjson => try processNDJSONLine(allocator, trimmed, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls),
        .sse => try processSSELine(allocator, trimmed, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls),
    }
}

pub fn processStreamChunk(
    allocator: std.mem.Allocator,
    api_format: ApiFormat,
    partial_line: *array_list_compat.ArrayList(u8),
    chunk: []const u8,
    full_content: *array_list_compat.ArrayList(u8),
    finish_reason: *?[]const u8,
    usage: *?Usage,
    callback: StreamCallback,
    saw_done: *bool,
    streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
) !void {
    try partial_line.appendSlice(chunk);

    var start: usize = 0;
    for (partial_line.items, 0..) |byte, i| {
        if (byte == '\n') {
            try processStreamLine(allocator, api_format, partial_line.items[start..i], full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
            start = i + 1;
        }
    }

    if (start > 0) {
        const remaining = partial_line.items[start..];
        const kept = try allocator.dupe(u8, remaining);
        defer allocator.free(kept);
        partial_line.clearRetainingCapacity();
        try partial_line.appendSlice(kept);
    }
}

pub fn appendEscapedJsonString(json_body: *array_list_compat.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try json_body.appendSlice("\\\""),
            '\\' => try json_body.appendSlice("\\\\"),
            '\n' => try json_body.appendSlice("\\n"),
            '\r' => try json_body.appendSlice("\\r"),
            '\t' => try json_body.appendSlice("\\t"),
            else => {
                // Escape all other control characters (0x00-0x1F) as \uXXXX
                // JSON spec requires control chars to be escaped
                if (c < 0x20) {
                    try json_body.writer().print("\\u{d:0>4}", .{c});
                } else {
                    try json_body.append(c);
                }
            },
        }
    }
}

pub fn appendToolCallJson(json_body: *array_list_compat.ArrayList(u8), tool_call: ToolCallInfo) !void {
    try json_body.appendSlice("{\"id\":\"");
    try appendEscapedJsonString(json_body, tool_call.id);
    try json_body.appendSlice("\",\"type\":\"function\",\"function\":{\"name\":\"");
    try appendEscapedJsonString(json_body, tool_call.name);
    try json_body.appendSlice("\",\"arguments\":\"");
    try appendEscapedJsonString(json_body, tool_call.arguments);
    try json_body.appendSlice("\"}}");
}

pub fn appendChatMessageJson(json_body: *array_list_compat.ArrayList(u8), msg: ChatMessage) !void {
    try json_body.appendSlice("{\"role\":\"");
    try appendEscapedJsonString(json_body, msg.role);
    try json_body.appendSlice("\"");

    if (msg.tool_call_id) |tool_call_id| {
        try json_body.appendSlice(",\"tool_call_id\":\"");
        try appendEscapedJsonString(json_body, tool_call_id);
        try json_body.appendSlice("\"");
    }

    if (msg.content) |content| {
        try json_body.appendSlice(",\"content\":\"");
        try appendEscapedJsonString(json_body, content);
        try json_body.appendSlice("\"");
    } else {
        try json_body.appendSlice(",\"content\":null");
    }

    if (msg.tool_calls) |tool_calls| {
        try json_body.appendSlice(",\"tool_calls\":[");
        for (tool_calls, 0..) |tool_call, i| {
            if (i > 0) {
                try json_body.appendSlice(",");
            }
            try appendToolCallJson(json_body, tool_call);
        }
        try json_body.appendSlice("]");
    }

    try json_body.appendSlice("}");
}

pub fn buildStreamingBodyFromMessages(
    allocator: std.mem.Allocator,
    api_model_name: []const u8,
    system_prompt: ?[]const u8,
    messages: []const ChatMessage,
    tools_json: []const u8,
    api_format: ApiFormat,
    max_tokens: u32,
    temperature: f32,
) ![]const u8 {
    var json_body = array_list_compat.ArrayList(u8).init(allocator);
    defer json_body.deinit();

    try json_body.appendSlice("{\"model\":\"");
    try json_body.appendSlice(api_model_name);
    try json_body.appendSlice("\",\"messages\":[");

    var needs_comma = false;
    if (system_prompt) |sys_prompt| {
        if (sys_prompt.len > 0) {
            try json_body.appendSlice("{\"role\":\"system\",\"content\":\"");
            try appendEscapedJsonString(&json_body, sys_prompt);
            try json_body.appendSlice("\"}");
            needs_comma = true;
        }
    }

    for (messages) |msg| {
        if (needs_comma) {
            try json_body.appendSlice(",");
        }
        try appendChatMessageJson(&json_body, msg);
        needs_comma = true;
    }

    try json_body.writer().print("],\"max_tokens\":{d},\"temperature\":{d:.2}", .{ max_tokens, temperature });
    if (tools_json.len > 0) {
        try json_body.appendSlice(tools_json);
    }
    if (api_format != .ollama) {
        try json_body.appendSlice(",\"stream\":true");
    }
    try json_body.appendSlice("}");

    return allocator.dupe(u8, json_body.items);
}

/// Build a streaming request body with Anthropic cache_control breakpoints.
/// cache_marks is a parallel array to messages where true = add ephemeral cache marker.
pub fn buildCacheAwareStreamingBody(
    allocator: std.mem.Allocator,
    api_model_name: []const u8,
    system_prompt: ?[]const u8,
    messages: []const ChatMessage,
    tools_json: []const u8,
    max_tokens: u32,
    temperature: f32,
    cache_marks: []const bool,
) ![]const u8 {
    var json_body = array_list_compat.ArrayList(u8).init(allocator);
    defer json_body.deinit();

    try json_body.appendSlice("{\"model\":\"");
    try json_body.appendSlice(api_model_name);
    try json_body.appendSlice("\",\"messages\":[");

    var needs_comma = false;

    // System prompt — mark as cacheable if first cache_mark is true
    if (system_prompt) |sys_prompt| {
        if (sys_prompt.len > 0) {
            try json_body.appendSlice("{\"role\":\"system\",\"content\":\"");
            try appendEscapedJsonString(&json_body, sys_prompt);
            try json_body.appendSlice("\"");
            if (cache_marks.len > 0 and cache_marks[0]) {
                try json_body.appendSlice(",\"cache_control\":{\"type\":\"ephemeral\"}");
            }
            try json_body.appendSlice("}");
            needs_comma = true;
        }
    }

    for (messages, 0..) |msg, i| {
        if (needs_comma) {
            try json_body.appendSlice(",");
        }
        try appendChatMessageJson(&json_body, msg);
        // Inject cache_control before the closing brace
        const mark_idx = i + 1; // offset by 1 for system prompt
        if (mark_idx < cache_marks.len and cache_marks[mark_idx]) {
            // Remove trailing '}' and add cache_control before it
            if (json_body.items.len > 0 and json_body.items[json_body.items.len - 1] == '}') {
                _ = json_body.pop();
            }
            try json_body.appendSlice(",\"cache_control\":{\"type\":\"ephemeral\"}}");
        }
        needs_comma = true;
    }

    try json_body.writer().print("],\"max_tokens\":{d},\"temperature\":{d:.2}", .{ max_tokens, temperature });
    if (tools_json.len > 0) {
        try json_body.appendSlice(tools_json);
    }
    try json_body.appendSlice(",\"stream\":true}");

    return allocator.dupe(u8, json_body.items);
}

pub fn buildStreamingResponse(
    allocator: std.mem.Allocator,
    model: []const u8,
    provider_name: []const u8,
    content_slice: []const u8,
    final_finish_reason: []const u8,
    usage: ?Usage,
    streaming_tool_calls: []const StreamingToolCall,
) !ChatResponse {
    const content = try allocator.dupe(u8, content_slice);
    errdefer allocator.free(content);

    const role = try allocator.dupe(u8, "assistant");
    errdefer allocator.free(role);

    const finish_reason = try allocator.dupe(u8, final_finish_reason);
    errdefer allocator.free(finish_reason);

    const choices = try allocator.alloc(ChatChoice, 1);
    errdefer allocator.free(choices);

    choices[0] = .{
        .index = 0,
        .message = .{
            .role = role,
            .content = content,
            .tool_call_id = null,
            .tool_calls = try cloneStreamingToolCalls(allocator, streaming_tool_calls),
        },
        .finish_reason = finish_reason,
    };

    return ChatResponse{
        .id = try allocator.dupe(u8, "streaming-response"),
        .object = try allocator.dupe(u8, "chat.completion"),
        .created = @intCast(std.time.timestamp()),
        .model = try allocator.dupe(u8, model),
        .choices = choices,
        .usage = usage,
        .provider = try allocator.dupe(u8, provider_name),
        .cost = null,
        .system_fingerprint = null,
    };
}

pub fn cloneToolCallInfosFromAPI(allocator: std.mem.Allocator, tool_calls: anytype) !?[]const ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.function.name),
            .arguments = try allocator.dupe(u8, tool_call.function.arguments),
        };
    }
    return copied;
}

pub fn cloneStreamingToolCalls(allocator: std.mem.Allocator, tool_calls: []const StreamingToolCall) !?[]const ToolCallInfo {
    if (tool_calls.len == 0) {
        return null;
    }

    const copied = try allocator.alloc(ToolCallInfo, tool_calls.len);
    for (tool_calls, 0..) |tool_call, i| {
        var arguments = array_list_compat.ArrayList(u8).init(allocator);
        defer arguments.deinit();

        for (tool_call.arguments_fragments.items) |fragment| {
            try arguments.appendSlice(fragment);
        }

        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id orelse ""),
            .name = try allocator.dupe(u8, tool_call.name orelse ""),
            .arguments = try allocator.dupe(u8, arguments.items),
        };
    }
    return copied;
}
