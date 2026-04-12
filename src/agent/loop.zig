const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");

const Allocator = std.mem.Allocator;

/// Tool call request from AI response
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, name: []const u8, arguments: []const u8) !ToolCall {
        return ToolCall{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .arguments = try allocator.dupe(u8, arguments),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolCall) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.arguments);
    }
};

/// Tool execution result
pub const ToolResult = struct {
    call_id: []const u8,
    output: []const u8,
    success: bool,
    duration_ms: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, call_id: []const u8, output: []const u8, success: bool) !ToolResult {
        return ToolResult{
            .call_id = try allocator.dupe(u8, call_id),
            .output = try allocator.dupe(u8, output),
            .success = success,
            .duration_ms = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolResult) void {
        self.allocator.free(self.call_id);
        self.allocator.free(self.output);
    }
};

/// Tool executor function type
pub const ToolExecutor = *const fn (Allocator, []const u8, []const u8) anyerror!ToolResult;

/// A single message in the agent loop conversation history
pub const LoopMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
};

/// Callback type for sending messages to AI and getting a response
/// Takes the full message history, returns the AI text response and finish reason.
pub const AISendFn = *const fn (Allocator, []const LoopMessage) anyerror!AIResponse;

/// AI response from the send callback
pub const AIResponse = struct {
    content: []const u8,
    finish_reason: FinishReason,
    tool_calls: []const ToolCallInfo,

    pub const FinishReason = enum {
        stop,
        tool_calls,
        length,
        error_unknown,

        pub fn fromString(s: []const u8) FinishReason {
            if (std.mem.eql(u8, s, "stop")) return .stop;
            if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
            if (std.mem.eql(u8, s, "length")) return .length;
            return .error_unknown;
        }
    };

    pub const ToolCallInfo = ai_types.ToolCallInfo;
};

/// Loop step result — output of a single iteration
pub const StepResult = struct {
    has_tool_calls: bool,
    tool_calls: array_list_compat.ArrayList(*ToolCall),
    tool_results: array_list_compat.ArrayList(*ToolResult),
    ai_response: []const u8,
    finish_reason: []const u8,
    iteration: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StepResult {
        return StepResult{
            .has_tool_calls = false,
            .tool_calls = array_list_compat.ArrayList(*ToolCall).init(allocator),
            .tool_results = array_list_compat.ArrayList(*ToolResult).init(allocator),
            .ai_response = "",
            .finish_reason = "stop",
            .iteration = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StepResult) void {
        if (self.ai_response.len > 0) {
            self.allocator.free(self.ai_response);
        }
        for (self.tool_calls.items) |tc| {
            tc.deinit();
            self.allocator.destroy(tc);
        }
        self.tool_calls.deinit();
        for (self.tool_results.items) |tr| {
            tr.deinit();
            self.allocator.destroy(tr);
        }
        self.tool_results.deinit();
    }
};

/// Final result of running the agent loop
pub const LoopResult = struct {
    final_response: []const u8,
    total_iterations: u32,
    total_tool_calls: u32,
    total_retries: u32,
    steps: array_list_compat.ArrayList(*StepResult),
    allocator: Allocator,

    pub fn deinit(self: *LoopResult) void {
        for (self.steps.items) |step| {
            step.deinit();
            self.allocator.destroy(step);
        }
        self.steps.deinit();
    }
};

/// Retry configuration with exponential backoff
/// Reference: OpenHarness exponential backoff retry
pub const RetryConfig = struct {
    max_retries: u32,
    initial_delay_ms: u64,
    max_delay_ms: u64,
    backoff_multiplier: f64,

    pub fn init() RetryConfig {
        return RetryConfig{
            .max_retries = 3,
            .initial_delay_ms = 1000,
            .max_delay_ms = 30000,
            .backoff_multiplier = 2.0,
        };
    }

    /// Calculate delay for a given attempt (exponential backoff)
    pub fn delayForAttempt(self: *const RetryConfig, attempt: u32) u64 {
        const base: f64 = @floatFromInt(self.initial_delay_ms);
        const multiplier = std.math.pow(f64, self.backoff_multiplier, @as(f64, @floatFromInt(attempt)));
        const delay: u64 = @intFromFloat(base * multiplier);
        return @min(delay, self.max_delay_ms);
    }

    /// Sleep for the calculated backoff delay
    pub fn wait(self: *const RetryConfig, attempt: u32) void {
        std.Thread.sleep(self.delayForAttempt(attempt) * std.time.ns_per_ms);
    }
};

/// Agent loop configuration
pub const LoopConfig = struct {
    max_iterations: u32,
    retry_config: RetryConfig,
    show_intermediate: bool,
    tool_timeout_ms: u64,

    pub fn init() LoopConfig {
        return LoopConfig{
            .max_iterations = 25,
            .retry_config = RetryConfig.init(),
            .show_intermediate = true,
            .tool_timeout_ms = 30000,
        };
    }
};

/// Agent Loop Engine — continuous tool-call cycle with retry
///
/// Implements the agentic loop pattern:
///   1. User sends message
///   2. AI responds (possibly with tool calls)
///   3. Tools execute, results feed back to AI
///   4. Repeat until AI finishes (no more tool calls)
///
/// Reference: OpenHarness query_engine.py agent loop
pub const AgentLoop = struct {
    allocator: Allocator,
    config: LoopConfig,
    registered_tools: std.StringHashMap(ToolExecutor),
    history: array_list_compat.ArrayList(LoopMessage),
    iteration: u32,
    total_tool_calls: u32,
    total_retries: u32,
    running: bool,

    pub fn init(allocator: Allocator) AgentLoop {
        return AgentLoop{
            .allocator = allocator,
            .config = LoopConfig.init(),
            .registered_tools = std.StringHashMap(ToolExecutor).init(allocator),
            .history = array_list_compat.ArrayList(LoopMessage).init(allocator),
            .iteration = 0,
            .total_tool_calls = 0,
            .total_retries = 0,
            .running = false,
        };
    }

    /// Configure the loop
    pub fn setConfig(self: *AgentLoop, config: LoopConfig) void {
        self.config = config;
    }

    /// Register a tool executor
    pub fn registerTool(self: *AgentLoop, name: []const u8, executor: ToolExecutor) !void {
        try self.registered_tools.put(name, executor);
    }

    /// Check if a tool is registered
    pub fn hasTool(self: *AgentLoop, name: []const u8) bool {
        return self.registered_tools.contains(name);
    }

    /// Execute a tool call with retry
    pub fn executeTool(self: *AgentLoop, call: *ToolCall) !?ToolResult {
        const executor = self.registered_tools.get(call.name) orelse {
            std.debug.print("  Tool '{s}' not registered\n", .{call.name});
            return null;
        };

        var attempt: u32 = 0;
        while (attempt <= self.config.retry_config.max_retries) : (attempt += 1) {
            if (attempt > 0) {
                self.total_retries += 1;
                if (self.config.show_intermediate) {
                    std.debug.print("  Retry {d}/{d} for tool '{s}'...\n", .{
                        attempt,
                        self.config.retry_config.max_retries,
                        call.name,
                    });
                }
                self.config.retry_config.wait(attempt - 1);
            }

            const result = executor(self.allocator, call.id, call.arguments) catch |err| {
                if (self.config.show_intermediate) {
                    std.debug.print("  Tool '{s}' error: {}\n", .{ call.name, err });
                }
                if (attempt >= self.config.retry_config.max_retries) {
                    return ToolResult.init(self.allocator, call.id, "Tool execution failed after max retries", false) catch null;
                }
                continue;
            };
            return result;
        }
        return null;
    }

    /// Run the agent loop with an AI send callback
    ///
    /// This is the core orchestration method:
    ///   1. Add user message to history
    ///   2. Send history to AI via callback
    ///   3. If AI returns tool calls → execute them → add results to history → goto 2
    ///   4. If AI returns stop → done
    ///   5. If max iterations reached → stop with last response
    pub fn run(self: *AgentLoop, ai_send: AISendFn, user_message: []const u8) !LoopResult {
        self.running = true;
        self.reset();

        var result = LoopResult{
            .final_response = "",
            .total_iterations = 0,
            .total_tool_calls = 0,
            .total_retries = 0,
            .steps = array_list_compat.ArrayList(*StepResult).init(self.allocator),
            .allocator = self.allocator,
        };

        // Add user message to history
        try self.addMessage("user", user_message);

        var done = false;
        while (!done and self.iteration < self.config.max_iterations) {
            self.iteration += 1;
            const step = try self.allocator.create(StepResult);
            step.* = StepResult.init(self.allocator);
            step.iteration = self.iteration;

            if (self.config.show_intermediate) {
                std.debug.print("\n--- Agent Loop Iteration {d}/{d} ---\n", .{ self.iteration, self.config.max_iterations });
            }

            // Send conversation history to AI
            const ai_response = ai_send(self.allocator, self.history.items) catch |err| {
                if (self.config.show_intermediate) {
                    std.debug.print("  AI send error: {}\n", .{err});
                }
                step.ai_response = try self.allocator.dupe(u8, "Error: AI request failed");
                step.finish_reason = "error";
                try result.steps.append(step);
                done = true;
                break;
            };

            // Store AI response
            const response_copy = try self.allocator.dupe(u8, ai_response.content);
            step.ai_response = response_copy;
            step.finish_reason = switch (ai_response.finish_reason) {
                .stop => "stop",
                .tool_calls => "tool_calls",
                .length => "length",
                .error_unknown => "error",
            };

            // Add assistant response to history
            try self.addMessage("assistant", ai_response.content);

            // Check for tool calls
            if (ai_response.tool_calls.len > 0) {
                step.has_tool_calls = true;

                // Add assistant message with tool calls to history
                for (ai_response.tool_calls) |tc| {
                    self.total_tool_calls += 1;
                    const tool_call = try self.allocator.create(ToolCall);
                    tool_call.* = try ToolCall.init(self.allocator, tc.id, tc.name, tc.arguments);
                    try step.tool_calls.append(tool_call);

                    if (self.config.show_intermediate) {
                        std.debug.print("  Tool call: {s}({s})\n", .{ tc.name, tc.arguments });
                    }

                    // Execute tool
                    const tool_result = self.executeTool(tool_call) catch null;
                    if (tool_result) |tr| {
                        const result_ptr = try self.allocator.create(ToolResult);
                        result_ptr.* = tr;
                        try step.tool_results.append(result_ptr);

                        // Add tool result to history
                        try self.addToolResult(tr.call_id, tc.name, tr.output);

                        if (self.config.show_intermediate) {
                            const status = if (tr.success) "OK" else "FAILED";
                            std.debug.print("  Tool result [{s}]: {s}\n", .{ status, tr.output });
                        }
                    } else {
                        // Tool not found or failed — report error back to AI
                        const err_msg = try std.fmt.allocPrint(self.allocator, "Tool '{s}' not found or execution failed", .{tc.name});
                        try self.addToolResult(tc.id, tc.name, err_msg);
                        self.allocator.free(err_msg);
                    }
                }
            } else {
                // No tool calls — AI is done
                done = true;
            }

            try result.steps.append(step);
        }

        // Set final response from last step
        if (result.steps.items.len > 0) {
            result.final_response = result.steps.items[result.steps.items.len - 1].ai_response;
        }
        result.total_iterations = self.iteration;
        result.total_tool_calls = self.total_tool_calls;
        result.total_retries = self.total_retries;

        self.running = false;
        return result;
    }

    /// Add a message to the loop history
    pub fn addMessage(self: *AgentLoop, role: []const u8, content: []const u8) !void {
        try self.history.append(.{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = null,
            .tool_name = null,
        });
    }

    /// Add a tool result to history
    pub fn addToolResult(self: *AgentLoop, call_id: []const u8, tool_name: []const u8, output: []const u8) !void {
        try self.history.append(.{
            .role = try self.allocator.dupe(u8, "tool"),
            .content = try self.allocator.dupe(u8, output),
            .tool_call_id = try self.allocator.dupe(u8, call_id),
            .tool_name = try self.allocator.dupe(u8, tool_name),
        });
    }

    /// Print loop status
    pub fn printStatus(self: *AgentLoop) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Agent Loop Engine ===\n", .{}) catch {};
        stdout.print("  Iteration: {d}/{d}\n", .{ self.iteration, self.config.max_iterations }) catch {};
        stdout.print("  Total tool calls: {d}\n", .{self.total_tool_calls}) catch {};
        stdout.print("  Total retries: {d}\n", .{self.total_retries}) catch {};
        stdout.print("  History messages: {d}\n", .{self.history.items.len}) catch {};
        stdout.print("  Registered tools: {d}\n", .{self.registered_tools.count()}) catch {};
        stdout.print("  Running: {s}\n", .{if (self.running) "yes" else "no"}) catch {};
        stdout.print("\n  Registered tools:\n", .{}) catch {};
        var iter = self.registered_tools.iterator();
        while (iter.next()) |entry| {
            stdout.print("    - {s}\n", .{entry.key_ptr.*}) catch {};
        }
    }

    /// Reset the loop state
    pub fn reset(self: *AgentLoop) void {
        for (self.history.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_name) |n| self.allocator.free(n);
        }
        self.history.clearRetainingCapacity();
        self.iteration = 0;
        self.total_tool_calls = 0;
        self.total_retries = 0;
        self.running = false;
    }

    pub fn deinit(self: *AgentLoop) void {
        for (self.history.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_name) |n| self.allocator.free(n);
        }
        self.history.deinit();
        self.registered_tools.deinit();
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Mock tool executor that returns a fixed result
fn mockToolExecutor(allocator: Allocator, call_id: []const u8, arguments: []const u8) anyerror!ToolResult {
    _ = call_id;
    _ = arguments;
    return try ToolResult.init(allocator, "mock-call-id", "mock tool output", true);
}

/// Mock tool executor that always fails
fn failingToolExecutor(allocator: Allocator, call_id: []const u8, arguments: []const u8) anyerror!ToolResult {
    _ = allocator;
    _ = call_id;
    _ = arguments;
    return error.ToolExecutionFailed;
}

/// Mock AI send function that returns stop immediately (no tool calls)
fn mockAISendStop(allocator: Allocator, messages: []const LoopMessage) anyerror!AIResponse {
    _ = allocator;
    _ = messages;
    return AIResponse{
        .content = "I am done.",
        .finish_reason = .stop,
        .tool_calls = &.{},
    };
}

/// Mock AI send function that returns one tool call on first call, then stops
var mock_send_call_count: u32 = 0;

fn mockAISendOneToolCall(allocator: Allocator, messages: []const LoopMessage) anyerror!AIResponse {
    _ = allocator;
    _ = messages;
    mock_send_call_count += 1;
    if (mock_send_call_count == 1) {
        return AIResponse{
            .content = "I need to use a tool.",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]AIResponse.ToolCallInfo{
                .{
                    .id = "call-1",
                    .name = "mock_tool",
                    .arguments = "{\"query\": \"test\"}",
                },
            },
        };
    }
    return AIResponse{
        .content = "Tool result processed. Final answer: 42",
        .finish_reason = .stop,
        .tool_calls = &[_]AIResponse.ToolCallInfo{},
    };
}

/// Mock AI send that loops 3 times with tool calls, then stops
var mock_multi_call_count: u32 = 0;

fn mockAISendMultiToolCall(allocator: Allocator, messages: []const LoopMessage) anyerror!AIResponse {
    _ = allocator;
    _ = messages;
    mock_multi_call_count += 1;
    if (mock_multi_call_count <= 3) {
        return AIResponse{
            .content = "Processing...",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]AIResponse.ToolCallInfo{
                .{
                    .id = "multi-call",
                    .name = "mock_tool",
                    .arguments = "args",
                },
            },
        };
    }
    return AIResponse{
        .content = "All done after 3 tool calls.",
        .finish_reason = .stop,
        .tool_calls = &.{},
    };
}

test "ToolCall - init and deinit" {
    const tc = try ToolCall.init(testing.allocator, "id-1", "my_tool", "{\"arg\": 1}");
    defer {
        var mutable = tc;
        mutable.deinit();
    }
    try testing.expectEqualStrings("id-1", tc.id);
    try testing.expectEqualStrings("my_tool", tc.name);
    try testing.expectEqualStrings("{\"arg\": 1}", tc.arguments);
}

test "ToolResult - init and deinit" {
    const tr = try ToolResult.init(testing.allocator, "call-1", "result output", true);
    defer {
        var mutable = tr;
        mutable.deinit();
    }
    try testing.expectEqualStrings("call-1", tr.call_id);
    try testing.expectEqualStrings("result output", tr.output);
    try testing.expect(tr.success);
}

test "RetryConfig - default values" {
    const rc = RetryConfig.init();
    try testing.expectEqual(@as(u32, 3), rc.max_retries);
    try testing.expectEqual(@as(u64, 1000), rc.initial_delay_ms);
    try testing.expectEqual(@as(u64, 30000), rc.max_delay_ms);
    try testing.expectEqual(@as(f64, 2.0), rc.backoff_multiplier);
}

test "RetryConfig - delayForAttempt exponential backoff" {
    const rc = RetryConfig.init();
    // attempt 0: 1000 * 2^0 = 1000
    try testing.expectEqual(@as(u64, 1000), rc.delayForAttempt(0));
    // attempt 1: 1000 * 2^1 = 2000
    try testing.expectEqual(@as(u64, 2000), rc.delayForAttempt(1));
    // attempt 2: 1000 * 2^2 = 4000
    try testing.expectEqual(@as(u64, 4000), rc.delayForAttempt(2));
    // attempt 10: should cap at max_delay_ms = 30000
    try testing.expectEqual(@as(u64, 30000), rc.delayForAttempt(10));
}

test "LoopConfig - default values" {
    const lc = LoopConfig.init();
    try testing.expectEqual(@as(u32, 25), lc.max_iterations);
    try testing.expect(lc.show_intermediate);
    try testing.expectEqual(@as(u64, 30000), lc.tool_timeout_ms);
}

test "FinishReason - fromString" {
    try testing.expectEqual(AIResponse.FinishReason.stop, AIResponse.FinishReason.fromString("stop"));
    try testing.expectEqual(AIResponse.FinishReason.tool_calls, AIResponse.FinishReason.fromString("tool_calls"));
    try testing.expectEqual(AIResponse.FinishReason.length, AIResponse.FinishReason.fromString("length"));
    try testing.expectEqual(AIResponse.FinishReason.error_unknown, AIResponse.FinishReason.fromString("something_else"));
}

test "AgentLoop - init and deinit" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try testing.expectEqual(@as(u32, 0), loop.iteration);
    try testing.expectEqual(@as(u32, 0), loop.total_tool_calls);
    try testing.expect(!loop.running);
    try testing.expectEqual(@as(u32, 25), loop.config.max_iterations);
}

test "AgentLoop - registerTool and hasTool" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try testing.expect(!loop.hasTool("mock_tool"));
    try loop.registerTool("mock_tool", mockToolExecutor);
    try testing.expect(loop.hasTool("mock_tool"));
    try testing.expect(!loop.hasTool("nonexistent"));
}

test "AgentLoop - addMessage adds to history" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.addMessage("user", "Hello");
    try loop.addMessage("assistant", "Hi there");
    try testing.expectEqual(@as(usize, 2), loop.history.items.len);
    try testing.expectEqualStrings("user", loop.history.items[0].role);
    try testing.expectEqualStrings("Hello", loop.history.items[0].content);
    try testing.expectEqualStrings("assistant", loop.history.items[1].role);
    try testing.expectEqualStrings("Hi there", loop.history.items[1].content);
}

test "AgentLoop - addToolResult adds tool message" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.addToolResult("call-123", "my_tool", "tool output here");
    try testing.expectEqual(@as(usize, 1), loop.history.items.len);
    try testing.expectEqualStrings("tool", loop.history.items[0].role);
    try testing.expectEqualStrings("tool output here", loop.history.items[0].content);
    try testing.expectEqualStrings("call-123", loop.history.items[0].tool_call_id.?);
    try testing.expectEqualStrings("my_tool", loop.history.items[0].tool_name.?);
}

test "AgentLoop - reset clears state" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.addMessage("user", "test");
    loop.iteration = 5;
    loop.total_tool_calls = 3;
    loop.running = true;
    loop.reset();
    try testing.expectEqual(@as(usize, 0), loop.history.items.len);
    try testing.expectEqual(@as(u32, 0), loop.iteration);
    try testing.expectEqual(@as(u32, 0), loop.total_tool_calls);
    try testing.expect(!loop.running);
}

test "AgentLoop - run with immediate stop (no tool calls)" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    var result = try loop.run(mockAISendStop, "Hello, just answer me");
    defer result.deinit();
    try testing.expectEqualStrings("I am done.", result.final_response);
    try testing.expectEqual(@as(u32, 1), result.total_iterations);
    try testing.expectEqual(@as(u32, 0), result.total_tool_calls);
    try testing.expectEqual(@as(u32, 0), result.total_retries);
    try testing.expectEqual(@as(usize, 1), result.steps.items.len);
}

test "AgentLoop - run with one tool call then stop" {
    mock_send_call_count = 0;
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.registerTool("mock_tool", mockToolExecutor);
    var result = try loop.run(mockAISendOneToolCall, "Use a tool then answer");
    defer result.deinit();
    try testing.expectEqualStrings("Tool result processed. Final answer: 42", result.final_response);
    try testing.expectEqual(@as(u32, 2), result.total_iterations);
    try testing.expectEqual(@as(u32, 1), result.total_tool_calls);
    try testing.expectEqual(@as(usize, 2), result.steps.items.len);
    // First step should have tool calls
    try testing.expect(result.steps.items[0].has_tool_calls);
    // Second step should not
    try testing.expect(!result.steps.items[1].has_tool_calls);
}

test "AgentLoop - run with multiple tool call rounds" {
    mock_multi_call_count = 0;
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.registerTool("mock_tool", mockToolExecutor);
    var result = try loop.run(mockAISendMultiToolCall, "Multi-step task");
    defer result.deinit();
    try testing.expectEqualStrings("All done after 3 tool calls.", result.final_response);
    try testing.expectEqual(@as(u32, 3), result.total_tool_calls);
    try testing.expectEqual(@as(usize, 4), result.steps.items.len);
}

test "AgentLoop - executeTool with unregistered tool returns null" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    const tc = try ToolCall.init(testing.allocator, "id-1", "nonexistent_tool", "{}");
    defer {
        var mutable = tc;
        mutable.deinit();
    }
    const result = try loop.executeTool(@constCast(&tc));
    try testing.expect(result == null);
}

test "AgentLoop - executeTool with registered tool succeeds" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    try loop.registerTool("mock_tool", mockToolExecutor);
    const tc = try ToolCall.init(testing.allocator, "id-1", "mock_tool", "{\"q\": 1}");
    defer {
        var mutable = tc;
        mutable.deinit();
    }
    const result = try loop.executeTool(@constCast(&tc));
    try testing.expect(result != null);
    if (result) |tr| {
        defer {
            var mutable = tr;
            mutable.deinit();
        }
        try testing.expect(tr.success);
        try testing.expectEqualStrings("mock tool output", tr.output);
    }
}

test "StepResult - init and deinit" {
    var step = StepResult.init(testing.allocator);
    defer step.deinit();
    try testing.expect(!step.has_tool_calls);
    try testing.expectEqual(@as(u32, 0), step.iteration);
    try testing.expectEqualStrings("", step.ai_response);
    try testing.expectEqualStrings("stop", step.finish_reason);
}

test "LoopResult - deinit cleans up steps" {
    var loop = AgentLoop.init(testing.allocator);
    defer loop.deinit();
    var result = try loop.run(mockAISendStop, "test");
    result.deinit();
    // If we get here without crash, deinit worked correctly
}
