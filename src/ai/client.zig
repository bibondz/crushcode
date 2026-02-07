const std = @import("std");
const registry_mod = @import("registry");
const error_handler_mod = @import("../ai/error_handler.zig");

// Forward declarations
pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
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
};

pub const ChatChoice = struct {
    index: u32,
    message: ChatMessage,
    finish_reason: []const u8,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
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

    pub fn sendChat(self: *AIClient, user_message: []const u8) !ChatResponse {
        // Validate inputs
        if (user_message.len == 0) {
            return error.InvalidRequest; // Use error union instead of ErrorResponse object
        }

        const retry_config = error_handler_mod.RetryConfig.default();
        var attempt: u32 = 0;

        // Early validation for required fields (Law 1)
        if (self.model.len == 0) {
            return error.ConfigurationError; // Use error union instead of ErrorResponse object
        }

        const has_key = self.api_key.len > 0;
        const is_local = std.mem.eql(u8, self.provider.name, "ollama") or
            std.mem.eql(u8, self.provider.name, "lm_studio") or
            std.mem.eql(u8, self.provider.name, "llama_cpp");

        if (!has_key and !is_local) {
            return error.AuthenticationError; // Fail fast with clear error (Law 4)
        }

        _ = self.allocator;

        std.debug.print("\n=== Crushcode AI Client ===\n", .{});
        std.debug.print("Provider: {s}\n", .{self.provider.name});
        std.debug.print("Model: {s}\n", .{self.model});
        std.debug.print("API Endpoint: {s}/chat/completions\n", .{self.provider.config.base_url});
        std.debug.print("User Message: {s}\n", .{user_message});

        while (attempt < retry_config.max_attempts) {
            attempt += 1;

            std.debug.print("\n[Attempt {d}/{d}]\n", .{ attempt, retry_config.max_attempts });

            if (attempt > 1) {
                const delay_ms = error_handler_mod.calculateDelay(attempt - 1, retry_config);
                std.debug.print("Waiting {d}ms before retry...\n", .{delay_ms});
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }

            const result = try performHttpRequest(self, user_message, has_key, is_local, attempt);

            if (result.err) |err| {
                std.debug.print("Request failed: {s}\n", .{error_handler_mod.formatError(err)});

                if (!error_handler_mod.isRetryableError(err.error_type)) {
                    return err; // Fail fast for non-retryable errors (Law 4)
                }

                continue;
            }

            if (result.response) |response| {
                std.debug.print("✅ Request succeeded\n", .{});
                return response;
            }
        }

        // All retries exhausted - fail loud with clear error
        return error.RetryExhausted; // Use error union instead of ErrorResponse object
    }

    fn performHttpRequest(self: *AIClient, user_message: []const u8, has_key: bool, is_local: bool, attempt: u32) !error_handler_mod.RequestResult {
        const allocator = self.allocator;
        _ = has_key; // Suppress unused parameter warning
        _ = is_local; // Suppress unused parameter warning

        std.debug.print("\n[HTTP Request Simulation]\n", .{});
        std.debug.print("Method: POST\n", .{});
        std.debug.print("Headers: Content-Type: application/json, Authorization: Bearer [...]\n", .{});

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"max_tokens":2048,"temperature":0.7}}
        , .{ self.model, user_message });
        defer allocator.free(json_body);
        std.debug.print("Body: {s}\n", .{json_body});

        std.debug.print("\n[Awaiting API Response...]\n", .{});

        // Simulate different error scenarios based on random for testing
        const random_value = std.crypto.random.intRangeAtMost(u8, 100);

        if (random_value < 10) { // 10% chance of network error
            return error_handler_mod.RequestResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.NetworkError,
                    "Simulated network failure",
                ),
                .response = null,
            };
        } else if (random_value < 15) { // 5% chance of rate limit
            return error_handler_mod.RequestResult{
                .err = error_handler_mod.ErrorResponse.withRetryAfter(
                    error_handler_mod.AIClientError.RateLimitError,
                    "Rate limit exceeded",
                    60,
                ),
                .response = null,
            };
        } else if (random_value < 20) { // 5% chance of server error
            return error_handler_mod.RequestResult{
                .err = error_handler_mod.ErrorResponse.init(
                    error_handler_mod.AIClientError.ServerError,
                    "Simulated server error",
                ),
                .response = null,
            };
        }

        // Success case
        const response_content = try std.fmt.allocPrint(allocator,
            \\Hello! This is Crushcode AI speaking.\n\n
            \\I received your message: "{s}"\n\n
            \\This is currently a SIMULATED response with error handling and retry logic.\n
            \\Real HTTP implementation requires Zig 0.16.0+ with stable HTTP client API.\n
            \\See HTTP_CLIENT_NOTES.md for details.\n
            \\Attempt: {d} of {d}
        , .{ user_message, attempt, 5 });

        errdefer allocator.free(response_content);

        const choices = try allocator.alloc(ChatChoice, 1);
        choices[0] = .{
            .index = 0,
            .message = .{
                .role = "assistant",
                .content = response_content,
            },
            .finish_reason = "stop",
        };

        const response = ChatResponse{
            .id = "chatcmpl-simulated-with-retry",
            .object = "chat.completion",
            .created = std.time.timestamp(),
            .model = self.model,
            .choices = choices,
            .usage = Usage{
                .prompt_tokens = estimateTokens(user_message),
                .completion_tokens = estimateTokens(response_content),
                .total_tokens = estimateTokens(user_message) + estimateTokens(response_content),
            },
        };

        return error_handler_mod.RequestResult{
            .err = null,
            .response = response,
        };
    }

    fn estimateTokens(text: []const u8) u32 {
        const len = @min(text.len, 100);
        return @as(u32, @divTrunc(len, 4));
    }
};
