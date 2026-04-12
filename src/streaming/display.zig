const std = @import("std");
const file_compat = @import("file_compat");
const types = @import("types");

const StreamEvent = types.StreamEvent;
const StreamEventType = types.StreamEventType;

/// Terminal display for real-time streaming output
pub const StreamDisplay = struct {
    allocator: std.mem.Allocator,
    show_thinking: bool,
    last_was_tool: bool,
    token_count: u32,

    pub fn init(allocator: std.mem.Allocator, show_thinking: bool) StreamDisplay {
        return StreamDisplay{
            .allocator = allocator,
            .show_thinking = show_thinking,
            .last_was_tool = false,
            .token_count = 0,
        };
    }

    /// Display a stream event to the terminal
    pub fn displayEvent(self: *StreamDisplay, event: StreamEvent) void {
        const stdout = file_compat.File.stdout().writer();

        switch (event.event_type) {
            .token => {
                if (self.last_was_tool) {
                    stdout.print("\n", .{}) catch {};
                    self.last_was_tool = false;
                }
                stdout.print("{s}", .{event.token}) catch {};
                self.token_count += 1;
            },
            .thinking => {
                if (self.show_thinking and event.thinking.len > 0) {
                    // Dim/italic style for thinking tokens
                    stdout.print("\x1b[2m{s}\x1b[0m", .{event.thinking}) catch {};
                }
            },
            .tool_call => {
                if (event.tool_call.name.len > 0) {
                    if (!self.last_was_tool) {
                        stdout.print("\n", .{}) catch {};
                    }
                    stdout.print("  \x1b[36m[tool: {s}]\x1b[0m", .{event.tool_call.name}) catch {};
                    self.last_was_tool = true;
                }
            },
            .tool_result => {
                // Brief indicator that tool completed
                if (event.tool_result.name.len > 0) {
                    stdout.print(" \x1b[32m✓\x1b[0m", .{}) catch {};
                }
            },
            .done => {
                if (self.last_was_tool) {
                    stdout.print("\n", .{}) catch {};
                    self.last_was_tool = false;
                }
                // Print usage summary if available
                if (event.done.usage) |usage| {
                    stdout.print("\n\x1b[2m({d} tokens in / {d} tokens out)\x1b[0m\n", .{
                        usage.input_tokens,
                        usage.output_tokens,
                    }) catch {};
                } else {
                    stdout.print("\n", .{}) catch {};
                }
            },
            .stream_error => {
                stdout.print("\n\x1b[31mStream error: {s}\x1b[0m\n", .{event.stream_error.message}) catch {};
            },
        }
    }

    /// Print streaming header
    pub fn printHeader(self: *StreamDisplay, provider: []const u8, model: []const u8) void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\x1b[2mStreaming from {s} ({s})...\x1b[0m\n", .{ provider, model }) catch {};
    }

    pub fn getTokenCount(self: *const StreamDisplay) u32 {
        return self.token_count;
    }
};
