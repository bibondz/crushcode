const std = @import("std");

/// Classification of HTTP/API errors for retry decisions
pub const ErrorClass = enum {
    retryable_transient,
    retryable_rate_limit,
    non_retryable_auth,
    non_retryable_input,
    non_retryable_not_found,
    unknown,

    /// Human-readable name for logging
    pub fn toString(self: ErrorClass) []const u8 {
        return switch (self) {
            .retryable_transient => "retryable_transient",
            .retryable_rate_limit => "retryable_rate_limit",
            .non_retryable_auth => "non_retryable_auth",
            .non_retryable_input => "non_retryable_input",
            .non_retryable_not_found => "non_retryable_not_found",
            .unknown => "unknown",
        };
    }
};

/// Configuration for retry behavior with exponential backoff
pub const RetryPolicy = struct {
    max_attempts: u32,
    initial_interval_ms: u64,
    max_interval_ms: u64,
    backoff_multiplier: f64,
    jitter: bool,

    /// Preset for remote AI provider calls (3 attempts, generous backoff)
    pub fn forProvider() RetryPolicy {
        return RetryPolicy{
            .max_attempts = 3,
            .initial_interval_ms = 1000,
            .max_interval_ms = 60000,
            .backoff_multiplier = 2.0,
            .jitter = true,
        };
    }

    /// Preset for tool execution retries (2 attempts, moderate backoff)
    pub fn forTool() RetryPolicy {
        return RetryPolicy{
            .max_attempts = 2,
            .initial_interval_ms = 500,
            .max_interval_ms = 5000,
            .backoff_multiplier = 1.5,
            .jitter = true,
        };
    }

    /// Preset for local provider calls like Ollama (2 attempts, fast backoff)
    pub fn forLocal() RetryPolicy {
        return RetryPolicy{
            .max_attempts = 2,
            .initial_interval_ms = 200,
            .max_interval_ms = 2000,
            .backoff_multiplier = 1.5,
            .jitter = true,
        };
    }

    /// Calculate delay in ms for given attempt number (0-indexed).
    /// Uses exponential backoff: initial * multiplier^attempt, capped at max_interval_ms.
    /// If jitter=true, add random 0-50% of base delay.
    pub fn delayMs(self: *const RetryPolicy, attempt: u32) u64 {
        const base_f: f64 = @floatFromInt(self.initial_interval_ms);
        const exp = std.math.pow(f64, self.backoff_multiplier, @as(f64, @floatFromInt(attempt)));
        const raw_delay = base_f * exp;
        const capped = @min(raw_delay, @as(f64, @floatFromInt(self.max_interval_ms)));
        var delay: u64 = @intFromFloat(capped);

        if (self.jitter and delay > 0) {
            // Random jitter: 0 to 50% of base delay
            const jitter_max = delay / 2;
            if (jitter_max > 0) {
                const jitter = std.crypto.random.intRangeAtMost(u64, 0, jitter_max);
                delay += jitter;
            }
        }

        return delay;
    }

    /// Classify an HTTP error into ErrorClass based on status code and body
    pub fn classifyError(http_status: u16, body: []const u8) ErrorClass {
        return switch (http_status) {
            429 => {
                // Check for rate-limit indicators in body
                if (containsRateLimitHint(body)) {
                    return .retryable_rate_limit;
                }
                return .retryable_rate_limit;
            },
            401, 403 => .non_retryable_auth,
            400 => .non_retryable_input,
            404 => .non_retryable_not_found,
            500...599 => .retryable_transient,
            else => .unknown,
        };
    }

    /// Check if an ErrorClass is retryable
    pub fn isRetryable(class: ErrorClass) bool {
        return switch (class) {
            .retryable_transient, .retryable_rate_limit => true,
            .non_retryable_auth,
            .non_retryable_input,
            .non_retryable_not_found,
            .unknown,
            => false,
        };
    }
};

/// Check if the response body contains rate-limit related keywords (case-insensitive)
fn containsRateLimitHint(body: []const u8) bool {
    const hints = [_][]const u8{
        "retry-after",
        "rate limit",
        "rate_limit",
        "too many requests",
        "quota exceeded",
        "requests per",
    };
    for (hints) |hint| {
        if (indexOfCaseInsensitive(body, hint)) |_| {
            return true;
        }
    }
    return false;
}

/// Case-insensitive substring search
fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return @as(?usize, 0);
    if (haystack.len < needle.len) return null;

    var i: usize = 0;
    const end = haystack.len - needle.len;
    while (i <= end) : (i += 1) {
        var match = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Result of a retry operation
pub const RetryResult = enum {
    success,
    max_attempts_reached,
    non_retryable_error,
    self_heal_success,
    self_heal_failed,
};

/// Mutable state tracking progress through retry attempts
pub const RetryState = struct {
    policy: RetryPolicy,
    current_attempt: u32,
    last_error: ?ErrorClass,
    last_error_message: ?[]const u8,
    total_wait_ms: u64,
    allocator: std.mem.Allocator,

    /// Initialize retry state with the given policy
    pub fn init(allocator: std.mem.Allocator, policy: RetryPolicy) RetryState {
        return RetryState{
            .policy = policy,
            .current_attempt = 0,
            .last_error = null,
            .last_error_message = null,
            .total_wait_ms = 0,
            .allocator = allocator,
        };
    }

    /// Returns delay_ms for next attempt, or null if exhausted.
    /// Increments current_attempt on each call.
    pub fn nextAttempt(self: *RetryState) ?u64 {
        if (self.current_attempt >= self.policy.max_attempts) {
            return null;
        }
        const delay = self.policy.delayMs(self.current_attempt);
        self.current_attempt += 1;
        self.total_wait_ms += delay;
        return delay;
    }

    /// Record an error. Stores the error class and message.
    /// Returns true if the error is retryable and attempts remain.
    pub fn recordError(self: *RetryState, class: ErrorClass, message: []const u8) bool {
        self.last_error = class;

        // Free previous error message if any
        if (self.last_error_message) |old| {
            self.allocator.free(old);
            self.last_error_message = null;
        }

        // Duplicate the new message
        self.last_error_message = self.allocator.dupe(u8, message) catch null;

        // Only retry if the error class is retryable
        if (!RetryPolicy.isRetryable(class)) {
            return false;
        }

        // Check if we have attempts remaining
        return self.current_attempt < self.policy.max_attempts;
    }

    /// Record success, clearing error state
    pub fn recordSuccess(self: *RetryState) void {
        self.last_error = null;
        if (self.last_error_message) |old| {
            self.allocator.free(old);
            self.last_error_message = null;
        }
    }

    /// Clean up allocated resources
    pub fn deinit(self: *RetryState) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
        }
    }
};
