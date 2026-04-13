const std = @import("std");
const file_compat = @import("file_compat");
const color_mod = @import("color");

const Style = color_mod.Style;

/// Stdout-based streaming spinner — shows animated feedback while waiting for AI responses.
/// Uses ANSI escape codes directly (no TUI Screen dependency).
///
/// Since AI requests are blocking, this provides a static "Thinking..." indicator
/// that's cleared once the response arrives. The spinner frame advances via tick()
/// if called from a polling loop.
pub const StreamingSpinner = struct {
    pub const classic_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const dots_frames = [_][]const u8{ ".", "o", "O", "o" };
    pub const arrows_frames = [_][]const u8{ "|", "/", "-", "\\" };

    frames: []const []const u8,
    frame_index: usize = 0,
    start_ms: i64,
    message: []const u8,

    /// Create a new spinner with the given frame set and label.
    pub fn init(frames: []const []const u8, message: []const u8) StreamingSpinner {
        return .{
            .frames = frames,
            .start_ms = std.time.milliTimestamp(),
            .message = message,
        };
    }

    /// Advance to the next animation frame.
    pub fn tick(self: *StreamingSpinner) void {
        self.frame_index = (self.frame_index + 1) % self.frames.len;
    }

    /// Get the elapsed time in seconds since init().
    pub fn elapsedSeconds(self: *const StreamingSpinner) f64 {
        const now = std.time.milliTimestamp();
        if (now <= self.start_ms) return 0.0;
        const delta_ms: f64 = @floatFromInt(now - self.start_ms);
        return delta_ms / 1000.0;
    }

    /// Print the spinner to stdout (overwrites current line with \r).
    pub fn show(self: *StreamingSpinner) void {
        const stdout = file_compat.File.stdout().writer();
        const frame = self.frames[self.frame_index];
        const elapsed = self.elapsedSeconds();
        stdout.print("\r{s}{s}{s} {s} ({d:.1}s){s}", .{
            Style.info.start(),
            frame,
            Style.info.reset(),
            self.message,
            elapsed,
            "\x1b[0K", // clear to end of line
        }) catch {};
    }

    /// Clear the spinner line from the terminal.
    pub fn clear(_: *StreamingSpinner) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\r\x1b[2K\r", .{}) catch {};
    }

    /// Print a static "Thinking..." indicator (for blocking calls).
    /// Call clearStatic() when the response arrives.
    pub fn showStatic(message: []const u8) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\r{s}⠹ {s}...{s}", .{
            Style.info.start(),
            message,
            "\x1b[0K",
        }) catch {};
    }

    /// Clear a static indicator.
    pub fn clearStatic() void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\r\x1b[2K\r", .{}) catch {};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StreamingSpinner — init and tick" {
    const test_frames = [_][]const u8{ "a", "b", "c" };
    var sp = StreamingSpinner.init(&test_frames, "test");
    try std.testing.expectEqual(@as(usize, 0), sp.frame_index);
    try std.testing.expectEqualStrings("test", sp.message);

    sp.tick();
    try std.testing.expectEqual(@as(usize, 1), sp.frame_index);

    sp.tick();
    try std.testing.expectEqual(@as(usize, 2), sp.frame_index);

    // Wraps around
    sp.tick();
    try std.testing.expectEqual(@as(usize, 0), sp.frame_index);
}

test "StreamingSpinner — elapsed is non-negative" {
    const test_frames = [_][]const u8{"."};
    var sp = StreamingSpinner.init(&test_frames, "test");
    const elapsed = sp.elapsedSeconds();
    try std.testing.expect(elapsed >= 0.0);
}
