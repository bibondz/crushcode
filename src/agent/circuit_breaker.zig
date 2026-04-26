const std = @import("std");

/// Circuit breaker states: closed (healthy), open (tripped), half_open (probing)
pub const CircuitState = enum { closed, open, half_open };

/// Standalone circuit breaker per provider.
/// Tracks consecutive failures and trips open after reaching threshold.
/// Automatically transitions to half_open after reset_timeout_ns, allowing a probe request.
/// provider_name is a reference — NOT owned/duped.
pub const CircuitBreaker = struct {
    failure_count: u32,
    success_count: u32,
    last_failure_ns: i64,
    threshold: u32,
    reset_timeout_ns: u64,
    state: CircuitState,
    provider_name: []const u8,

    /// Initialize a circuit breaker for a provider.
    /// provider_name is stored as a reference (not duped).
    pub fn init(provider_name: []const u8, threshold: u32, reset_timeout_ns: u64) CircuitBreaker {
        return CircuitBreaker{
            .failure_count = 0,
            .success_count = 0,
            .last_failure_ns = 0,
            .threshold = threshold,
            .reset_timeout_ns = reset_timeout_ns,
            .state = .closed,
            .provider_name = provider_name,
        };
    }

    /// Check if a request is allowed through the circuit breaker.
    /// Returns false if the circuit is open and the reset timeout has not elapsed.
    /// Transitions to half_open if the timeout has elapsed, allowing one probe.
    pub fn allow(self: *CircuitBreaker) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                const now_ns = std.time.nanoTimestamp();
                const elapsed = @as(u64, @intCast(now_ns - self.last_failure_ns));
                if (elapsed >= self.reset_timeout_ns) {
                    self.state = .half_open;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }

    /// Record a successful request. Resets failure_count and transitions to closed.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count = 0;
        self.success_count += 1;
        self.state = .closed;
    }

    /// Record a failed request. Increments failure_count and trips open if threshold reached.
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        self.success_count = 0;
        self.last_failure_ns = @intCast(std.time.nanoTimestamp());
        if (self.failure_count >= self.threshold) {
            self.state = .open;
        }
    }

    /// Force close the circuit breaker, resetting all counters.
    pub fn reset(self: *CircuitBreaker) void {
        self.failure_count = 0;
        self.success_count = 0;
        self.state = .closed;
    }
};

/// Map of provider name → CircuitBreaker for use in router.
pub const CircuitBreakerMap = std.StringHashMap(CircuitBreaker);

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "CircuitBreaker - init state is closed" {
    const cb = CircuitBreaker.init("openai", 5, 30_000_000_000);
    try testing.expectEqual(CircuitState.closed, cb.state);
    try testing.expectEqual(@as(u32, 0), cb.failure_count);
    try testing.expectEqual(@as(u32, 0), cb.success_count);
    try testing.expectEqual(@as(u32, 5), cb.threshold);
    try testing.expectEqualStrings("openai", cb.provider_name);
}

test "CircuitBreaker - allow returns true when closed" {
    var cb = CircuitBreaker.init("test", 3, 1_000_000_000);
    try testing.expect(cb.allow());
    try testing.expect(cb.allow());
}

test "CircuitBreaker - trips open after threshold failures" {
    var cb = CircuitBreaker.init("test", 3, 60_000_000_000);
    try testing.expectEqual(CircuitState.closed, cb.state);

    cb.recordFailure();
    try testing.expectEqual(CircuitState.closed, cb.state);
    try testing.expectEqual(@as(u32, 1), cb.failure_count);

    cb.recordFailure();
    try testing.expectEqual(CircuitState.closed, cb.state);

    cb.recordFailure();
    try testing.expectEqual(CircuitState.open, cb.state);
    try testing.expect(!cb.allow());
}

test "CircuitBreaker - recordSuccess resets to closed" {
    var cb = CircuitBreaker.init("test", 2, 60_000_000_000);
    cb.recordFailure();
    cb.recordFailure();
    try testing.expectEqual(CircuitState.open, cb.state);

    cb.recordSuccess();
    try testing.expectEqual(CircuitState.closed, cb.state);
    try testing.expectEqual(@as(u32, 0), cb.failure_count);
    try testing.expectEqual(@as(u32, 1), cb.success_count);
}

test "CircuitBreaker - reset forces closed" {
    var cb = CircuitBreaker.init("test", 1, 60_000_000_000);
    cb.recordFailure();
    try testing.expectEqual(CircuitState.open, cb.state);

    cb.reset();
    try testing.expectEqual(CircuitState.closed, cb.state);
    try testing.expectEqual(@as(u32, 0), cb.failure_count);
    try testing.expectEqual(@as(u32, 0), cb.success_count);
}

test "CircuitBreaker - half_open allows one probe" {
    var cb = CircuitBreaker.init("test", 1, 1_000_000); // 1ms timeout for test
    cb.recordFailure();
    try testing.expectEqual(CircuitState.open, cb.state);

    // Wait for timeout to elapse
    std.Thread.sleep(2 * std.time.ns_per_ms);

    try testing.expect(cb.allow());
    try testing.expectEqual(CircuitState.half_open, cb.state);
}
