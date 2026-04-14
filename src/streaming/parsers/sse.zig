const std = @import("std");
const array_list_compat = @import("array_list_compat");
const types = @import("types");

const StreamEvent = types.StreamEvent;
const TokenUsage = types.TokenUsage;
const StreamDone = types.StreamDone;
const StreamError = types.StreamError;

/// SSE (Server-Sent Events) parser for OpenAI, Anthropic, and OpenRouter
/// Format: lines starting with "data: " followed by JSON payload
/// Termination: "data: [DONE]"
pub const SSEParser = struct {
    allocator: std.mem.Allocator,
    partial_line: array_list_compat.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return SSEParser{
            .allocator = allocator,
            .partial_line = array_list_compat.ArrayList(u8).init(allocator),
        };
    }

    /// Parse a chunk of SSE data, returning events for complete messages
    pub fn parse(self: *SSEParser, chunk: []const u8) ![]StreamEvent {
        var events = array_list_compat.ArrayList(StreamEvent).init(self.allocator);
        errdefer events.deinit();

        try self.partial_line.appendSlice(chunk);

        // Process complete lines (delimited by \n)
        var start: usize = 0;
        for (self.partial_line.items, 0..) |byte, i| {
            if (byte == '\n') {
                const line = self.partial_line.items[start..i];
                // Trim \r for Windows line endings
                const trimmed = std.mem.trimRight(u8, line, "\r");
                if (trimmed.len > 0) {
                    if (self.parseLine(trimmed)) |event| {
                        try events.append(event);
                    }
                }
                start = i + 1;
            }
        }

        // Keep remaining partial line (shift left in-place, no extra allocation)
        if (start > 0) {
            const remaining = self.partial_line.items[start..];
            std.mem.copyForwards(u8, self.partial_line.items, remaining);
            self.partial_line.shrinkRetainingCapacity(remaining.len);
        }

        return events.toOwnedSlice();
    }

    /// Parse a single SSE line
    fn parseLine(self: *SSEParser, line: []const u8) ?StreamEvent {
        // SSE lines start with "data: " or "data:"
        const data_prefix = "data: ";
        const data_prefix_short = "data:";

        var json_data: ?[]const u8 = null;

        if (std.mem.startsWith(u8, line, data_prefix)) {
            json_data = line[data_prefix.len..];
        } else if (std.mem.startsWith(u8, line, data_prefix_short)) {
            json_data = line[data_prefix_short.len..];
        } else {
            // Not a data line (could be "event:", "id:", "retry:", or comment)
            return null;
        }

        const data = json_data.?;

        // Check for stream termination
        if (std.mem.eql(u8, data, "[DONE]")) {
            return StreamEvent.doneEvent(StreamDone{
                .finish_reason = "stop",
            });
        }

        // Try Anthropic format
        if (self.parseAnthropicFormat(data)) |event| {
            return event;
        }

        // Try OpenAI format
        if (self.parseOpenAIFormat(data)) |event| {
            return event;
        }

        return null;
    }

    /// Parse Anthropic SSE format
    /// event: content_block_delta
    /// data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"token"}}
    fn parseAnthropicFormat(self: *SSEParser, data: []const u8) ?StreamEvent {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        const event_type = root.object.get("type") orelse return null;
        if (event_type != .string) return null;
        const type_str = event_type.string;

        if (std.mem.eql(u8, type_str, "content_block_start")) {
            const content_block = root.object.get("content_block") orelse return null;
            if (content_block != .object) return null;

            const block_type = content_block.object.get("type") orelse return null;
            if (block_type != .string) return null;

            if (std.mem.eql(u8, block_type.string, "thinking")) {
                const text = content_block.object.get("thinking") orelse return null;
                if (text != .string) return null;
                if (text.string.len == 0) return null;
                return StreamEvent.thinkingEvent(text.string);
            }

            return null;
        }

        // Content delta — text tokens
        if (std.mem.eql(u8, type_str, "content_block_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;

            const delta_type = delta.object.get("type") orelse return null;
            if (delta_type != .string) return null;

            // Text delta
            if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                const text = delta.object.get("text") orelse return null;
                if (text != .string) return null;
                if (text.string.len == 0) return null;
                return StreamEvent.tokenEvent(text.string);
            }

            // Thinking delta
            if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                const text = delta.object.get("thinking") orelse return null;
                if (text != .string) return null;
                if (text.string.len == 0) return null;
                return StreamEvent.thinkingEvent(text.string);
            }

            return null;
        }

        // Tool use input delta
        if (std.mem.eql(u8, type_str, "input_json_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;
            const partial_json = delta.object.get("partial_json") orelse return null;
            if (partial_json != .string) return null;

            return StreamEvent.toolCallEvent(types.ToolCallStart{
                .arguments = partial_json.string,
            });
        }

        // Message start — contains usage
        if (std.mem.eql(u8, type_str, "message_start")) {
            // Initial usage from message_start — we don't emit events for this
            // but could track it for token counting
            return null;
        }

        // Message delta — contains final usage and stop reason
        if (std.mem.eql(u8, type_str, "message_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;

            const stop_reason = delta.object.get("stop_reason") orelse return null;
            if (stop_reason != .string) return null;

            var usage: ?TokenUsage = null;
            if (root.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    usage = TokenUsage{
                        .output_tokens = if (usage_val.object.get("output_tokens")) |ot| switch (ot) {
                            .integer => |v| @intCast(v),
                            else => 0,
                        } else 0,
                    };
                }
            }

            return StreamEvent.doneEvent(StreamDone{
                .finish_reason = stop_reason.string,
                .usage = usage,
            });
        }

        return null;
    }

    /// Parse OpenAI streaming format (same as in NDJSON but from SSE data)
    fn parseOpenAIFormat(self: *SSEParser, data: []const u8) ?StreamEvent {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        const choices = root.object.get("choices") orelse return null;
        if (choices != .array or choices.array.items.len == 0) return null;

        const first_choice = choices.array.items[0];
        if (first_choice != .object) return null;

        // Check finish_reason
        if (first_choice.object.get("finish_reason")) |fr| {
            const reason = switch (fr) {
                .string => |s| s,
                .null => "",
                else => "",
            };
            if (reason.len > 0 and !std.mem.eql(u8, reason, "null")) {
                var usage: ?TokenUsage = null;
                if (root.object.get("usage")) |usage_val| {
                    if (usage_val == .object) {
                        const pt = usage_val.object.get("prompt_tokens") orelse return null;
                        const ct = usage_val.object.get("completion_tokens") orelse return null;
                        usage = TokenUsage{
                            .input_tokens = switch (pt) {
                                .integer => |v| @intCast(v),
                                else => 0,
                            },
                            .output_tokens = switch (ct) {
                                .integer => |v| @intCast(v),
                                else => 0,
                            },
                        };
                    }
                }
                return StreamEvent.doneEvent(StreamDone{
                    .finish_reason = reason,
                    .usage = usage,
                });
            }
        }

        // Delta content
        const delta = first_choice.object.get("delta") orelse return null;
        if (delta != .object) return null;

        // Tool calls
        if (delta.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array and tool_calls.array.items.len > 0) {
                const tc = tool_calls.array.items[0];
                if (tc != .object) return null;

                const id = if (tc.object.get("id")) |id_val| switch (id_val) {
                    .string => |s| s,
                    else => "",
                } else "";

                const index: u32 = if (tc.object.get("index")) |idx| switch (idx) {
                    .integer => |v| @intCast(v),
                    else => 0,
                } else 0;

                const func = tc.object.get("function") orelse return null;
                if (func != .object) return null;

                const name = if (func.object.get("name")) |n| switch (n) {
                    .string => |s| s,
                    else => "",
                } else "";
                const args = if (func.object.get("arguments")) |a| switch (a) {
                    .string => |s| s,
                    else => "",
                } else "";

                return StreamEvent.toolCallEvent(types.ToolCallStart{
                    .id = id,
                    .name = name,
                    .arguments = args,
                    .index = index,
                });
            }
        }

        // Regular content
        if (delta.object.get("content")) |content_val| {
            const content = switch (content_val) {
                .string => |s| s,
                else => return null,
            };
            if (content.len == 0) return null;
            return StreamEvent.tokenEvent(content);
        }

        // Reasoning content
        if (delta.object.get("reasoning_content")) |reasoning| {
            const content = switch (reasoning) {
                .string => |s| s,
                else => return null,
            };
            if (content.len == 0) return null;
            return StreamEvent.thinkingEvent(content);
        }

        return null;
    }

    pub fn deinit(self: *SSEParser) void {
        self.partial_line.deinit();
    }
};
