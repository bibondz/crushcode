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
