const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Error types for AI client operations
pub const AIClientError = error{
    NetworkError,
    AuthenticationError,
    RateLimitError,
    TokenLimitError,
    InvalidRequest,
    ModelNotFound,
    ServerError,
    TimeoutError,
    InvalidResponse,
    ConfigurationError,
    RetryExhausted,
};

/// Configuration for retry logic
/// NOTE: agent/loop.zig has its own RetryConfig with sleep/wait methods
/// and u64/f64 fields. Keep in sync or merge if use cases converge.
pub const RetryConfig = struct {
    max_attempts: u32 = 3,
    base_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 30000,
    backoff_multiplier: f32 = 2.0,
    jitter: bool = true,

    pub fn default() RetryConfig {
        return RetryConfig{};
    }

    pub fn aggressive() RetryConfig {
        return RetryConfig{
            .max_attempts = 5,
            .base_delay_ms = 500,
            .max_delay_ms = 60000,
        };
    }

    pub fn conservative() RetryConfig {
        return RetryConfig{
            .max_attempts = 2,
            .base_delay_ms = 2000,
            .max_delay_ms = 10000,
        };
    }
};

/// Rate limiter for API requests
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    requests_per_minute: u32,
    request_times: array_list_compat.ArrayList(i64),

    pub fn init(allocator: std.mem.Allocator, requests_per_minute: u32) !RateLimiter {
        return RateLimiter{
            .allocator = allocator,
            .requests_per_minute = requests_per_minute,
            .request_times = array_list_compat.ArrayList(i64).init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.request_times.deinit();
    }

    pub fn checkRateLimit(self: *RateLimiter) !void {
        const now = std.time.timestamp();
        const one_minute_ago = now - 60;

        // Remove old requests
        var i: usize = 0;
        while (i < self.request_times.items.len) {
            if (self.request_times.items[i] < one_minute_ago) {
                _ = self.request_times.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check if we're at the limit
        if (self.request_times.items.len >= self.requests_per_minute) {
            // Calculate wait time
            const oldest_request = self.request_times.items[0];
            const wait_time = @max(0, (oldest_request + 60) - now);

            if (wait_time > 0) {
                std.log.warn("Rate limit reached. Waiting {d} seconds...", .{wait_time});
                // Note: In real implementation, use proper sleep
                // std.time.sleep(@as(u64, @intCast(wait_time * std.time.ns_per_s)));
                return error.RateLimitError;
            }
        }

        // Add current request
        try self.request_times.append(now);
    }
};

/// Error response from API
pub const ErrorResponse = struct {
    error_type: AIClientError,
    message: []const u8,
    code: ?[]const u8 = null,
    retry_after: ?u32 = null, // seconds

    pub fn init(error_type: AIClientError, message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = error_type,
            .message = message,
        };
    }

    pub fn withCode(error_type: AIClientError, message: []const u8, code: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = error_type,
            .message = message,
            .code = code,
        };
    }

    pub fn withRetryAfter(error_type: AIClientError, message: []const u8, retry_after: u32) ErrorResponse {
        return ErrorResponse{
            .error_type = error_type,
            .message = message,
            .retry_after = retry_after,
        };
    }
};

/// Parse HTTP status code into appropriate error
pub fn parseHttpStatus(status: u16, body: []const u8) ?ErrorResponse {
    _ = body; // Suppress unused parameter for now
    return switch (status) {
        400 => ErrorResponse.init(AIClientError.InvalidRequest, "Bad request - check your input"),
        401 => ErrorResponse.init(AIClientError.AuthenticationError, "Invalid API key"),
        403 => ErrorResponse.init(AIClientError.AuthenticationError, "Access forbidden - check permissions"),
        404 => ErrorResponse.init(AIClientError.ModelNotFound, "Model not found"),
        429 => ErrorResponse.withRetryAfter(AIClientError.RateLimitError, "Rate limit exceeded", 60),
        500...599 => ErrorResponse.init(AIClientError.ServerError, "Server error - please try again"),
        else => null,
    };
}

/// Calculate delay with exponential backoff and optional jitter
pub fn calculateDelay(attempt: u32, config: RetryConfig) u32 {
    // Exponential backoff: base_delay * multiplier^attempt
    const base_delay = @as(f32, @floatFromInt(config.base_delay_ms)) *
        std.math.pow(f32, config.backoff_multiplier, @as(f32, @floatFromInt(attempt)));

    var delay = @as(u32, @intFromFloat(base_delay));

    // Apply jitter if enabled
    if (config.jitter and delay > 100) {
        const jitter_range = @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay)) * 0.1));
        const jitter = std.crypto.random.intRangeAtMost(u32, 0, jitter_range);
        delay += jitter;
    }

    // Cap at max delay
    return @min(delay, config.max_delay_ms);
}

/// Determine if error is retryable
pub fn isRetryableError(error_type: AIClientError) bool {
    return switch (error_type) {
        AIClientError.NetworkError, AIClientError.RateLimitError, AIClientError.ServerError, AIClientError.TimeoutError => true,

        AIClientError.AuthenticationError, AIClientError.TokenLimitError, AIClientError.InvalidRequest, AIClientError.ModelNotFound, AIClientError.InvalidResponse, AIClientError.ConfigurationError, AIClientError.RetryExhausted => false,
    };
}

/// Format error message for display
pub fn formatError(err: ErrorResponse) []const u8 {
    return switch (err.error_type) {
        AIClientError.NetworkError => "Network connection failed. Check your internet connection.",
        AIClientError.AuthenticationError => "Authentication failed. Check your API key.",
        AIClientError.RateLimitError => "Rate limit exceeded. Please wait before making more requests.",
        AIClientError.TokenLimitError => "Token limit exceeded. Try with a shorter message.",
        AIClientError.InvalidRequest => "Invalid request. Check your input parameters.",
        AIClientError.ModelNotFound => "Model not found. Check if the model name is correct.",
        AIClientError.ServerError => "Server error. Please try again later.",
        AIClientError.TimeoutError => "Request timed out. Please try again.",
        AIClientError.InvalidResponse => "Invalid response from server.",
        AIClientError.ConfigurationError => "Configuration error. Check your settings.",
        AIClientError.RetryExhausted => "Maximum retry attempts exceeded.",
    };
}
