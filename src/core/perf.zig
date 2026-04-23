const std = @import("std");

/// High-resolution performance timer for measuring latency and throughput.
pub const Timer = struct {
    start_time: i64,
    
    pub fn start() Timer {
        return .{ .start_time = std.time.milliTimestamp() };
    }
    
    pub fn stop(self: Timer) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }
    
    pub fn elapsed(self: Timer) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }
};

/// Simple reporter for performance metrics.
pub const PerfReport = struct {
    pub fn log(metric: []const u8, value: i64, unit: []const u8) void {
        std.debug.print("[PERF] {s}: {d}{s}\n", .{ metric, value, unit });
    }
};

// ========== UNIT TESTS ==========

const testing = std.testing;

test "Timer.start and elapsed" {
    const timer = Timer.start();
    const elapsed = timer.elapsed();
    // Elapsed should be non-negative (>= 0) since no time travel
    try testing.expect(elapsed >= 0);
}

test "Timer.stop returns positive duration" {
    const timer = Timer.start();
    std.Thread.sleep(10 * std.time.ns_per_ms);
    const duration = timer.stop();
    // Allow tolerance: at least 8ms should have passed after 10ms sleep
    try testing.expect(duration >= 8);
}

test "PerfReport.log does not crash" {
    // Verify log() runs without errors for sample values
    PerfReport.log("test_metric", 42, "ms");
    PerfReport.log("throughput", 1000, "tok/s");
    PerfReport.log("negative_value", -1, "ms");
}
