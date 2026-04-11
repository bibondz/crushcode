const std = @import("std");
const types = @import("types.zig");

const StreamEvent = types.StreamEvent;
const TokenUsage = types.TokenUsage;
const StreamDone = types.StreamDone;
const StreamError = types.StreamError;

/// Response accumulator for collecting streaming chunks into a complete response
pub const ResponseBuffer = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    thinking_content: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCallAccumulator),
    finish_reason: ?[]const u8 = null,
    usage: ?TokenUsage = null,
    stream_error: ?StreamError = null,
    token_count: u32 = 0,

    /// Accumulator for multi-chunk tool calls
    pub const ToolCallAccumulator = struct {
        id: []const u8,
        name: []const u8,
        arguments: std.ArrayList(u8),
        completed: bool,
    };

    pub fn init(allocator: std.mem.Allocator) ResponseBuffer {
        return ResponseBuffer{
            .allocator = allocator,
            .content = std.ArrayList(u8).init(allocator),
            .thinking_content = std.ArrayList(u8).init(allocator),
            .tool_calls = std.ArrayList(ToolCallAccumulator).init(allocator),
        };
    }

    /// Process a stream event and accumulate into buffer
    pub fn processEvent(self: *ResponseBuffer, event: StreamEvent) void {
        switch (event.event_type) {
            .token => {
                self.content.appendSlice(event.token) catch {};
                self.token_count += 1;
            },
            .thinking => {
                self.thinking_content.appendSlice(event.thinking) catch {};
            },
            .tool_call => {
                const tc = event.tool_call;
                if (self.findToolCall(tc.index)) |existing| {
                    if (tc.arguments.len > 0) {
                        existing.arguments.appendSlice(tc.arguments) catch {};
                    }
                } else {
                    const accumulator = ToolCallAccumulator{
                        .id = self.allocator.dupe(u8, tc.id) catch "",
                        .name = self.allocator.dupe(u8, tc.name) catch "",
                        .arguments = blk: {
                            var list = std.ArrayList(u8).init(self.allocator);
                            if (tc.arguments.len > 0) list.appendSlice(tc.arguments) catch {};
                            break :blk list;
                        },
                        .completed = false,
                    };
                    self.tool_calls.append(accumulator) catch {};
                }
            },
            .tool_result => {
                const tr = event.tool_result;
                for (self.tool_calls.items) |*tc| {
                    if (std.mem.eql(u8, tc.id, tr.id)) {
                        tc.completed = true;
                        break;
                    }
                }
            },
            .done => {
                const done = event.done;
                if (done.finish_reason.len > 0) {
                    self.finish_reason = self.allocator.dupe(u8, done.finish_reason) catch null;
                }
                self.usage = done.usage;
            },
            .stream_error => {
                const err = event.stream_error;
                self.stream_error = StreamError{
                    .code = err.code,
                    .message = self.allocator.dupe(u8, err.message) catch "stream error",
                };
            },
        }
    }

    /// Find tool call accumulator by index
    fn findToolCall(self: *ResponseBuffer, index: u32) ?*ToolCallAccumulator {
        if (index < self.tool_calls.items.len) {
            return &self.tool_calls.items[index];
        }
        return null;
    }

    /// Get the full accumulated content as a string
    pub fn getFullContent(self: *const ResponseBuffer) []const u8 {
        return self.content.items;
    }

    /// Check if stream completed successfully
    pub fn isComplete(self: *const ResponseBuffer) bool {
        return self.finish_reason != null;
    }

    /// Check if stream had an error
    pub fn hasError(self: *const ResponseBuffer) bool {
        return self.stream_error != null;
    }

    pub fn deinit(self: *ResponseBuffer) void {
        self.content.deinit();
        self.thinking_content.deinit();
        for (self.tool_calls.items) |*tc| {
            if (tc.id.len > 0) self.allocator.free(tc.id);
            if (tc.name.len > 0) self.allocator.free(tc.name);
            tc.arguments.deinit();
        }
        self.tool_calls.deinit();
        if (self.finish_reason) |fr| self.allocator.free(fr);
    }
};
