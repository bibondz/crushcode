const std = @import("std");

/// Configuration for loop detection.
/// Modeled after Crush's loop_detection.go: hashes tool name + args + output
/// into a SHA-256 signature, then counts occurrences within a sliding window.
pub const LoopDetectorConfig = struct {
    /// Number of recent tool interactions to examine.
    window_size: u32 = 10,
    /// Maximum times the same signature can appear before triggering.
    max_repeats: u32 = 5,

    pub fn init() LoopDetectorConfig {
        return .{
            .window_size = 10,
            .max_repeats = 5,
        };
    }
};

/// SHA-256 digest — 32 bytes.
const Signature = [32]u8;

/// Maximum window size supported. Ring buffer is stack-allocated.
const MAX_WINDOW: usize = 32;

/// LoopDetector detects when the agent is stuck repeating the same
/// tool interactions. Unlike the old name+error-prefix approach in
/// self_heal.zig, this works for ALL tool calls (success + failure)
/// and hashes the full interaction (name + args + output) so it
/// catches subtler loops like reading the same file repeatedly.
///
/// Uses a fixed-size ring buffer (no allocator needed) since window
/// sizes are small (default 10, max 32).
///
/// Reference: Crush `internal/agent/loop_detection.go` (92 lines)
pub const LoopDetector = struct {
    config: LoopDetectorConfig,
    /// Ring buffer of recent step signatures.
    buffer: [MAX_WINDOW]Signature,
    /// Number of entries currently in the ring buffer.
    len: usize,
    /// Next write position in the ring buffer.
    head: usize,

    /// Initialize the detector with default config.
    pub fn init() LoopDetector {
        return initWithConfig(LoopDetectorConfig.init());
    }

    /// Initialize with custom config.
    pub fn initWithConfig(config: LoopDetectorConfig) LoopDetector {
        var det = LoopDetector{
            .config = config,
            .buffer = undefined,
            .len = 0,
            .head = 0,
        };
        // Zero-initialize buffer so comparisons are deterministic
        @memset(&det.buffer, [1]u8{0} ** 32);
        return det;
    }

    /// Record a tool interaction and return true if a loop is detected.
    /// Call this AFTER each tool execution with the tool name, arguments,
    /// and output (both successful and failed).
    pub fn recordAndCheck(self: *LoopDetector, tool_name: []const u8, args: []const u8, output: []const u8) bool {
        const sig = computeSignature(tool_name, args, output);

        const window: usize = @intCast(self.config.window_size);
        self.buffer[self.head] = sig;
        self.head = (self.head + 1) % window;
        if (self.len < window) {
            self.len += 1;
        }

        return self.detectLoop();
    }

    /// Check current state for loops without recording a new step.
    pub fn detectLoop(self: *const LoopDetector) bool {
        if (self.len < 3) return false;

        const max_rep: usize = @intCast(self.config.max_repeats);

        // Count occurrences of the most recently added signature.
        // The last entry written is at (head - 1 + window) % window,
        // or simply (self.len - 1) before wrapping.
        const window: usize = @intCast(self.config.window_size);
        const latest_idx: usize = if (self.len <= window)
            self.len - 1
        else
            (self.head + window - 1) % window;
        const latest = self.buffer[latest_idx];

        var count: usize = 0;
        for (self.buffer[0..self.len]) |sig| {
            if (std.mem.eql(u8, &sig, &latest)) {
                count += 1;
                if (count > max_rep) return true;
            }
        }

        return false;
    }

    /// Compute SHA-256 hash of tool_name + \0 + args + \0 + output + \0.
    /// Matches Crush's `getToolInteractionSignature` which hashes
    /// ToolName, Input, and output string.
    fn computeSignature(tool_name: []const u8, args: []const u8, output: []const u8) Signature {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(tool_name);
        hasher.update(&[1]u8{0x00});
        hasher.update(args);
        hasher.update(&[1]u8{0x00});
        hasher.update(output);
        hasher.update(&[1]u8{0x00});
        var digest: Signature = undefined;
        hasher.final(&digest);
        return digest;
    }

    /// Number of steps recorded (capped at window_size).
    pub fn stepCount(self: *const LoopDetector) usize {
        return self.len;
    }

    /// Reset all recorded state.
    pub fn reset(self: *LoopDetector) void {
        self.len = 0;
        self.head = 0;
    }

    /// Clean up (no-op for stack-allocated ring buffer).
    pub fn deinit(self: *LoopDetector) void {
        _ = self;
    }

    /// Return the effective window size (clamped to MAX_WINDOW).
    pub fn effectiveWindowSize(self: *const LoopDetector) usize {
        const w: usize = @intCast(self.config.window_size);
        return @min(w, MAX_WINDOW);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "LoopDetectorConfig - default values" {
    const cfg = LoopDetectorConfig.init();
    try testing.expectEqual(@as(u32, 10), cfg.window_size);
    try testing.expectEqual(@as(u32, 5), cfg.max_repeats);
}

test "LoopDetector - no loop with few steps" {
    var detector = LoopDetector.init();
    defer detector.deinit();

    // 3 different tool calls — should not trigger
    const result = detector.recordAndCheck("read_file", "path=a.zig", "content A");
    try testing.expect(!result);
    const result2 = detector.recordAndCheck("read_file", "path=b.zig", "content B");
    try testing.expect(!result2);
}

test "LoopDetector - detects loop after max_repeats" {
    var detector = LoopDetector.initWithConfig(.{ .window_size = 10, .max_repeats = 3 });
    defer detector.deinit();

    // Same tool call repeated 4 times (exceeds max_repeats=3)
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok");
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok");
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok");
    const result = detector.recordAndCheck("edit", "file=main.zig", "ok");
    try testing.expect(result);
}

test "LoopDetector - different args don't trigger" {
    var detector = LoopDetector.initWithConfig(.{ .window_size = 10, .max_repeats = 3 });
    defer detector.deinit();

    // Same tool, different args — different signatures
    _ = detector.recordAndCheck("edit", "file=a.zig", "ok");
    _ = detector.recordAndCheck("edit", "file=b.zig", "ok");
    _ = detector.recordAndCheck("edit", "file=c.zig", "ok");
    _ = detector.recordAndCheck("edit", "file=d.zig", "ok");
    try testing.expect(!detector.detectLoop());
}

test "LoopDetector - different outputs don't trigger" {
    var detector = LoopDetector.initWithConfig(.{ .window_size = 10, .max_repeats = 3 });
    defer detector.deinit();

    // Same tool+args, different output — agent is making progress
    _ = detector.recordAndCheck("edit", "file=main.zig", "attempt 1");
    _ = detector.recordAndCheck("edit", "file=main.zig", "attempt 2");
    _ = detector.recordAndCheck("edit", "file=main.zig", "attempt 3");
    _ = detector.recordAndCheck("edit", "file=main.zig", "attempt 4");
    try testing.expect(!detector.detectLoop());
}

test "LoopDetector - sliding window evicts old entries" {
    var detector = LoopDetector.initWithConfig(.{ .window_size = 4, .max_repeats = 3 });
    defer detector.deinit();

    // Fill window with alternating calls
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok"); // sig A
    _ = detector.recordAndCheck("read", "path=other.zig", "data"); // sig B
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok"); // sig A
    _ = detector.recordAndCheck("read", "path=other.zig", "data"); // sig B
    try testing.expect(!detector.detectLoop()); // A=2, B=2 → both ≤3

    // Window wraps: oldest A evicted → [B, A, B, A] → now add another A
    _ = detector.recordAndCheck("edit", "file=main.zig", "ok");
    try testing.expect(!detector.detectLoop()); // [A, B, A, A] → A=3, still not >3
}

test "LoopDetector - reset clears state" {
    var detector = LoopDetector.init();
    defer detector.deinit();

    _ = detector.recordAndCheck("tool", "args", "output");
    _ = detector.recordAndCheck("tool", "args", "output");
    try testing.expectEqual(@as(usize, 2), detector.stepCount());

    detector.reset();
    try testing.expectEqual(@as(usize, 0), detector.stepCount());
}

test "LoopDetector - init and deinit" {
    var detector = LoopDetector.init();
    detector.deinit();
}
