const std = @import("std");
const registry_mod = @import("registry");
const error_handler_mod = @import("../ai/error_handler.zig");

// Forward declarations
pub const ChatMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []ChatMessage,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    stream: ?bool = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []ChatChoice,
    usage: ?Usage = null,
    provider: ?[]const u8 = null,
    cost: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,
};

pub const ChatChoice = struct {
    index: u32,
    message: ChatMessage,
    finish_reason: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const OllamaResponse = struct {
    model: []const u8,
    message: OllamaMessage,
    done: bool,
};

pub const OllamaMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const AIClient = struct {
    allocator: std.mem.Allocator,
    provider: registry_mod.Provider,
    model: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, provider: registry_mod.Provider, model: []const u8, api_key: []const u8) !AIClient {
        return AIClient{
            .allocator = allocator,
            .provider = provider,
            .model = model,
            .api_key = api_key,
        };
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
            std.debug.print("\n=== Crushcode AI Client ===\n", .{});
            std.debug.print("Provider: {s}\n", .{self.provider.name});
            std.debug.print("Model: {s}\n", .{self.model});
            std.debug.print("API Endpoint: {s}/chat/completions\n", .{self.provider.config.base_url});
            if (single_message) |msg| {
                std.debug.print("User Message: {s}\n", .{msg});
            } else if (messages) |msgs| {
                std.debug.print("Messages: {d}\n", .{msgs.len});
            }
        }

        while (attempt < retry_config.max_attempts) {
            attempt += 1;
            if (debug) std.debug.print("\n[Attempt {d}/{d}]\n", .{ attempt, retry_config.max_attempts });

            if (attempt > 1) {
                const delay_ms = error_handler_mod.calculateDelay(attempt - 1, retry_config);
                if (debug) std.debug.print("Waiting {d}ms before retry...\n", .{delay_ms});
                std.Thread.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
            }

            const result = if (single_message != null)
                try self.performHttpRequest(single_message.?, has_key, is_local, attempt, debug)
            else
                try self.performHttpRequestHistory(messages.?, has_key, is_local, attempt, debug);

            if (result.err) |err| {
                if (debug) std.debug.print("Request failed: {s}\n", .{error_handler_mod.formatError(err)});
                if (!error_handler_mod.isRetryableError(err.error_type)) {
                    return error.RetryExhausted;
                }
                continue;
            }

            if (result.response) |response| {
                if (debug) std.debug.print("✅ Request succeeded\n", .{});
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
            std.debug.print("\n[HTTP Request]\n", .{});
            std.debug.print("Method: POST\n", .{});
            std.debug.print("URL: {s}{s}\n", .{ self.provider.config.base_url, chat_path });
        }

        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, chat_path });
        defer allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"max_tokens":2048,"temperature":0.7}}
        , .{ self.getApiModelName(), user_message });
        defer allocator.free(json_body);
        if (debug) std.debug.print("Body: {s}\n", .{json_body});

        var response_buf = std.ArrayList(u8).init(allocator);
        defer response_buf.deinit();

        var headers_buf = std.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        if (self.api_key.len > 0) {
            try headers_buf.append(.{ .name = try allocator.dupe(u8, "Authorization"), .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key}) });
        }

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = json_body,
            .extra_headers = headers_buf.items,
            .response_storage = .{ .dynamic = &response_buf },
        }) catch |err| {
            if (debug) std.debug.print("HTTP Error: {!}\n", .{err});
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.NetworkError,
                    @errorName(err),
                ),
                .response = null,
            };
        };

        if (debug) std.debug.print("Response Status: {}\n", .{fetch_result.status});

        if (fetch_result.status != .ok) {
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.ServerError,
                    try response_buf.toOwnedSlice(),
                ),
                .response = null,
            };
        }

        const response_slice = response_buf.items;

        // For Ollama, responses contain multiple JSON objects (streaming)
        // Parse each line and accumulate the full content
        if (std.mem.eql(u8, self.provider.name, "ollama")) {
            var full_content = std.ArrayList(u8).init(allocator);
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
                full_content.appendSlice(ollama_chunk.value.message.content) catch {};
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

        var json_parsed = try std.json.parseFromSlice(ChatResponse, allocator, response_slice, .{
            .ignore_unknown_fields = true,
        });
        defer json_parsed.deinit();

        // Deep clone the response to avoid lifetime issues
        const original = json_parsed.value;

        // Clone id
        const id_copy = try allocator.dupe(u8, original.id);

        // Clone object
        const object_copy = try allocator.dupe(u8, original.object);

        // Clone model
        const model_copy = try allocator.dupe(u8, original.model);

        // Clone choices
        const choices_copy = try allocator.alloc(ChatChoice, original.choices.len);

        for (original.choices, 0..) |orig_choice, i| {
            const role_copy = try allocator.dupe(u8, orig_choice.message.role);

            const content_copy: ?[]const u8 = if (orig_choice.message.content) |c|
                try allocator.dupe(u8, c)
            else
                null;

            const finish_copy: ?[]const u8 = if (orig_choice.finish_reason) |fr|
                try allocator.dupe(u8, fr)
            else
                null;

            choices_copy[i] = .{
                .index = orig_choice.index,
                .message = .{
                    .role = role_copy,
                    .content = content_copy,
                },
                .finish_reason = finish_copy,
            };
        }

        // Clone provider, cost, system_fingerprint if present
        const provider_copy: ?[]const u8 = if (original.provider) |p|
            try allocator.dupe(u8, p)
        else
            null;

        const cost_copy: ?[]const u8 = if (original.cost) |c|
            try allocator.dupe(u8, c)
        else
            null;

        const sf_copy: ?[]const u8 = if (original.system_fingerprint) |sf|
            try allocator.dupe(u8, sf)
        else
            null;

        const cloned_response = ChatResponse{
            .id = id_copy,
            .object = object_copy,
            .created = original.created,
            .model = model_copy,
            .choices = choices_copy,
            .usage = original.usage,
            .provider = provider_copy,
            .cost = cost_copy,
            .system_fingerprint = sf_copy,
        };

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
            std.debug.print("\n[HTTP Request with History]\n", .{});
            std.debug.print("Method: POST\n", .{});
            std.debug.print("URL: {s}{s}\n", .{ self.provider.config.base_url, chat_path });
        }

        const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.provider.config.base_url, chat_path });
        defer allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Build JSON body with message history
        var json_body = std.ArrayList(u8).init(allocator);
        defer json_body.deinit();

        try json_body.appendSlice("{\"model\":\"");
        try json_body.appendSlice(self.model);
        try json_body.appendSlice("\",\"messages\":[");

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

        try json_body.appendSlice("],\"max_tokens\":2048,\"temperature\":0.7}");

        const json_body_slice = try json_body.toOwnedSlice();
        defer allocator.free(json_body_slice);

        if (debug) std.debug.print("Body: {s}\n", .{json_body_slice[0..@min(200, json_body_slice.len)]});

        var response_buf = std.ArrayList(u8).init(allocator);
        defer response_buf.deinit();

        var headers_buf = std.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        if (self.api_key.len > 0) {
            try headers_buf.append(.{ .name = try allocator.dupe(u8, "Authorization"), .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key}) });
        }

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = json_body_slice,
            .extra_headers = headers_buf.items,
            .response_storage = .{ .dynamic = &response_buf },
        }) catch |err| {
            if (debug) std.debug.print("HTTP Error: {!}\n", .{err});
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.NetworkError,
                    @errorName(err),
                ),
                .response = null,
            };
        };

        if (debug) std.debug.print("Response Status: {}\n", .{fetch_result.status});

        if (fetch_result.status != .ok) {
            return HTTPResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.ServerError,
                    try response_buf.toOwnedSlice(),
                ),
                .response = null,
            };
        }

        const response_slice = response_buf.items;

        // For Ollama, responses contain multiple JSON objects (streaming)
        if (std.mem.eql(u8, self.provider.name, "ollama")) {
            var full_content = std.ArrayList(u8).init(allocator);
            defer full_content.deinit();

            var is_done = false;

            var lines = std.mem.splitScalar(u8, response_slice, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;

                var ollama_chunk = std.json.parseFromSlice(OllamaResponse, allocator, line, .{
                    .ignore_unknown_fields = true,
                }) catch continue;
                defer ollama_chunk.deinit();

                full_content.appendSlice(ollama_chunk.value.message.content) catch {};
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

        var json_parsed = try std.json.parseFromSlice(ChatResponse, allocator, response_slice, .{
            .ignore_unknown_fields = true,
        });
        defer json_parsed.deinit();

        return HTTPResult{
            .err = null,
            .response = json_parsed.value,
        };
    }

    fn estimateTokens(text: []const u8) u32 {
        const len = @min(text.len, 100);
        return @as(u32, @divTrunc(len, 4));
    }
};
