const std = @import("std");

/// Convergence detection for iterative agent loops
///
/// Inspired by Cavekit's convergence detection — auto-detects when
/// iterative refinement loops plateau (no meaningful improvement
/// between iterations), preventing infinite loops.
///
/// Reference: Cavekit convergence-gate feature
pub const ConvergenceDetector = struct {
    /// Minimum change ratio to be considered "making progress"
    /// If change ratio falls below this for `max_stall_rounds`, we've converged
    min_change_threshold: f64 = 0.05, // 5% change

    /// Number of consecutive rounds below threshold before declaring convergence
    max_stall_rounds: u32 = 3,

    /// Current stall counter
    stall_count: u32 = 0,

    /// History of change ratios for the last N rounds
    history: [8]f64,
    history_len: u32 = 0,

    pub fn init() ConvergenceDetector {
        return .{
            .history = [_]f64{0} ** 8,
            .history_len = 0,
            .stall_count = 0,
        };
    }

    /// Record a new iteration result and check for convergence
    /// `prev_output` = output from previous iteration
    /// `curr_output` = output from current iteration
    /// Returns true if the loop has converged (should stop)
    pub fn checkConvergence(self: *ConvergenceDetector, prev_output: []const u8, curr_output: []const u8) bool {
        const change_ratio = computeChangeRatio(prev_output, curr_output);

        // Store in circular buffer
        if (self.history_len < self.history.len) {
            self.history[self.history_len] = change_ratio;
            self.history_len += 1;
        } else {
            // Shift left
            for (self.history[0 .. self.history.len - 1], 1..) |*slot, i| {
                slot.* = self.history[i];
            }
            self.history[self.history.len - 1] = change_ratio;
        }

        // Check stall
        if (change_ratio < self.min_change_threshold) {
            self.stall_count += 1;
        } else {
            self.stall_count = 0;
        }

        return self.stall_count >= self.max_stall_rounds;
    }

    /// Get the average change ratio over recent iterations
    pub fn averageChangeRate(self: *const ConvergenceDetector) f64 {
        if (self.history_len == 0) return 1.0;
        var sum: f64 = 0;
        for (self.history[0..self.history_len]) |v| {
            sum += v;
        }
        return sum / @as(f64, @floatFromInt(self.history_len));
    }

    /// Reset for a new convergence detection cycle
    pub fn reset(self: *ConvergenceDetector) void {
        self.stall_count = 0;
        self.history_len = 0;
    }
};

/// Compute a simple change ratio between two strings
/// Returns 0.0 (identical) to 1.0 (completely different)
fn computeChangeRatio(prev: []const u8, curr: []const u8) f64 {
    if (prev.len == 0 and curr.len == 0) return 0.0;
    if (prev.len == 0 or curr.len == 0) return 1.0;

    // Simple line-based diff ratio
    var prev_lines: u32 = 1;
    var curr_lines: u32 = 1;
    for (prev) |ch| {
        if (ch == '\n') prev_lines += 1;
    }
    for (curr) |ch| {
        if (ch == '\n') curr_lines += 1;
    }

    // Use length difference as proxy for change amount
    const len_diff = if (prev.len > curr.len) prev.len - curr.len else curr.len - prev.len;
    const max_len = @max(prev.len, curr.len);

    // Also count character-level differences (sampled for performance)
    const sample_size = @min(256, @min(prev.len, curr.len));
    var diff_count: u32 = 0;
    if (sample_size > 0) {
        const step = @max(1, @min(prev.len, curr.len) / sample_size);
        var i: usize = 0;
        while (i < @min(prev.len, curr.len)) : (i += step) {
            if (prev[i] != curr[i]) diff_count += 1;
        }
    }

    // Combine length diff ratio and character diff ratio
    const len_ratio: f64 = @as(f64, @floatFromInt(len_diff)) / @as(f64, @floatFromInt(max_len));
    const char_ratio: f64 = if (sample_size > 0) @as(f64, @floatFromInt(diff_count)) / @as(f64, @floatFromInt(sample_size)) else 0.0;

    return (len_ratio + char_ratio) / 2.0;
}
