const std = @import("std");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const http_client = @import("http_client");
const registry_mod = @import("registry");
const tool_types = @import("tool_types");
const error_handler_mod = @import("error_handler.zig");
const streaming_parsers = @import("ai_streaming_parsers");

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

    /// Get the actual model name to send to API (strip "opencode/" prefix for Zen/Go)
    pub fn getApiModelName(self: *AIClient) []const u8 {
        if (std.mem.startsWith(u8, self.model, "opencode/")) {
            return self.model["opencode/".len..];
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

    /// Send chat with streaming, calling callback for each token chunk.
    pub fn sendChatStreaming(self: *AIClient, messages: []const ChatMessage, callback: StreamCallback) !ChatResponse {
        if (messages.len == 0) {
            return error.InvalidRequest;
        }

        if (self.model.len == 0) {
            return error.ConfigurationError;
        }

        const has_key = self.api_key.len > 0;
        const is_local = std.mem.eql(u8, self.provider.name, "ollama") or
            std.mem.eql(u8, self.provider.name, "lm_studio") or
            std.mem.eql(u8, self.provider.name, "llama_cpp") or
            std.mem.eql(u8, self.provider.name, "opencode-zen") or
            std.mem.eql(u8, self.provider.name, "opencode-go");

        if (!has_key and !is_local) {
            return error.AuthenticationError;
        }

        const allocator = self.allocator;
        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, self.getChatPath() });
        defer allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);
        const json_body = try self.buildStreamingBodyFromMessages(messages);
        defer allocator.free(json_body);

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

        const retry_config = error_handler_mod.RetryConfig.default();
        var attempt: u32 = 0;

        // Early validation for required fields
        if (self.model.len == 0) {
            return error.ConfigurationError;
        }

        const has_key = self.api_key.len > 0;
        const is_local = std.mem.eql(u8, self.provider.name, "ollama") or
            std.mem.eql(u8, self.provider.name, "lm_studio") or
            std.mem.eql(u8, self.provider.name, "llama_cpp") or
            std.mem.eql(u8, self.provider.name, "opencode-zen") or
            std.mem.eql(u8, self.provider.name, "opencode-go");

        if (!has_key and !is_local) {
            return error.AuthenticationError;
        }

        if (debug) {
            std.log.debug("\n=== Crushcode AI Client ===", .{});
            std.log.debug("Provider: {s}", .{self.provider.name});
            std.log.debug("Model: {s}", .{self.model});
            std.log.debug("API Endpoint: {s}/chat/completions", .{self.provider.config.base_url});
            if (single_message) |msg| {
                std.log.debug("User Message: {s}", .{msg});
            } else if (messages) |msgs| {
                std.log.debug("Messages: {d}", .{msgs.len});
            }
        }

        while (attempt < retry_config.max_attempts) {
            attempt += 1;
            if (debug) std.log.debug("\n[Attempt {d}/{d}]", .{ attempt, retry_config.max_attempts });

            if (attempt > 1) {
                const delay_ms = error_handler_mod.calculateDelay(attempt - 1, retry_config);
                if (debug) std.log.debug("Waiting {d}ms before retry...", .{delay_ms});
                std.Thread.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
            }

            const result = if (single_message != null)
                try self.performHttpRequest(single_message.?, has_key, is_local, attempt, debug)
            else
                try self.performHttpRequestHistory(messages.?, has_key, is_local, attempt, debug);

            if (result.err) |err| {
                if (debug) std.log.debug("Request failed: {s}", .{error_handler_mod.formatError(err)});
                if (!error_handler_mod.isRetryableError(err.error_type)) {
                    return error.RetryExhausted;
                }
                continue;
            }

            if (result.response) |response| {
                if (debug) std.log.debug("✅ Request succeeded", .{});
                return response;
            }
        }

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

        const chat_path = if (std.mem.eql(u8, self.provider.name, "ollama")) "/chat" else if (std.mem.eql(u8, self.provider.name, "opencode-zen")) "/chat/completions" else if (std.mem.eql(u8, self.provider.name, "opencode-go")) "/chat/completions" else "/chat/completions";

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
            if (debug) std.log.debug("Error Response: {s}", .{error_body});
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.ServerError,
                    try allocator.dupe(u8, error_body),
                ),
                .response = null,
            };
        }

        const response_slice = fetch_result.body;

        // For Ollama, responses contain multiple JSON objects (streaming)
        // Parse each line and accumulate the full content
        if (std.mem.eql(u8, self.provider.name, "ollama")) {
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

        const chat_path = if (std.mem.eql(u8, self.provider.name, "ollama")) "/chat" else "/chat/completions";

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
        try json_body.appendSlice(self.model);
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

        for (messages, 0..) |msg, i| {
            if (i > 0) try json_body.appendSlice(",");
            try json_body.appendSlice("{\"role\":\"");
            try json_body.appendSlice(msg.role);
            try json_body.appendSlice("\",\"content\":\"");
            // Escape special characters in content
            const msg_content = msg.content orelse "";
            for (msg_content) |c| {
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
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.ServerError,
                    try allocator.dupe(u8, fetch_result.body),
                ),
                .response = null,
            };
        }

        const response_slice = fetch_result.body;

        // For Ollama, responses contain multiple JSON objects (streaming)
        if (std.mem.eql(u8, self.provider.name, "ollama")) {
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

    fn estimateTokens(text: []const u8) u32 {
        const len = @min(text.len, 100);
        return @as(u32, @divTrunc(len, 4));
    }

    fn detectStreamingFormat(self: *AIClient) StreamFormat {
        return streaming_parsers.detectStreamingFormat(self.provider.name);
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
        return streaming_parsers.processStreamLine(self.allocator, self.provider.name, line, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
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
        return streaming_parsers.processStreamChunk(self.allocator, self.provider.name, partial_line, chunk, full_content, finish_reason, usage, callback, saw_done, streaming_tool_calls);
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
            // Ollama: disable streaming to avoid Zig stdlib HTTP state machine bug
            // The non-streaming path works correctly and returns full response
            if (std.mem.eql(u8, self.provider.name, "ollama")) {
                // Use stream:false - non-streaming works correctly
            } else {
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

        return streaming_parsers.buildStreamingBodyFromMessages(self.allocator, self.getApiModelName(), self.system_prompt, messages, tools_json, self.provider.name, self.max_tokens, self.temperature);
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
        if (std.mem.eql(u8, self.provider.name, "ollama")) return "/chat";
        return "/chat/completions";
    }
};
