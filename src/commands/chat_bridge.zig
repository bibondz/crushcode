const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const core = @import("core_api");
const agent_loop_mod = @import("agent_loop");
const lifecycle_hooks_mod = @import("lifecycle_hooks");
const spinner_mod = @import("spinner");
const markdown_mod = @import("markdown_renderer");
const error_display_mod = @import("error_display");
const json_output_mod = @import("json_output");
const color_mod = @import("color");
const chat_helpers = @import("chat_helpers");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

const HookContext = lifecycle_hooks_mod.HookContext;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;
const AIResponse = agent_loop_mod.AIResponse;
const LoopMessage = agent_loop_mod.LoopMessage;
const Style = color_mod.Style;

pub const InteractiveBridgeContext = struct {
    allocator: std.mem.Allocator,
    client: *core.AIClient,
    messages: *array_list_compat.ArrayList(core.ChatMessage),
    hooks: *LifecycleHooks,
    provider_name: []const u8,
    model_name: []const u8,
    turn_start_len: usize,
    synced_loop_messages: usize,
    turn_request_count: u32,
    turn_failed: bool,
    total_input_tokens: *u64,
    total_output_tokens: *u64,
    request_count: *u32,
    request_arena: std.heap.ArenaAllocator,
    json_out: json_output_mod.JsonOutput,
};

pub threadlocal var active_bridge_context: ?*InteractiveBridgeContext = null;
pub threadlocal var active_streaming_enabled: bool = false;
pub threadlocal var active_show_thinking: bool = false;

pub fn appendLoopHistoryMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, loop_message: LoopMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, loop_message.role),
        .content = if (loop_message.content.len > 0) try allocator.dupe(u8, loop_message.content) else null,
        .tool_call_id = if (loop_message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = null,
    });
}

pub fn syncLoopMessagesToOuterHistory(ctx: *InteractiveBridgeContext, loop_messages: []const LoopMessage) !void {
    while (ctx.synced_loop_messages < loop_messages.len) : (ctx.synced_loop_messages += 1) {
        const loop_message = loop_messages[ctx.synced_loop_messages];
        if (std.mem.eql(u8, loop_message.role, "assistant")) {
            continue;
        }
        try appendLoopHistoryMessage(ctx.messages, ctx.allocator, loop_message);
    }
}

pub fn interactiveStreamCallback(token: []const u8, done: bool) void {
    _ = done;
    if (token.len == 0) {
        return;
    }

    const stdout = file_compat.File.stdout().writer();
    stdout.print("{s}", .{token}) catch {};
}

pub fn sendInteractiveLoopMessages(allocator: std.mem.Allocator, loop_messages: []const LoopMessage) anyerror!AIResponse {
    _ = ai_types;
    const ctx = active_bridge_context orelse return error.MissingBridgeContext;

    _ = ctx.request_arena.reset(.retain_capacity);
    const arena = ctx.request_arena.allocator();

    try syncLoopMessagesToOuterHistory(ctx, loop_messages);

    const last_content_len = if (ctx.messages.items.len == 0)
        0
    else
        (ctx.messages.items[ctx.messages.items.len - 1].content orelse "").len;

    var pre_request_ctx = HookContext.init(arena);
    defer pre_request_ctx.deinit();
    pre_request_ctx.phase = .pre_request;
    pre_request_ctx.provider = ctx.provider_name;
    pre_request_ctx.model = ctx.model_name;
    pre_request_ctx.token_count = chat_helpers.clampUsizeToU32(last_content_len);
    try ctx.hooks.execute(.pre_request, &pre_request_ctx);

    spinner_mod.StreamingSpinner.showStatic("Thinking");

    out("\n{s}Assistant:{s} ", .{ Style.prompt_assistant.start(), Style.prompt_assistant.reset() });

    var response: core.ChatResponse = undefined;
    if (active_streaming_enabled) {
        core.setStreamingThinkingEnabled(active_show_thinking);
        defer core.setStreamingThinkingEnabled(false);
        response = ctx.client.sendChatStreaming(ctx.messages.items, interactiveStreamCallback) catch |err| {
            ctx.turn_failed = true;
            spinner_mod.StreamingSpinner.clearStatic();
            error_display_mod.printError("Request Failed", @errorName(err));
            return err;
        };
    } else {
        response = ctx.client.sendChatWithHistory(ctx.messages.items) catch |err| {
            ctx.turn_failed = true;
            spinner_mod.StreamingSpinner.clearStatic();
            error_display_mod.printError("Request Failed", @errorName(err));
            return err;
        };
    }

    spinner_mod.StreamingSpinner.clearStatic();

    if (response.choices.len == 0) {
        ctx.turn_failed = true;
        error_display_mod.printError("Empty Response", "The AI returned an empty response");
        return error.EmptyResponse;
    }

    ctx.turn_request_count += 1;
    ctx.request_count.* += 1;

    const choice = response.choices[0];
    const content = choice.message.content orelse "";
    const finish_reason_text = choice.finish_reason orelse "stop";

    if (content.len > 0) {
        markdown_mod.MarkdownRenderer.render(content);
    }

    if (response.usage) |usage| {
        ctx.total_input_tokens.* += usage.prompt_tokens;
        ctx.total_output_tokens.* += usage.completion_tokens;
        out("\n{s}({d} tokens in / {d} out | session total: {d}){s}", .{
            Style.dimmed.start(),
            usage.prompt_tokens,
            usage.completion_tokens,
            ctx.total_input_tokens.* + ctx.total_output_tokens.*,
            Style.dimmed.reset(),
        });

        ctx.json_out.emitAssistant(content);
        ctx.json_out.emitUsage(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    } else {
        ctx.json_out.emitAssistant(content);
    }
    out("\n", .{});

    var post_request_ctx = HookContext.init(arena);
    defer post_request_ctx.deinit();
    post_request_ctx.phase = .post_request;
    post_request_ctx.provider = ctx.provider_name;
    post_request_ctx.model = ctx.model_name;
    post_request_ctx.token_count = if (response.usage) |usage|
        chat_helpers.clampU64ToU32(usage.total_tokens)
    else
        chat_helpers.clampUsizeToU32(content.len);
    try ctx.hooks.execute(.post_request, &post_request_ctx);

    try chat_helpers.appendResponseMessage(ctx.messages, allocator, choice.message);
    ctx.synced_loop_messages = loop_messages.len + 1;

    const parsed_tool_calls = try ctx.client.extractToolCallsWithAllocator(&response, arena);

    if (std.mem.eql(u8, finish_reason_text, "tool_calls") and parsed_tool_calls.len == 0) {
        ctx.turn_failed = true;
        out("\nError: Model requested tool calls but none were parsed\n", .{});
        return error.InvalidToolCallResponse;
    }

    var loop_tool_calls: []const AIResponse.ToolCallInfo = &.{};
    if (parsed_tool_calls.len > 0) {
        const copied = try arena.alloc(AIResponse.ToolCallInfo, parsed_tool_calls.len);
        for (parsed_tool_calls, 0..) |tool_call, i| {
            copied[i] = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
        }
        loop_tool_calls = copied;
    }

    return .{
        .content = content,
        .finish_reason = AIResponse.FinishReason.fromString(finish_reason_text),
        .tool_calls = loop_tool_calls,
    };
}
