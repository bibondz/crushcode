const std = @import("std");

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

/// Loop step result
pub const StepResult = struct {
    has_tool_calls: bool,
    tool_calls: std.ArrayList(*ToolCall),
    tool_results: std.ArrayList(*ToolResult),
    ai_response: []const u8,
    finish_reason: []const u8,
    iteration: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StepResult {
        return StepResult{
            .has_tool_calls = false,
            .tool_calls = std.ArrayList(*ToolCall).init(allocator),
            .tool_results = std.ArrayList(*ToolResult).init(allocator),
            .ai_response = "",
            .finish_reason = "stop",
            .iteration = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StepResult) void {
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
    history: std.ArrayList(LoopMessage),
    iteration: u32,
    total_tool_calls: u32,
    total_retries: u32,
    running: bool,

    pub const LoopMessage = struct {
        role: []const u8,
        content: []const u8,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
    };

    pub fn init(allocator: Allocator) AgentLoop {
        return AgentLoop{
            .allocator = allocator,
            .config = LoopConfig.init(),
            .registered_tools = std.StringHashMap(ToolExecutor).init(allocator),
            .history = std.ArrayList(LoopMessage).init(allocator),
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
        const stdout = std.io.getStdOut().writer();
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
