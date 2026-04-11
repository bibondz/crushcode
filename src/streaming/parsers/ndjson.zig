const std = @import("std");
const types = @import("../types.zig");

const StreamEvent = types.StreamEvent;
const TokenUsage = types.TokenUsage;
const StreamDone = types.StreamDone;
const StreamError = types.StreamError;

/// NDJSON (Newline-Delimited JSON) parser for Ollama and similar providers
/// Each line is a complete JSON object followed by \n
pub const NDJsonParser = struct {
    allocator: std.mem.Allocator,
    partial_line: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) NDJsonParser {
        return NDJsonParser{
            .allocator = allocator,
            .partial_line = std.ArrayList(u8).init(allocator),
        };
    }

    /// Parse a chunk of NDJSON data, returning events for complete lines
    pub fn parse(self: *NDJsonParser, chunk: []const u8) ![]StreamEvent {
        var events = std.ArrayList(StreamEvent).init(self.allocator);
        errdefer {
            for (events.items) |_| {}
            events.deinit();
        }

        // Append chunk to partial line buffer
        try self.partial_line.appendSlice(chunk);

        // Process complete lines
        var start: usize = 0;
        for (self.partial_line.items, 0..) |byte, i| {
            if (byte == '\n') {
                const line = self.partial_line.items[start..i];
                if (line.len > 0) {
                    const event = self.parseLine(line) catch |err| {
                        if (err == error.EmptyLine) {
                            start = i + 1;
                            continue;
                        }
                        // Skip malformed lines
                        start = i + 1;
                        continue;
                    };
                    try events.append(event);
                }
                start = i + 1;
            }
        }

        // Keep remaining partial line
        if (start > 0) {
            const remaining = self.partial_line.items[start..];
            const kept = try self.allocator.dupe(u8, remaining);
            self.partial_line.clearRetainingCapacity();
            try self.partial_line.appendSlice(kept);
            self.allocator.free(kept);
        }

        return events.toOwnedSlice();
    }

    /// Parse a single NDJSON line into a StreamEvent
    fn parseLine(self: *NDJsonParser, line: []const u8) !StreamEvent {
        _ = self;

        // Try Ollama format first
        if (try parseOllamaFormat(line)) |event| {
            return event;
        }

        // Try generic OpenAI streaming format
        if (try parseOpenAIStreamFormat(line)) |event| {
            return event;
        }

        return error.EmptyLine;
    }

    /// Parse Ollama NDJSON format
    /// {"model":"...","message":{"role":"assistant","content":"token"},"done":false}
    fn parseOllamaFormat(line: []const u8) ?StreamEvent {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const root = parsed.value;

        // Check for Ollama format: has "message" and "done" fields
        const msg_obj = root.object.get("message") orelse return null;
        const done_val = root.object.get("done") orelse return null;

        const is_done = switch (done_val) {
            .bool => |b| b,
            else => false,
        };

        if (is_done) {
            // Extract usage if present
            var usage: ?TokenUsage = null;
            if (root.object.get("eval_count")) |eval_count| {
                if (root.object.get("prompt_eval_count")) |prompt_eval| {
                    usage = TokenUsage{
                        .input_tokens = switch (prompt_eval) {
                            .integer => |v| @intCast(v),
                            else => 0,
                        },
                        .output_tokens = switch (eval_count) {
                            .integer => |v| @intCast(v),
                            else => 0,
                        },
                    };
                }
            }
            return StreamEvent.doneEvent(StreamDone{
                .finish_reason = "stop",
                .usage = usage,
            });
        }

        // Extract content from message
        const content_val = msg_obj.object.get("content") orelse return null;
        const content = switch (content_val) {
            .string => |s| s,
            else => return null,
        };

        if (content.len == 0) return null;
        return StreamEvent.tokenEvent(content);
    }

    /// Parse OpenAI-compatible streaming format
    /// {"id":"...","choices":[{"delta":{"content":"token"}}]}
    fn parseOpenAIStreamFormat(line: []const u8) ?StreamEvent {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const root = parsed.value;

        // Check for OpenAI format: has "choices" array
        const choices = root.object.get("choices") orelse return null;
        if (choices != .array or choices.array.items.len == 0) return null;

        const first_choice = choices.array.items[0];

        // Check for finish_reason
        if (first_choice.object.get("finish_reason")) |fr| {
            const reason = switch (fr) {
                .string => |s| s,
                .null => "",
                else => "",
            };
            if (reason.len > 0 and !std.mem.eql(u8, reason, "null")) {
                var usage: ?TokenUsage = null;
                if (root.object.get("usage")) |usage_val| {
                    usage = parseOpenAIUsage(usage_val);
                }
                return StreamEvent.doneEvent(StreamDone{
                    .finish_reason = reason,
                    .usage = usage,
                });
            }
        }

        // Extract delta content
        const delta = first_choice.object.get("delta") orelse return null;

        // Check for tool calls in delta
        if (delta.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array and tool_calls.array.items.len > 0) {
                const tc = tool_calls.array.items[0];
                const id = if (tc.object.get("id")) |id_val| switch (id_val) {
                    .string => |s| s,
                    else => "",
                } else "";

                const func = tc.object.get("function") orelse return null;
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
                    .index = 0,
                });
            }
        }

        // Regular content delta
        if (delta.object.get("content")) |content_val| {
            const content = switch (content_val) {
                .string => |s| s,
                else => return null,
            };
            if (content.len == 0) return null;
            return StreamEvent.tokenEvent(content);
        }

        // Reasoning/thinking content
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

    fn parseOpenAIUsage(usage_val: std.json.Value) ?TokenUsage {
        if (usage_val != .object) return null;
        return TokenUsage{
            .input_tokens = usage_val.object.get("prompt_tokens") orelse return null,
            .output_tokens = usage_val.object.get("completion_tokens") orelse return null,
            .cache_read_tokens = blk: {
                const details = usage_val.object.get("prompt_tokens_details") orelse break :blk 0;
                if (details != .object) break :blk 0;
                const cached = details.object.get("cached_tokens") orelse break :blk 0;
                break :blk cached;
            },
        };
    }

    pub fn deinit(self: *NDJsonParser) void {
        self.partial_line.deinit();
    }
};
