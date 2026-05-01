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

// ------------------------------------------------------------
// Tests for error_handler.zig
// ------------------------------------------------------------
test "parseHttpStatus - 400 maps to InvalidRequest" {
    const res = parseHttpStatus(400, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            const _ = e; // keep linter happy
            try std.testing.expect(e.error_type == AIClientError.InvalidRequest);
        },
    }
}

test "parseHttpStatus - 401 maps to AuthenticationError" {
    const res = parseHttpStatus(401, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            try std.testing.expect(e.error_type == AIClientError.AuthenticationError);
        },
    }
}

test "parseHttpStatus - 403 maps to AuthenticationError" {
    const res = parseHttpStatus(403, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            try std.testing.expect(e.error_type == AIClientError.AuthenticationError);
        },
    }
}

test "parseHttpStatus - 404 maps to ModelNotFound" {
    const res = parseHttpStatus(404, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            try std.testing.expect(e.error_type == AIClientError.ModelNotFound);
        },
    }
}

test "parseHttpStatus - 429 maps to RateLimitError with retry_after" {
    const res = parseHttpStatus(429, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            try std.testing.expect(e.error_type == AIClientError.RateLimitError);
            try std.testing.expect(e.retry_after != null);
            try std.testing.expect(e.retry_after orelse 0 == 60);
        },
    }
}

test "parseHttpStatus - 500 maps to ServerError" {
    const res = parseHttpStatus(500, "body");
    switch (res) {
        null => { try std.testing.expect(false); },
        else => |e| {
            try std.testing.expect(e.error_type == AIClientError.ServerError);
        },
    }
}

test "parseHttpStatus - 200 returns null" {
    const res = parseHttpStatus(200, "body");
    try std.testing.expect(res == null);
}

test "parseHttpStatus - 999 returns null" {
    const res = parseHttpStatus(999, "body");
    try std.testing.expect(res == null);
}

test "calculateDelay - 0 returns base delay" {
    const cfg = RetryConfig.default();
    const d = calculateDelay(0, cfg);
    try std.testing.expect(d == cfg.base_delay_ms);
}

test "calculateDelay - 2 returns base * 2^2 (no jitter)" {
    const cfg = RetryConfig{ .max_attempts = 3, .base_delay_ms = 1000, .max_delay_ms = 30000, .backoff_multiplier = 2.0, .jitter = false };
    const d = calculateDelay(2, cfg);
    try std.testing.expect(d == 4000);
}

test "calculateDelay - cap at max_delay" {
    const cfg = RetryConfig{ .max_attempts = 3, .base_delay_ms = 5000, .max_delay_ms = 3000, .backoff_multiplier = 2.0, .jitter = false };
    const d = calculateDelay(0, cfg);
    try std.testing.expect(d == 3000);
}

test "RetryConfig presets" {
    const d = RetryConfig.default();
    try std.testing.expect(d.max_attempts == 3);
    try std.testing.expect(d.base_delay_ms == 1000);
    try std.testing.expect(d.max_delay_ms == 30000);
    try std.testing.expect(d.backoff_multiplier == 2.0);
    try std.testing.expect(d.jitter == true);

    const a = RetryConfig.aggressive();
    try std.testing.expect(a.max_attempts == 5);
    try std.testing.expect(a.base_delay_ms == 500);
    try std.testing.expect(a.max_delay_ms == 60000);

    const c = RetryConfig.conservative();
    try std.testing.expect(c.max_attempts == 2);
    try std.testing.expect(c.base_delay_ms == 2000);
    try std.testing.expect(c.max_delay_ms == 10000);
}

test "calculateDelay - aggressive preset" {
    const cfg = RetryConfig.aggressive();
    const d = calculateDelay(4, cfg);
    try std.testing.expect(d == 8000);
}

test "calculateDelay - conservative preset cap" {
    const cfg = RetryConfig.conservative();
    const d = calculateDelay(4, cfg);
    try std.testing.expect(d == 10000);
}

test "isRetryableError - common retryable values" {
    try std.testing.expect(isRetryableError(AIClientError.NetworkError));
    try std.testing.expect(isRetryableError(AIClientError.RateLimitError));
    try std.testing.expect(isRetryableError(AIClientError.ServerError));
    try std.testing.expect(isRetryableError(AIClientError.TimeoutError));
    try std.testing.expect(!isRetryableError(AIClientError.AuthenticationError));
}

test "formatError - returns non-empty strings for several errors" {
    var e = ErrorResponse{ .error_type = AIClientError.NetworkError, .message = "net" };
    try std.testing.expect(formatError(e).len > 0);
    e = ErrorResponse{ .error_type = AIClientError.AuthenticationError, .message = "auth" };
    try std.testing.expect(formatError(e).len > 0);
    e = ErrorResponse{ .error_type = AIClientError.RateLimitError, .message = "rate" };
    try std.testing.expect(formatError(e).len > 0);
}

test "formatError - TokenLimitError returns non-empty" {
    const e = ErrorResponse{ .error_type = AIClientError.TokenLimitError, .message = "tok" };
    const s = formatError(e);
    try std.testing.expect(s.len > 0);
}

test "ErrorResponse - withCode sets code" {
    const e = ErrorResponse.withCode(AIClientError.InvalidRequest, "msg", "ERR-001");
    try std.testing.expect(std.mem.eql(u8, e.code orelse "", "ERR-001"));
}

test "ErrorResponse - withRetryAfter sets retry_after" {
    const e = ErrorResponse.withRetryAfter(AIClientError.RateLimitError, "msg", 30);
    try std.testing.expect(e.retry_after != null);
    try std.testing.expect(e.retry_after orelse 0 == 30);
}

test "RateLimiter init/deinit basic" {
    var rl = RateLimiter.init(std.testing.allocator, 60);
    rl.deinit();
    // If we reach here, allocation/deallocation didn't crash
}
