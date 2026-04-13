/// JSON Lines output emitter for machine-readable crushcode output.
/// Inspired by ripgrep's --json format: one JSON object per line.
///
/// Event types:
///   session_start  — session metadata (provider, model)
///   message_start  — user message sent
///   assistant      — assistant response chunk
///   tool_call      — AI requests tool execution
///   tool_result    — tool execution result
///   usage          — token usage for this request
///   error          — error occurred
///   session_end    — session finished
const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

pub const JsonOutput = struct {
    enabled: bool,

    pub fn init(enabled: bool) JsonOutput {
        return .{
            .enabled = enabled,
        };
    }

    /// Emit a session_start event with provider and model info.
    pub fn emitSessionStart(self: JsonOutput, provider: []const u8, model: []const u8) void {
        if (!self.enabled) return;
        self.writeEvent("session_start", provider, model, "", "", 0, 0, 0);
    }

    /// Emit a message_start event with the user's message.
    pub fn emitMessageStart(self: JsonOutput, role: []const u8, content: []const u8) void {
        if (!self.enabled) return;
        self.writeEvent("message_start", "", "", role, content, 0, 0, 0);
    }

    /// Emit an assistant response event.
    pub fn emitAssistant(self: JsonOutput, content: []const u8) void {
        if (!self.enabled) return;
        self.writeEvent("assistant", "", "", "", content, 0, 0, 0);
    }

    /// Emit a tool_call event when the AI requests tool execution.
    pub fn emitToolCall(self: JsonOutput, tool_name: []const u8, tool_id: []const u8, arguments: []const u8) void {
        if (!self.enabled) return;
        // Simple JSON — skip argument content to avoid escaping complexity
        _ = arguments;
        const stdout = file_compat.File.stdout();
        stdout.print(
            \\{{"type":"tool_call","data":{{"tool_name":"{s}","tool_id":"{s}"}}}}
            \\
        , .{ tool_name, tool_id }) catch {};
    }

    /// Emit a tool_result event after tool execution completes.
    pub fn emitToolResult(self: JsonOutput, tool_id: []const u8, output: []const u8, success: bool) void {
        if (!self.enabled) return;
        _ = output;
        const status = if (success) "true" else "false";
        const stdout = file_compat.File.stdout();
        stdout.print(
            \\{{"type":"tool_result","data":{{"tool_id":"{s}","success":{s}}}}}
            \\
        , .{ tool_id, status }) catch {};
    }

    /// Emit a usage event with token counts.
    pub fn emitUsage(self: JsonOutput, input_tokens: u64, output_tokens: u64, total_tokens: u64) void {
        if (!self.enabled) return;
        self.writeEvent("usage", "", "", "", "", input_tokens, output_tokens, total_tokens);
    }

    /// Emit an error event.
    pub fn emitError(self: JsonOutput, message: []const u8) void {
        if (!self.enabled) return;
        const stdout = file_compat.File.stdout();
        stdout.print(
            \\{{"type":"error","data":{{"message":"{s}"}}}}
            \\
        , .{message}) catch {};
    }

    /// Emit a session_end event.
    pub fn emitSessionEnd(self: JsonOutput) void {
        if (!self.enabled) return;
        self.writeEvent("session_end", "", "", "", "", 0, 0, 0);
    }

    /// Internal: write a JSON Lines event to stdout.
    /// Uses a flat parameter list to avoid allocating anonymous structs.
    fn writeEvent(
        self: JsonOutput,
        event_type: []const u8,
        provider: []const u8,
        model: []const u8,
        role: []const u8,
        content: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        total_tokens: u64,
    ) void {
        if (!self.enabled) return;
        const stdout = file_compat.File.stdout();
        const allocator = std.heap.page_allocator;

        // Build data object based on event type
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        w.writeAll("{\"type\":\"") catch return;
        w.writeAll(event_type) catch return;
        w.writeAll("\",\"data\":{") catch return;

        var first = true;

        if (provider.len > 0) {
            if (!first) w.writeAll(",") catch return;
            w.print("\"provider\":\"{s}\"", .{provider}) catch return;
            first = false;
        }
        if (model.len > 0) {
            if (!first) w.writeAll(",") catch return;
            w.print("\"model\":\"{s}\"", .{model}) catch return;
            first = false;
        }
        if (role.len > 0) {
            if (!first) w.writeAll(",") catch return;
            w.print("\"role\":\"{s}\"", .{role}) catch return;
            first = false;
        }
        if (content.len > 0) {
            if (!first) w.writeAll(",") catch return;
            // Truncate content to 8KB for JSON output to avoid massive lines
            const max_content = @min(content.len, 8192);
            w.print("\"content\":\"{s}\"", .{content[0..max_content]}) catch return;
            first = false;
        }
        if (total_tokens > 0) {
            if (!first) w.writeAll(",") catch return;
            w.print("\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d}", .{ input_tokens, output_tokens, total_tokens }) catch return;
            first = false;
        }

        w.writeAll("}}\n") catch return;

        // Write to stdout — BrokenPipe is acceptable (consumer closed pipe)
        stdout.writeAll(buf.items) catch {};
    }
};
