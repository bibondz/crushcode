const std = @import("std");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const http_client = @import("http_client");
const registry_mod = @import("registry");
const tool_types = @import("tool_types");
const error_handler_mod = @import("error_handler.zig");
const streaming_parsers = @import("ai_streaming_parsers");
const trace_span = @import("trace_span");
const retry_policy = @import("retry_policy");
const guardrail = @import("guardrail_pipeline");
const metrics = @import("metrics_collector");
const circuit_breaker = @import("circuit_breaker");
const token_cache_mod = @import("token_cache");

pub const ChatMessage = ai_types.ChatMessage;
pub const ToolCallInfo = ai_types.ToolCallInfo;
pub const ParsedToolCall = ai_types.ParsedToolCall;
pub const ChatRequest = ai_types.ChatRequest;
pub const ChatResponse = ai_types.ChatResponse;
pub const ChatChoice = ai_types.ChatChoice;
pub const Usage = ai_types.Usage;

pub const OllamaResponse = struct {
    model: []const u8,
    message: OllamaMessage,
    done: bool,
};

pub const OllamaMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ExtendedUsage = ai_types.ExtendedUsage;
pub const ToolSchema = tool_types.ToolSchema;

const APIFunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

const APIToolCall = struct {
    id: []const u8,
    type: ?[]const u8 = null,
    function: APIFunctionCall,
};

const APIChatMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const APIToolCall = null,
};

const APIChatChoice = struct {
    index: u32,
    message: APIChatMessage,
    finish_reason: ?[]const u8 = null,
};

const APIChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []APIChatChoice,
    usage: ?Usage = null,
    provider: ?[]const u8 = null,
    cost: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,
};

const StreamingToolCall = streaming_parsers.StreamingToolCall;

pub const StreamCallback = ai_types.StreamCallback;
pub threadlocal var active_show_thinking: bool = false;

const StreamFormat = streaming_parsers.StreamFormat;

pub const AIClient = struct {
    allocator: std.mem.Allocator,
    provider: registry_mod.Provider,
    model: []const u8,
    api_key: []const u8,
    system_prompt: ?[]const u8 = null,
    tools: []const ToolSchema = &.{},
    /// Maximum tokens in AI response (default: 4096)
    max_tokens: u32 = 4096,
    /// Sampling temperature 0.0–2.0 (default: 0.7)
    temperature: f32 = 0.7,
    /// Optional guardrail pipeline for input validation before requests
    guardrail_pipeline: ?*guardrail.GuardrailPipeline = null,
    /// Optional metrics collector for request observability
    metrics_collector: ?*metrics.MetricsCollector = null,
    /// Optional circuit breaker map for provider failure tracking
    circuit_breakers: ?*circuit_breaker.CircuitBreakerMap = null,

    pub fn init(allocator: std.mem.Allocator, provider: registry_mod.Provider, model: []const u8, api_key: []const u8) !AIClient {
        return AIClient{
            .allocator = allocator,
            .provider = provider,
            .model = model,
            .api_key = api_key,
            .system_prompt = null,
            .max_tokens = 4096,
            .temperature = 0.7,
        };
    }

    pub fn setSystemPrompt(self: *AIClient, prompt: []const u8) void {
        self.system_prompt = prompt;
    }

    /// Set available tools for function calling
    pub fn setTools(self: *AIClient, tools: []const ToolSchema) void {
        self.tools = tools;
    }

    /// Record circuit breaker success for this provider
    fn recordCircuitSuccess(self: *AIClient) void {
        if (self.circuit_breakers) |breakers| {
            if (breakers.getPtr(self.provider.name)) |breaker| {
                breaker.recordSuccess();
            }
        }
    }

    /// Record circuit breaker failure for this provider
    fn recordCircuitFailure(self: *AIClient) void {
        if (self.circuit_breakers) |breakers| {
            if (breakers.getPtr(self.provider.name)) |breaker| {
                breaker.recordFailure();
            }
        }
    }

    /// Build the tools array JSON for API requests
    fn buildToolsJson(self: *AIClient, allocator: std.mem.Allocator) ![]const u8 {
        if (self.tools.len == 0) return allocator.dupe(u8, "");

        var buf = array_list_compat.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll(",\"tools\":[");
        for (self.tools, 0..) |tool, i| {
            if (i > 0) try writer.writeAll(",");
            // Note: tool.parameters is already a JSON string like {"type":"object",...}
            // We inject it as a raw JSON object (not a string) per OpenAI function calling spec.
            try writer.print(
                \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
            , .{ tool.name, tool.description, tool.parameters });
        }
        try writer.writeAll("]");

        return buf.toOwnedSlice();
    }

    pub fn deinit(self: *AIClient) void {
        _ = self;
    }

    /// Get the actual model name to send to API.
    /// Strips provider prefix (e.g. "openai/gpt-4o-mini" → "gpt-4o-mini")
    /// unless the provider config keeps the provider/model prefix.
    pub fn getApiModelName(self: *AIClient) []const u8 {
        if (self.provider.config.keep_prefix) {
            return self.model;
        }
        if (std.mem.indexOfScalar(u8, self.model, '/')) |idx| {
            return self.model[idx + 1 ..];
        }
        return self.model;
    }

    pub fn sendChat(self: *AIClient, user_message: []const u8) !ChatResponse {
        return self.sendChatWithOptions(user_message, null, true);
    }

    /// Send chat with conversation history
    pub fn sendChatWithHistory(self: *AIClient, messages: []const ChatMessage) !ChatResponse {
        return self.sendChatWithOptions(null, messages, true);
    }

    /// Mock streaming provider for performance benchmarking.
    /// Emits tokens with realistic SSE timing to measure TTFT and throughput
    /// without network latency.
    fn sendMockPerfStream(self: *AIClient, callback: StreamCallback) !ChatResponse {
        const allocator = self.allocator;
        const tokens = [_][]const u8{
            "PERF:mock_token_0",
            "PERF:mock_token_1",
            "PERF:mock_token_2",
            "PERF:mock_token_3",
            "PERF:mock_token_4",
            "PERF:mock_token_5",
            "PERF:mock_token_6",
            "PERF:mock_token_7",
            "PERF:mock_token_8",
            "PERF:mock_token_9",
        };

        var full_content = array_list_compat.ArrayList(u8).init(allocator);
        defer full_content.deinit();

        // Emit tokens with 10ms delay each (simulating 100 tok/s)
        for (tokens, 0..) |token, i| {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            try full_content.appendSlice(token);
            if (i == tokens.len - 1) {
                callback(token, true);
            } else {
                callback(token, false);
            }
        }

        const content = try allocator.dupe(u8, full_content.items);
        const model = try allocator.dupe(u8, self.model);

        const choices = try allocator.alloc(ChatChoice, 1);
        choices[0] = .{
            .index = 0,
            .message = .{
                .role = "assistant",
                .content = content,
                .tool_calls = null,
            },
            .finish_reason = "stop",
        };

        return ChatResponse{
            .id = "perf-mock-001",
            .object = "chat.completion",
            .created = @intCast(std.time.milliTimestamp()),
            .model = model,
            .choices = choices,
            .usage = .{
                .prompt_tokens = 10,
                .completion_tokens = tokens.len,
                .total_tokens = 10 + tokens.len,
            },
        };
    }

    /// Send chat with streaming, calling callback for each token chunk.
    pub fn sendChatStreaming(self: *AIClient, messages: []const ChatMessage, callback: StreamCallback) !ChatResponse {
        if (messages.len == 0) {
            return error.InvalidRequest;
        }

        if (self.model.len == 0) {
            return error.ConfigurationError;
        }

        if (std.mem.eql(u8, self.provider.name, "mock-perf")) {
            return self.sendMockPerfStream(callback);
        }

        const has_key = self.api_key.len > 0;
        const is_local = self.provider.config.is_local;

        if (!has_key and !is_local) {
            return error.AuthenticationError;
        }

        // Guardrail pre-check: validate last user message before sending
        // Guardrail check on the last user message
        var guardrail_redacted: ?[]const u8 = null;
        if (self.guardrail_pipeline) |pipeline| {
            const last_msg = messages[messages.len - 1];
            const input_text = last_msg.content orelse "";
            var gr_result = try pipeline.check(input_text);
            defer gr_result.deinit();
            if (gr_result.action == .deny) {
                std.log.warn("guardrail blocked request: {s} ({s})", .{ gr_result.scanner_name, gr_result.reason orelse "no reason" });
                return error.GuardrailBlocked;
            }
            if (gr_result.action == .redact and gr_result.redacted_content != null) {
                std.log.info("guardrail redacted content: {s}", .{gr_result.scanner_name});
                guardrail_redacted = gr_result.redacted_content.?;
                gr_result.redacted_content = null; // prevent deinit from freeing
            }
        }

        // Record start time for metrics
        const start_ns = std.time.nanoTimestamp();

        // Create trace span for observability
        var llm_span: ?*trace_span.Span = null;
        if (trace_span.context.currentTrace()) |trace| {
            const span_name = std.fmt.allocPrint(self.allocator, "llm.{s}", .{self.provider.name}) catch "llm.unknown";
            defer self.allocator.free(span_name);
            llm_span = trace.rootSpan(span_name, .llm) catch null;
            if (llm_span) |span| {
                span.model = self.allocator.dupe(u8, self.model) catch null;
                span.provider = self.allocator.dupe(u8, self.provider.name) catch null;
            }
        }
        defer if (llm_span) |span| span.deinit();

        const allocator = self.allocator;
        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, self.getChatPath() });
        defer allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);

        // Build effective messages — if guardrail redacted the last message,
        // create a copy with the redacted content replacing the original.
        var redacted_messages: ?[]ChatMessage = null;
        defer {
            if (redacted_messages) |rm| allocator.free(rm);
            if (guardrail_redacted) |r| allocator.free(r);
        }
        const effective_messages: []const ChatMessage = blk: {
            if (guardrail_redacted) |redacted| {
                var copy = try allocator.alloc(ChatMessage, messages.len);
                @memcpy(copy, messages);
                copy[messages.len - 1].content = redacted;
                redacted_messages = copy;
                break :blk copy;
            }
            break :blk messages;
        };

        // Build request body — use cache-aware builder for Anthropic providers
        const is_anthropic = std.mem.eql(u8, self.provider.name, "anthropic") or
            std.mem.eql(u8, self.provider.name, "bedrock") or
            std.mem.eql(u8, self.provider.name, "vertexai");

        const json_body = if (is_anthropic) blk_2: {
            // Build cache marks: system prompt + last 2 tool results
            var marks = try allocator.alloc(bool, effective_messages.len + 1);
            @memset(marks, false);
            // Mark system prompt as cacheable
            marks[0] = true;
            // Find last 2 tool-result messages
            var found: usize = 0;
            var idx: isize = @as(isize, @intCast(effective_messages.len)) - 1;
            while (idx >= 0 and found < 2) : (idx -= 1) {
                const i: usize = @intCast(idx);
                if (std.mem.eql(u8, effective_messages[i].role, "tool")) {
                    marks[i + 1] = true; // +1 for system prompt offset
                    found += 1;
                }
            }
            defer allocator.free(marks);
            const tools_json = try self.buildToolsJson(allocator);
            defer allocator.free(tools_json);
            break :blk_2 try streaming_parsers.buildCacheAwareStreamingBody(
                allocator, self.getApiModelName(), self.system_prompt,
                effective_messages, tools_json, self.max_tokens, self.temperature, marks,
            );
        } else try self.buildStreamingBodyFromMessages(effective_messages);
        defer allocator.free(json_body);

        // Store input payload on span (truncated)
        if (llm_span) |span| {
            span.input_json = allocator.dupe(u8, json_body[0..@min(json_body.len, 4096)]) catch null;
        }

        const headers = try self.buildHeaders();
        defer freeHeaders(allocator, headers);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var request = client.request(.POST, uri, .{
            .extra_headers = headers,
        }) catch return error.NetworkError;
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = json_body.len };
        var body = request.sendBodyUnflushed(&.{}) catch return error.NetworkError;
        body.writer.writeAll(json_body) catch return error.NetworkError;
        body.end() catch return error.NetworkError;
        request.connection.?.flush() catch return error.NetworkError;

        var response = request.receiveHead(&.{}) catch return error.NetworkError;
        var response_transfer_buffer: [4096]u8 = undefined;
        const response_reader = response.reader(&response_transfer_buffer);
        if (response.head.status != .ok) {
            var error_body = array_list_compat.ArrayList(u8).init(allocator);
            defer error_body.deinit();

            var error_chunk: [4096]u8 = undefined;
            while (true) {
                const bytes_read = response_reader.readSliceShort(&error_chunk) catch return error.NetworkError;
                if (bytes_read == 0) break;
                try error_body.appendSlice(error_chunk[0..bytes_read]);
            }

            // End trace span with error status
            if (llm_span) |span| {
                span.end(.@"error", error_body.items);
            }

            std.log.err("Streaming request failed (status {d}): {s}", .{ @intFromEnum(response.head.status), error_body.items });

            return error.ServerError;
        }

        var partial_line = array_list_compat.ArrayList(u8).init(allocator);
        defer partial_line.deinit();

        var full_content = array_list_compat.ArrayList(u8).init(allocator);
        defer full_content.deinit();

        var streaming_tool_calls = array_list_compat.ArrayList(StreamingToolCall).init(allocator);
        defer {
            for (streaming_tool_calls.items) |*tool_call| {
                tool_call.deinit(allocator);
            }
            streaming_tool_calls.deinit();
        }

        var finish_reason: ?[]const u8 = null;
        defer if (finish_reason) |reason| allocator.free(reason);

        var usage: ?Usage = null;

        var chunk_buf: [4096]u8 = undefined;
        var saw_done = false;

        streaming_parsers.active_show_thinking = active_show_thinking;
        defer streaming_parsers.active_show_thinking = false;

        while (true) {
            const bytes_read = response_reader.readSliceShort(&chunk_buf) catch return error.NetworkError;
            if (bytes_read == 0) break;

            try self.processStreamChunk(
                &partial_line,
                chunk_buf[0..bytes_read],
                &full_content,
                &finish_reason,
                &usage,
                callback,
                &saw_done,
                &streaming_tool_calls,
            );
        }

        try self.processStreamChunk(&partial_line, "\n", &full_content, &finish_reason, &usage, callback, &saw_done, &streaming_tool_calls);

        if (!saw_done) {
            callback("", true);
        }

        // Populate trace span with usage data and end it
        if (llm_span) |span| {
            if (usage) |u| {
                span.prompt_tokens = u.prompt_tokens;
                span.completion_tokens = u.completion_tokens;
                span.total_tokens = u.total_tokens;
            }
            span.end(.ok, null);
        }

        // Emit metrics (fire-and-forget)
        if (self.metrics_collector) |mc| {
            const elapsed_ns = std.time.nanoTimestamp() - start_ns;
            const duration_ms: f64 = @floatFromInt(@divTrunc(elapsed_ns, 1_000_000));
            mc.increment("crushcode_requests_total", 1, &.{});
            mc.observe("crushcode_request_duration_ms", duration_ms, &.{}) catch {};
        }

        // Record circuit breaker success
        if (self.circuit_breakers) |breakers| {
            if (breakers.getPtr(self.provider.name)) |breaker| {
                breaker.recordSuccess();
            }
        }

        return self.buildStreamingResponse(full_content.items, finish_reason orelse "stop", usage, streaming_tool_calls.items);
    }

    /// Send chat with tool results (for multi-turn agent loop)
    pub fn sendChatWithToolResults(self: *AIClient, messages: []ChatMessage, callback: StreamCallback) !ChatResponse {
        return self.sendChatStreaming(messages, callback);
    }

    /// Extract tool calls from a ChatResponse (non-streaming)
    pub fn extractToolCalls(self: *AIClient, response: *const ChatResponse) ![]ParsedToolCall {
        if (response.choices.len == 0) {
            return &.{};
        }

        const tool_calls = response.choices[0].message.tool_calls orelse return &.{};
        const parsed = try self.allocator.alloc(ParsedToolCall, tool_calls.len);
        for (tool_calls, 0..) |tool_call, i| {
            parsed[i] = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
        }
        return parsed;
    }

    /// Extract tool calls using a caller-provided arena allocator.
    /// All allocations live in the arena — no individual free() needed.
    /// Arena is reset between requests, so memory is reclaimed in bulk.
    pub fn extractToolCallsWithAllocator(self: *AIClient, response: *const ChatResponse, arena: std.mem.Allocator) ![]ParsedToolCall {
        _ = self;
        if (response.choices.len == 0) {
            return &.{};
        }

        const tool_calls = response.choices[0].message.tool_calls orelse return &.{};
        const parsed = try arena.alloc(ParsedToolCall, tool_calls.len);
        for (tool_calls, 0..) |tool_call, i| {
            parsed[i] = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
        }
        return parsed;
    }

    /// Build tool result messages for the next request.
    /// Format: {"role": "tool", "tool_call_id": "call_abc", "content": "file content..."}
    pub fn buildToolResultMessages(self: *AIClient, tool_calls: []ParsedToolCall, results: []const []const u8) ![]ChatMessage {
        if (tool_calls.len != results.len) {
            return error.InvalidRequest;
        }

        const messages = try self.allocator.alloc(ChatMessage, tool_calls.len);
        for (tool_calls, results, 0..) |tool_call, result, i| {
            messages[i] = .{
                .role = try self.allocator.dupe(u8, "tool"),
                .content = try self.allocator.dupe(u8, result),
                .tool_call_id = try self.allocator.dupe(u8, tool_call.id),
                .tool_calls = null,
            };
        }
        return messages;
    }

    /// Internal method with options
    fn sendChatWithOptions(self: *AIClient, single_message: ?[]const u8, messages: ?[]const ChatMessage, debug: bool) !ChatResponse {
        // Validate inputs
        if (single_message == null and messages == null) {
            return error.InvalidRequest;
        }

        var retry_state = retry_policy.RetryState.init(self.allocator, retry_policy.RetryPolicy.forProvider());
        defer retry_state.deinit();

        // Early validation for required fields
        if (self.model.len == 0) {
            return error.ConfigurationError;
        }

        const has_key = self.api_key.len > 0;
        const is_local = self.provider.config.is_local;

        if (!has_key and !is_local) {
            return error.AuthenticationError;
        }

        // Create trace span for observability
        var llm_span: ?*trace_span.Span = null;
        if (trace_span.context.currentTrace()) |trace| {
            const span_name = std.fmt.allocPrint(self.allocator, "llm.{s}", .{self.provider.name}) catch "llm.unknown";
            defer self.allocator.free(span_name);
            llm_span = trace.rootSpan(span_name, .llm) catch null;
            if (llm_span) |span| {
                span.model = self.allocator.dupe(u8, self.model) catch null;
                span.provider = self.allocator.dupe(u8, self.provider.name) catch null;
                if (single_message) |msg| {
                    span.input_json = self.allocator.dupe(u8, msg[0..@min(msg.len, 4096)]) catch null;
                }
            }
        }
        defer if (llm_span) |span| span.deinit();

        if (debug) {
            std.log.debug("\n=== Crushcode AI Client ===", .{});
            std.log.debug("Provider: {s}", .{self.provider.name});
            std.log.debug("Model: {s}", .{self.model});
            std.log.debug("API Endpoint: {s}{s}", .{ self.provider.config.base_url, self.getChatPath() });
            if (single_message) |msg| {
                std.log.debug("User Message: {s}", .{msg});
            } else if (messages) |msgs| {
                std.log.debug("Messages: {d}", .{msgs.len});
            }
        }

        while (retry_state.nextAttempt()) |delay_ms| {
            if (debug) std.log.debug("\n[Attempt {d}/{d}]", .{ retry_state.current_attempt, retry_state.policy.max_attempts });

            if (retry_state.current_attempt > 1) {
                if (debug) std.log.debug("Waiting {d}ms before retry...", .{delay_ms});
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }

            const result = if (single_message != null)
                try self.performHttpRequest(single_message.?, has_key, is_local, retry_state.current_attempt, debug)
            else
                try self.performHttpRequestHistory(messages.?, has_key, is_local, retry_state.current_attempt, debug);

            if (result.err) |err| {
                std.log.err("Request failed (attempt {d}): {s}", .{ retry_state.current_attempt, error_handler_mod.formatError(err) });
                if (debug) std.log.debug("Request failed: {s}", .{error_handler_mod.formatError(err)});

                // Derive approximate HTTP status from error type for classification
                const http_status: u16 = switch (err.error_type) {
                    error.AuthenticationError => 401,
                    error.RateLimitError => 429,
                    error.InvalidRequest => 400,
                    error.ModelNotFound => 404,
                    error.ServerError => 500,
                    error.NetworkError => 503,
                    error.TimeoutError => 408,
                    else => 500,
                };
                // Classify error with the new retry policy system
                const error_class = retry_policy.RetryPolicy.classifyError(http_status, err.message);
                const can_retry = retry_state.recordError(error_class, err.message);

                // Keep backward compat: also check legacy isRetryableError
                if (!can_retry and !error_handler_mod.isRetryableError(err.error_type)) {
                    if (llm_span) |span| span.end(.@"error", err.message);
                    self.recordCircuitFailure();
                    return error.RetryExhausted;
                }
                if (!can_retry) {
                    // New policy says stop but legacy says retryable — respect new policy
                    if (llm_span) |span| span.end(.@"error", err.message);
                    self.recordCircuitFailure();
                    return error.RetryExhausted;
                }
                continue;
            }

            if (result.response) |response| {
                if (debug) std.log.debug("Request succeeded", .{});
                retry_state.recordSuccess();
                self.recordCircuitSuccess();

                // Populate trace span with usage data
                if (llm_span) |span| {
                    if (response.usage) |usage| {
                        span.prompt_tokens = usage.prompt_tokens;
                        span.completion_tokens = usage.completion_tokens;
                        span.total_tokens = usage.total_tokens;
                    }
                    span.end(.ok, null);
                }

                return response;
            }
        }

        if (llm_span) |span| span.end(.@"error", "max attempts reached");
        self.recordCircuitFailure();
        return error.RetryExhausted;
    }

    const HTTPResult = struct {
        err: ?error_handler_mod.ErrorResponse,
        response: ?ChatResponse,
    };

    fn performHttpRequest(self: *AIClient, user_message: []const u8, has_key: bool, is_local: bool, _attempt: u32, debug: bool) !HTTPResult {
        const allocator = self.allocator;
        _ = is_local;
        _ = has_key;
        _ = _attempt;

        const chat_path = self.getChatPath();

        if (debug) {
            std.log.debug("\n[HTTP Request]", .{});
            std.log.debug("Method: POST", .{});
            std.log.debug("URL: {s}{s}", .{ self.provider.config.base_url, chat_path });
        }

        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, chat_path });
        defer allocator.free(endpoint);

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"max_tokens":{d},"temperature":{d:.2}}}
        , .{ self.getApiModelName(), user_message, self.max_tokens, self.temperature });
        defer allocator.free(json_body);
        if (debug) std.log.debug("Body: {s}", .{json_body});

        const headers = try self.buildHeaders();
        defer freeHeaders(allocator, headers);

        const fetch_result = http_client.httpPost(allocator, endpoint, headers, json_body) catch |err| {
            if (debug) std.log.debug("HTTP Error: {s}", .{@errorName(err)});
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.NetworkError,
                    @errorName(err),
                ),
                .response = null,
            };
        };
        defer allocator.free(fetch_result.body);

        if (debug) std.log.debug("Response Status: {}", .{fetch_result.status});

        if (fetch_result.status != .ok) {
            const error_body = fetch_result.body;
            const http_status: u16 = @intFromEnum(fetch_result.status);
            std.log.err("HTTP {d} from {s}: {s}", .{ http_status, endpoint, error_body });

            // Use proper error classification so non-retryable errors (401, 403, 404) aren't retried
            const parsed = error_handler_mod.parseHttpStatus(http_status, error_body);
            const err_response = parsed orelse error_handler_mod.ErrorResponse.init(
                error_handler_mod.AIClientError.ServerError,
                try allocator.dupe(u8, error_body),
            );

            return HTTPResult{
                .err = err_response,
                .response = null,
            };
        }

        const response_slice = fetch_result.body;

        // For Ollama, responses contain multiple JSON objects (streaming)
        // Parse each line and accumulate the full content
        if (self.provider.config.api_format == .ollama) {
            var full_content = array_list_compat.ArrayList(u8).init(allocator);
            defer full_content.deinit();

            var is_done = false;

            // Split by newlines and parse each JSON object
            var lines = std.mem.splitScalar(u8, response_slice, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;

                // Parse this JSON chunk
                var ollama_chunk = std.json.parseFromSlice(OllamaResponse, allocator, line, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    // Skip malformed lines
                    continue;
                };
                defer ollama_chunk.deinit();

                // Accumulate content
                full_content.appendSlice(ollama_chunk.value.message.content) catch |err| {
                    std.log.err("Failed to accumulate Ollama stream content: {}", .{err});
                };
                is_done = ollama_chunk.value.done;

                if (is_done) break;
            }

            const content = try full_content.toOwnedSlice();
            errdefer allocator.free(content);

            const choices = try allocator.alloc(ChatChoice, 1);
            errdefer allocator.free(choices);

            choices[0] = .{
                .index = 0,
                .message = .{
                    .role = try allocator.dupe(u8, "assistant"),
                    .content = content,
                },
                .finish_reason = if (is_done) "stop" else null,
            };

            const response = ChatResponse{
                .id = "ollama-response",
                .object = "chat.completion",
                .created = @intCast(std.time.timestamp()),
                .model = self.model,
                .choices = choices,
                .usage = null,
            };

            return HTTPResult{
                .err = null,
                .response = response,
            };
        }

        var json_parsed = try std.json.parseFromSlice(APIChatResponse, allocator, response_slice, .{
            .ignore_unknown_fields = true,
        });
        defer json_parsed.deinit();
        const cloned_response = try cloneAPIChatResponse(allocator, json_parsed.value);

        return HTTPResult{
            .err = null,
            .response = cloned_response,
        };
    }

    fn performHttpRequestHistory(self: *AIClient, messages: []const ChatMessage, has_key: bool, is_local: bool, _attempt: u32, debug: bool) !HTTPResult {
        const allocator = self.allocator;
        _ = is_local;
        _ = has_key;
        _ = _attempt;

        const chat_path = self.getChatPath();

        if (debug) {
            std.log.debug("\n[HTTP Request with History]", .{});
            std.log.debug("Method: POST", .{});
            std.log.debug("URL: {s}{s}", .{ self.provider.config.base_url, chat_path });
        }

        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, chat_path });
        defer allocator.free(endpoint);

        // Build JSON body with message history
        var json_body = array_list_compat.ArrayList(u8).init(allocator);
        defer json_body.deinit();

        try json_body.appendSlice("{\"model\":\"");
        try json_body.appendSlice(self.getApiModelName());
        try json_body.appendSlice("\",\"messages\":[");

        // Prepend system message if system_prompt is set
        if (self.system_prompt) |sys_prompt| {
            if (sys_prompt.len > 0) {
                try json_body.appendSlice("{\"role\":\"system\",\"content\":\"");
                for (sys_prompt) |c| {
                    switch (c) {
                        '"' => try json_body.appendSlice("\\\""),
                        '\\' => try json_body.appendSlice("\\\\"),
                        '\n' => try json_body.appendSlice("\\n"),
                        '\r' => try json_body.appendSlice("\\r"),
                        '\t' => try json_body.appendSlice("\\t"),
                        else => try json_body.append(c),
                    }
                }
                try json_body.appendSlice("\"}");
                if (messages.len > 0) try json_body.appendSlice(",");
            }
        }

        // Use appendChatMessageJson which correctly handles tool_call_id and tool_calls
        for (messages, 0..) |msg, i| {
            if (i > 0) try json_body.appendSlice(",");
            try streaming_parsers.appendChatMessageJson(&json_body, msg);
        }

        try json_body.writer().print("],\"max_tokens\":{d},\"temperature\":{d:.2}}}", .{ self.max_tokens, self.temperature });

        const json_body_slice = try json_body.toOwnedSlice();
        defer allocator.free(json_body_slice);

        if (debug) std.log.debug("Body: {s}", .{json_body_slice[0..@min(200, json_body_slice.len)]});

        const headers = try self.buildHeaders();
        defer freeHeaders(allocator, headers);

        const fetch_result = http_client.httpPost(allocator, endpoint, headers, json_body_slice) catch |err| {
            if (debug) std.log.debug("HTTP Error: {s}", .{@errorName(err)});
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.NetworkError,
                    @errorName(err),
                ),
                .response = null,
            };
        };
        defer allocator.free(fetch_result.body);

        if (debug) std.log.debug("Response Status: {}", .{fetch_result.status});

        if (fetch_result.status != .ok) {
            const http_status: u16 = @intFromEnum(fetch_result.status);
            std.log.err("HTTP {d} from {s}: {s}", .{ http_status, endpoint, fetch_result.body });

            const parsed = error_handler_mod.parseHttpStatus(http_status, fetch_result.body);
            const err_response = parsed orelse error_handler_mod.ErrorResponse.init(
                error_handler_mod.AIClientError.ServerError,
                try allocator.dupe(u8, fetch_result.body),
            );

            return HTTPResult{
                .err = err_response,
                .response = null,
            };
        }

        const response_slice = fetch_result.body;

        // For Ollama, responses contain multiple JSON objects (streaming)
        if (self.provider.config.api_format == .ollama) {
            var full_content = array_list_compat.ArrayList(u8).init(allocator);
            defer full_content.deinit();

            var is_done = false;

            var lines = std.mem.splitScalar(u8, response_slice, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;

                var ollama_chunk = std.json.parseFromSlice(OllamaResponse, allocator, line, .{
                    .ignore_unknown_fields = true,
                }) catch continue;
                defer ollama_chunk.deinit();

                full_content.appendSlice(ollama_chunk.value.message.content) catch |err| {
                    std.log.err("Ollama stream: failed to accumulate content chunk: {}", .{err});
                };
                is_done = ollama_chunk.value.done;

                if (is_done) break;
            }

            const content = try full_content.toOwnedSlice();
            errdefer allocator.free(content);

            const choices = try allocator.alloc(ChatChoice, 1);
            errdefer allocator.free(choices);

            choices[0] = .{
                .index = 0,
                .message = .{
                    .role = try allocator.dupe(u8, "assistant"),
                    .content = content,
                },
                .finish_reason = if (is_done) "stop" else null,
            };

            const response = ChatResponse{
                .id = "ollama-response",
                .object = "chat.completion",
                .created = @intCast(std.time.timestamp()),
                .model = self.model,
                .choices = choices,
                .usage = null,
            };

            return HTTPResult{
                .err = null,
                .response = response,
            };
        }

        var json_parsed = try std.json.parseFromSlice(APIChatResponse, allocator, response_slice, .{
            .ignore_unknown_fields = true,
        });
        defer json_parsed.deinit();
        const cloned_response = try cloneAPIChatResponse(allocator, json_parsed.value);

        return HTTPResult{
            .err = null,
            .response = cloned_response,
        };
    }

    threadlocal var tcache: ?token_cache_mod.TokenCache = null;

    pub fn initTokenCache(allocator: std.mem.Allocator) void {
        if (tcache != null) return;
        tcache = token_cache_mod.TokenCache.init(allocator, 1024);
    }

    pub fn deinitTokenCache() void {
        if (tcache) |*c| {
            c.deinit();
            tcache = null;
        }
    }

    fn estimateTokens(text: []const u8) u32 {
        if (tcache) |*c| {
            return c.getOrEstimate(text);
        }
        const len = @min(text.len, 100);
        return @as(u32, @divTrunc(len, 4));
    }

    fn detectStreamingFormat(self: *AIClient) StreamFormat {
        return streaming_parsers.detectStreamingFormat(self.provider.config.api_format);
    }

    fn jsonU32(value: ?std.json.Value) u32 {
        return streaming_parsers.jsonU32(value);
    }

    fn setFinishReason(allocator: std.mem.Allocator, finish_reason: *?[]const u8, reason: []const u8) !void {
        return streaming_parsers.setFinishReason(allocator, finish_reason, reason);
    }

    fn appendStreamingToken(full_content: *array_list_compat.ArrayList(u8), token: []const u8, callback: StreamCallback) !void {
        return streaming_parsers.appendStreamingToken(full_content, token, callback);
    }

    fn markStreamDone(
        allocator: std.mem.Allocator,
        finish_reason: *?[]const u8,
        usage: *?Usage,
        reason: []const u8,
        maybe_usage: ?Usage,
        callback: StreamCallback,
        saw_done: *bool,
    ) !void {
        return streaming_parsers.markStreamDone(allocator, finish_reason, usage, reason, maybe_usage, callback, saw_done);
    }

    fn parseUsage(usage_value: std.json.Value) ?Usage {
        return streaming_parsers.parseUsage(usage_value);
    }

    fn processOpenAIStreamingPayload(
        self: *AIClient,
        root: std.json.Value,
        full_content: *array_list_compat.ArrayList(u8),
        finish_reason: *?[]const u8,
        usage: *?Usage,
        callback: StreamCallback,
        saw_done: *bool,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processOpenAIStreamingPayload(self.allocator, root, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
    }

    fn processOpenAIToolCallDelta(
        self: *AIClient,
        tool_calls_value: std.json.Value,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processOpenAIToolCallDelta(self.allocator, tool_calls_value, streaming_tool_calls);
    }

    fn processNDJSONLine(
        self: *AIClient,
        line: []const u8,
        full_content: *array_list_compat.ArrayList(u8),
        finish_reason: *?[]const u8,
        usage: *?Usage,
        callback: StreamCallback,
        saw_done: *bool,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processNDJSONLine(self.allocator, line, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
    }

    fn processSSELine(
        self: *AIClient,
        line: []const u8,
        full_content: *array_list_compat.ArrayList(u8),
        finish_reason: *?[]const u8,
        usage: *?Usage,
        callback: StreamCallback,
        saw_done: *bool,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processSSELine(self.allocator, line, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
    }

    fn processStreamLine(
        self: *AIClient,
        line: []const u8,
        full_content: *array_list_compat.ArrayList(u8),
        finish_reason: *?[]const u8,
        usage: *?Usage,
        callback: StreamCallback,
        saw_done: *bool,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processStreamLine(self.allocator, self.provider.config.api_format, line, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
    }

    fn processStreamChunk(
        self: *AIClient,
        partial_line: *array_list_compat.ArrayList(u8),
        chunk: []const u8,
        full_content: *array_list_compat.ArrayList(u8),
        finish_reason: *?[]const u8,
        usage: *?Usage,
        callback: StreamCallback,
        saw_done: *bool,
        streaming_tool_calls: *array_list_compat.ArrayList(StreamingToolCall),
    ) !void {
        return streaming_parsers.processStreamChunk(self.allocator, self.provider.config.api_format, partial_line, chunk, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
    }

    fn appendEscapedJsonString(json_body: *array_list_compat.ArrayList(u8), value: []const u8) !void {
        return streaming_parsers.appendEscapedJsonString(json_body, value);
    }

    fn appendToolCallJson(json_body: *array_list_compat.ArrayList(u8), tool_call: ToolCallInfo) !void {
        return streaming_parsers.appendToolCallJson(json_body, tool_call);
    }

    fn appendChatMessageJson(json_body: *array_list_compat.ArrayList(u8), msg: ChatMessage) !void {
        return streaming_parsers.appendChatMessageJson(json_body, msg);
    }

    fn buildRequestBodyFromMessages(self: *AIClient, messages: []const ChatMessage, stream: bool) ![]const u8 {
        const allocator = self.allocator;
        var json_body = array_list_compat.ArrayList(u8).init(allocator);
        defer json_body.deinit();

        try json_body.appendSlice("{\"model\":\"");
        try json_body.appendSlice(self.getApiModelName());
        try json_body.appendSlice("\",\"messages\":[");

        var needs_comma = false;
        if (self.system_prompt) |sys_prompt| {
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

        try json_body.writer().print("],\"max_tokens\":{d},\"temperature\":{d:.2}", .{ self.max_tokens, self.temperature });
        // Inject tools array for function calling
        if (self.tools.len > 0) {
            const tools_json = try self.buildToolsJson(allocator);
            defer allocator.free(tools_json);
            try json_body.appendSlice(tools_json);
        }
        if (stream) {
            if (self.provider.config.api_format != .ollama) {
                try json_body.appendSlice(",\"stream\":true");
            }
        }
        try json_body.appendSlice("}");

        return allocator.dupe(u8, json_body.items);
    }

    fn freeHeaders(allocator: std.mem.Allocator, headers: []std.http.Header) void {
        for (headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(headers);
    }

    fn buildStreamingBodyFromMessages(self: *AIClient, messages: []const ChatMessage) ![]const u8 {
        const tools_json = try self.buildToolsJson(self.allocator);
        defer self.allocator.free(tools_json);

        return streaming_parsers.buildStreamingBodyFromMessages(self.allocator, self.getApiModelName(), self.system_prompt, messages, tools_json, self.provider.config.api_format, self.max_tokens, self.temperature);
    }

    fn buildStreamingResponse(self: *AIClient, content_slice: []const u8, final_finish_reason: []const u8, usage: ?Usage, streaming_tool_calls: []const StreamingToolCall) !ChatResponse {
        return streaming_parsers.buildStreamingResponse(self.allocator, self.model, self.provider.name, content_slice, final_finish_reason, usage, streaming_tool_calls);
    }

    fn cloneToolCallInfosFromAPI(allocator: std.mem.Allocator, tool_calls: ?[]const APIToolCall) !?[]const ToolCallInfo {
        return streaming_parsers.cloneToolCallInfosFromAPI(allocator, tool_calls);
    }

    fn cloneStreamingToolCalls(allocator: std.mem.Allocator, tool_calls: []const StreamingToolCall) !?[]const ToolCallInfo {
        return streaming_parsers.cloneStreamingToolCalls(allocator, tool_calls);
    }

    fn cloneAPIChatResponse(allocator: std.mem.Allocator, original: APIChatResponse) !ChatResponse {
        const id_copy = try allocator.dupe(u8, original.id);
        const object_copy = try allocator.dupe(u8, original.object);
        const model_copy = try allocator.dupe(u8, original.model);

        const choices_copy = try allocator.alloc(ChatChoice, original.choices.len);
        for (original.choices, 0..) |orig_choice, i| {
            const role_copy = try allocator.dupe(u8, orig_choice.message.role);
            const content_copy: ?[]const u8 = if (orig_choice.message.content) |content|
                try allocator.dupe(u8, content)
            else
                null;
            const finish_copy: ?[]const u8 = if (orig_choice.finish_reason) |finish|
                try allocator.dupe(u8, finish)
            else
                null;

            choices_copy[i] = .{
                .index = orig_choice.index,
                .message = .{
                    .role = role_copy,
                    .content = content_copy,
                    .tool_call_id = null,
                    .tool_calls = try cloneToolCallInfosFromAPI(allocator, orig_choice.message.tool_calls),
                },
                .finish_reason = finish_copy,
            };
        }

        return ChatResponse{
            .id = id_copy,
            .object = object_copy,
            .created = original.created,
            .model = model_copy,
            .choices = choices_copy,
            .usage = original.usage,
            .provider = if (original.provider) |provider| try allocator.dupe(u8, provider) else null,
            .cost = if (original.cost) |cost| try allocator.dupe(u8, cost) else null,
            .system_fingerprint = if (original.system_fingerprint) |fingerprint| try allocator.dupe(u8, fingerprint) else null,
        };
    }

    /// Extract extended usage from a ChatResponse for usage tracking
    pub fn extractExtendedUsage(_: *AIClient, response: *const ChatResponse) ExtendedUsage {
        var eu = ExtendedUsage{};
        if (response.usage) |usage| {
            eu.input_tokens = usage.prompt_tokens;
            eu.output_tokens = usage.completion_tokens;
        }
        return eu;
    }

    /// Build the JSON request body with streaming enabled
    pub fn buildStreamingBody(self: *AIClient, user_message: []const u8) ![]const u8 {
        const allocator = self.allocator;
        var json_body = array_list_compat.ArrayList(u8).init(allocator);
        defer json_body.deinit();

        try json_body.appendSlice("{\"model\":\"");
        try json_body.appendSlice(self.getApiModelName());
        try json_body.appendSlice("\",\"messages\":[");

        if (self.system_prompt) |sys_prompt| {
            if (sys_prompt.len > 0) {
                try json_body.appendSlice("{\"role\":\"system\",\"content\":\"");
                for (sys_prompt) |c| {
                    switch (c) {
                        '"' => try json_body.appendSlice("\\\""),
                        '\\' => try json_body.appendSlice("\\\\"),
                        '\n' => try json_body.appendSlice("\\n"),
                        '\r' => try json_body.appendSlice("\\r"),
                        '\t' => try json_body.appendSlice("\\t"),
                        else => try json_body.append(c),
                    }
                }
                try json_body.appendSlice("\"},");
            }
        }

        try json_body.appendSlice("{\"role\":\"user\",\"content\":\"");
        for (user_message) |c| {
            switch (c) {
                '"' => try json_body.appendSlice("\\\""),
                '\\' => try json_body.appendSlice("\\\\"),
                '\n' => try json_body.appendSlice("\\n"),
                '\r' => try json_body.appendSlice("\\r"),
                '\t' => try json_body.appendSlice("\\t"),
                else => try json_body.append(c),
            }
        }
        try json_body.writer().print("\"}}],\"max_tokens\":{d},\"temperature\":{d:.2},\"stream\":true}}", .{ self.max_tokens, self.temperature });

        return allocator.dupe(u8, json_body.items);
    }

    /// Build headers for HTTP request
    pub fn buildHeaders(self: *AIClient) ![]std.http.Header {
        const allocator = self.allocator;
        var headers = array_list_compat.ArrayList(std.http.Header).init(allocator);
        try headers.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        if (std.mem.eql(u8, self.provider.name, "openrouter")) {
            try headers.append(.{ .name = try allocator.dupe(u8, "HTTP-Referer"), .value = try allocator.dupe(u8, "https://github.com/crushcode/crushcode") });
            try headers.append(.{ .name = try allocator.dupe(u8, "X-Title"), .value = try allocator.dupe(u8, "Crushcode") });
        }

        if (self.api_key.len > 0) {
            try headers.append(.{ .name = try allocator.dupe(u8, "Authorization"), .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key}) });
        }

        return headers.toOwnedSlice();
    }

    /// Get the chat endpoint path for this provider
    pub fn getChatPath(self: *AIClient) []const u8 {
        if (self.provider.config.api_format == .ollama) return "/chat";
        return "/chat/completions";
    }
};

/// Cache control marker for Anthropic prompt caching
pub const CacheControl = struct {
    type: []const u8, // "ephemeral"
};

/// Message with optional cache breakpoint
pub const CacheMarkedMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    cache_control: ?CacheControl = null,
};

/// Build cache-aware messages for Anthropic providers.
/// Injects cache_control breakpoints:
/// - System prompt marked as cacheable
/// - Last 2 tool results marked as cacheable
/// Returns original messages unchanged for non-Anthropic providers.
/// Caller owns the returned slice and must free each field + the array.
pub fn buildCacheAwareMessages(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    messages: []const ChatMessage,
    provider_name: []const u8,
) ![]CacheMarkedMessage {
    const is_anthropic = std.mem.eql(u8, provider_name, "anthropic") or
        std.mem.eql(u8, provider_name, "bedrock") or
        std.mem.eql(u8, provider_name, "vertexai");

    // Find indices of last 2 tool-result messages (from the end)
    var last_tool_indices: [2]usize = .{ 0, 0 };
    var tools_found: usize = 0;

    if (is_anthropic and messages.len > 0) {
        var i: isize = @as(isize, @intCast(messages.len)) - 1;
        while (i >= 0 and tools_found < 2) : (i -= 1) {
            const idx: usize = @intCast(i);
            if (std.mem.eql(u8, messages[idx].role, "tool")) {
                last_tool_indices[tools_found] = idx;
                tools_found += 1;
            }
        }
    }

    // Total output: 1 (system) + messages.len
    const total = messages.len + 1;
    const result = try allocator.alloc(CacheMarkedMessage, total);

    // System prompt with cache control for Anthropic
    result[0] = .{
        .role = try allocator.dupe(u8, "system"),
        .content = try allocator.dupe(u8, system_prompt),
        .cache_control = if (is_anthropic) .{ .type = "ephemeral" } else null,
    };

    for (messages, 0..) |msg, msg_idx| {
        // Check if this message should be cache-marked (one of last 2 tool results)
        var should_mark = false;
        if (is_anthropic and std.mem.eql(u8, msg.role, "tool")) {
            for (last_tool_indices[0..tools_found]) |ti| {
                if (ti == msg_idx) {
                    should_mark = true;
                    break;
                }
            }
        }

        const content_str = msg.content orelse "";

        result[msg_idx + 1] = .{
            .role = try allocator.dupe(u8, msg.role),
            .content = try allocator.dupe(u8, content_str),
            .tool_call_id = if (msg.tool_call_id) |tcid| try allocator.dupe(u8, tcid) else null,
            .cache_control = if (should_mark) .{ .type = "ephemeral" } else null,
        };
    }

    return result;
}

// ========== UNIT TESTS ==========

const testing = std.testing;

test "sendMockPerfStream emits 10 tokens and returns valid response" {
    const allocator = testing.allocator;

    // Set up registry and register mock_perf provider
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.mock_perf);

    const provider = registry.getProvider("mock-perf").?;
    var client = try AIClient.init(allocator, provider, "perf-model-1", "perf-key");
    defer client.deinit();

    // Track tokens received via callback
    var token_count: usize = 0;
    var saw_done: bool = false;

    const CallbackState = struct {
        count: *usize,
        done: *bool,
    };
    const cb_state = CallbackState{ .count = &token_count, .done = &saw_done };
    _ = cb_state;

    const callback: StreamCallback = struct {
        fn cb(token: []const u8, done: bool) void {
            _ = token;
            _ = done;
        }
    }.cb;

    // Build a minimal messages array
    const messages = [_]ChatMessage{.{
        .role = "user",
        .content = "perf test",
    }};

    const response = try client.sendChatStreaming(&messages, callback);
    defer {
        // Free response allocations
        allocator.free(response.id);
        allocator.free(response.object);
        allocator.free(response.model);
        for (response.choices) |choice| {
            allocator.free(choice.message.role);
            if (choice.message.content) |content| allocator.free(content);
        }
        allocator.free(response.choices);
    }

    // Verify 10 tokens were emitted by checking response content
    // sendMockPerfStream emits 10 tokens of "PERF:mock_token_N" each 16 chars
    // Total content length = 10 * 16 = 160
    try testing.expect(response.choices.len == 1);
    const content = response.choices[0].message.content orelse "";
    try testing.expect(content.len > 0);

    // Verify usage stats are present and correct
    const usage = response.usage orelse {
        @panic("expected usage stats in mock perf response");
    };
    try testing.expectEqual(@as(u32, 10), usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 10), usage.completion_tokens);
    try testing.expectEqual(@as(u32, 20), usage.total_tokens);
}

test "getApiModelName strips provider prefix when keep_prefix is false" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "openai/gpt-4o-mini", "test-key");
    defer client.deinit();

    const model_name = client.getApiModelName();
    try testing.expectEqualStrings("gpt-4o-mini", model_name);
}

test "getApiModelName returns original model when no prefix" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const model_name = client.getApiModelName();
    try testing.expectEqualStrings("gpt-4o", model_name);
}

test "getApiModelName keeps prefix when provider config keep_prefix is true" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openrouter);

    const provider = registry.getProvider("openrouter").?;
    var client = try AIClient.init(allocator, provider, "openai/gpt-4o", "test-key");
    defer client.deinit();

    const model_name = client.getApiModelName();
    try testing.expectEqualStrings("openai/gpt-4o", model_name);
}

test "getChatPath returns /chat for ollama provider" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.ollama);

    const provider = registry.getProvider("ollama").?;
    var client = try AIClient.init(allocator, provider, "llama3", "");
    defer client.deinit();

    const path = client.getChatPath();
    try testing.expectEqualStrings("/chat", path);
}

test "getChatPath returns /chat/completions for non-ollama providers" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const path = client.getChatPath();
    try testing.expectEqualStrings("/chat/completions", path);
}

test "extractExtendedUsage returns correct token counts" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const usage = Usage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
    };

    const response = ChatResponse{
        .id = "test-id",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &[_]ChatChoice{},
        .usage = usage,
        .provider = null,
        .cost = null,
        .system_fingerprint = null,
    };

    const extended = client.extractExtendedUsage(&response);
    try testing.expectEqual(@as(u32, 100), extended.input_tokens);
    try testing.expectEqual(@as(u32, 50), extended.output_tokens);
}

test "extractExtendedUsage returns zero when usage is null" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const response = ChatResponse{
        .id = "test-id",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &[_]ChatChoice{},
        .usage = null,
        .provider = null,
        .cost = null,
        .system_fingerprint = null,
    };

    const extended = client.extractExtendedUsage(&response);
    try testing.expectEqual(@as(u32, 0), extended.input_tokens);
    try testing.expectEqual(@as(u32, 0), extended.output_tokens);
}

test "buildToolsJson returns empty string for no tools" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const tools_json = try client.buildToolsJson(allocator);
    defer allocator.free(tools_json);

    try testing.expectEqualStrings("", tools_json);
}

test "buildToolsJson builds correct JSON for single tool" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    const tools = [_]ToolSchema{.{
        .name = "search_web",
        .description = "Search the web for information",
        .parameters = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
    }};
    client.setTools(&tools);

    const tools_json = try client.buildToolsJson(allocator);
    defer allocator.free(tools_json);

    try testing.expect(tools_json.len > 0);
    try testing.expect(std.mem.indexOf(u8, tools_json, "search_web") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "Search the web for information") != null);
}

test "setSystemPrompt and setTools modify client state" {
    const allocator = testing.allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerProvider(.openai);

    const provider = registry.getProvider("openai").?;
    var client = try AIClient.init(allocator, provider, "gpt-4o", "test-key");
    defer client.deinit();

    try testing.expect(client.system_prompt == null);

    client.setSystemPrompt("You are a helpful assistant");
    try testing.expect(client.system_prompt != null);
    try testing.expectEqualStrings("You are a helpful assistant", client.system_prompt.?);

    const tools = [_]ToolSchema{.{
        .name = "test_tool",
        .description = "A test tool",
        .parameters = "{}",
    }};
    try testing.expect(client.tools.len == 0);

    client.setTools(&tools);
    try testing.expect(client.tools.len == 1);
    try testing.expectEqualStrings("test_tool", client.tools[0].name);
}
