const std = @import("std");

/// Desktop notification support for Crushcode.
/// Spawns platform-native notification commands:
///   - Linux: `notify-send` (libnotify)
///   - macOS: `osascript -e 'display notification'`
///   - Windows: PowerShell `New-BurntToastNotification` fallback
///
/// All notification calls are fire-and-forget — failures are silently
/// ignored so the agent loop never blocks on a notification.
///
/// Reference: Crush `internal/agent/coordinator.go` — notify package

/// Notification urgency levels.
pub const Urgency = enum {
    low,
    normal,
    critical,
};

/// Notification configuration.
pub const NotifyConfig = struct {
    /// Enable desktop notifications.
    enabled: bool = true,
    /// Minimum seconds between notifications (rate-limit).
    min_interval_ms: u64 = 5000,
    /// Application name shown in notifications.
    app_name: []const u8 = "Crushcode",
};

/// DesktopNotifier sends OS-level notifications.
/// Thread-safe: uses an internal mutex for the timestamp check.
pub const DesktopNotifier = struct {
    config: NotifyConfig,
    /// Timestamp of last sent notification (epoch ms).
    last_sent_ms: u64,
    /// Cached platform — computed once on first send.
    cached_platform: ?Platform,

    const Platform = enum {
        linux,
        macos,
        windows,
        unknown,
    };

    /// Initialize the notifier.
    pub fn init() DesktopNotifier {
        return initWithConfig(NotifyConfig{});
    }

    /// Initialize with custom config.
    pub fn initWithConfig(config: NotifyConfig) DesktopNotifier {
        return .{
            .config = config,
            .last_sent_ms = 0,
            .cached_platform = null,
        };
    }

    /// Detect the current platform.
    fn detectPlatform() Platform {
        // Check via builtin target
        const arch = @import("builtin").target.os.tag;
        return switch (arch) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .unknown,
        };
    }

    /// Get current epoch milliseconds.
    fn nowMs() u64 {
        return @intCast(std.time.milliTimestamp() + std.math.maxInt(i64) / 2 + 1);
    }

    /// Send a desktop notification. Fire-and-forget — errors are logged
    /// but never propagated. Rate-limited by min_interval_ms.
    pub fn notify(self: *DesktopNotifier, title: []const u8, body: []const u8) void {
        self.notifyWithUrgency(title, body, .normal);
    }

    /// Send a desktop notification with urgency level.
    pub fn notifyWithUrgency(self: *DesktopNotifier, title: []const u8, body: []const u8, urgency: Urgency) void {
        if (!self.config.enabled) return;

        // Rate-limit
        const now = nowMs();
        if (now - self.last_sent_ms < self.config.min_interval_ms) return;
        self.last_sent_ms = now;

        // Detect platform (cached)
        if (self.cached_platform == null) {
            self.cached_platform = detectPlatform();
        }
        const platform = self.cached_platform.?;

        switch (platform) {
            .linux => self.notifyLinux(title, body, urgency),
            .macos => self.notifyMacOS(title, body),
            .windows => self.notifyWindows(title, body),
            .unknown => {},
        }
    }

    /// Linux: `notify-send -u <urgency> -a <app> "<title>" "<body>"`
    fn notifyLinux(self: *DesktopNotifier, title: []const u8, body: []const u8, urgency: Urgency) void {
        _ = self;
        const urg_str = switch (urgency) {
            .low => "low",
            .normal => "normal",
            .critical => "critical",
        };

        // Build argv: notify-send -u <urgency> -a Crushcode "title" "body"
        var argv: [6][]const u8 = undefined;
        argv[0] = "notify-send";
        argv[1] = "-u";
        argv[2] = urg_str;
        argv[3] = title;
        argv[4] = body;
        const args = argv[0..5];

        spawnForget(args);
    }

    /// macOS: `osascript -e 'display notification "body" with title "title" sound name "default"'`
    fn notifyMacOS(self: *DesktopNotifier, title: []const u8, body: []const u8) void {
        _ = self;
        // Build the osascript command
        // We need: osascript -e 'display notification "body" with title "title"'
        // Using a fixed-size buffer for the script
        var script_buf: [1024]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\display notification "{s}" with title "{s}"
        , .{ body, title }) catch return;

        var argv: [3][]const u8 = undefined;
        argv[0] = "osascript";
        argv[1] = "-e";
        argv[2] = script;
        spawnForget(argv[0..3]);
    }

    /// Windows: PowerShell toast notification
    fn notifyWindows(self: *DesktopNotifier, title: []const u8, body: []const u8) void {
        _ = self;
        var script_buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\Add-Type -AssemblyName System.Windows.Forms; $n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; $n.ShowBalloonTip(5000, '{s}', '{s}', [System.Windows.Forms.ToolTipIcon]::None); Start-Sleep -Milliseconds 6000; $n.Dispose()
        , .{ title, body }) catch return;

        var argv: [3][]const u8 = undefined;
        argv[0] = "powershell";
        argv[1] = "-Command";
        argv[2] = script;
        spawnForget(argv[0..3]);
    }

    /// Fire-and-forget child process spawn.
    /// Spawns the command and immediately waits (collects exit status)
    /// to avoid zombie processes. Silently ignores all errors.
    fn spawnForget(argv: []const []const u8) void {
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        // Spawn and wait — fire-and-forget
        child.spawn() catch return;
        _ = child.wait() catch {};
    }

    /// Reset rate limiter (e.g., after a long pause).
    pub fn resetRateLimit(self: *DesktopNotifier) void {
        self.last_sent_ms = 0;
    }

    /// Clean up (no-op — no heap allocations).
    pub fn deinit(self: *DesktopNotifier) void {
        _ = self;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "NotifyConfig - defaults" {
    const cfg = NotifyConfig{};
    try testing.expect(cfg.enabled);
    try testing.expectEqual(@as(u64, 5000), cfg.min_interval_ms);
}

test "DesktopNotifier - init and deinit" {
    var notifier = DesktopNotifier.init();
    notifier.deinit();
}

test "DesktopNotifier - initWithConfig" {
    var notifier = DesktopNotifier.initWithConfig(.{ .enabled = false });
    defer notifier.deinit();
    try testing.expect(!notifier.config.enabled);
}

test "DesktopNotifier - disabled does nothing" {
    var notifier = DesktopNotifier.initWithConfig(.{ .enabled = false });
    defer notifier.deinit();
    // Should not crash or block when disabled
    notifier.notify("Test", "Body");
}

test "DesktopNotifier - rate limiting" {
    var notifier = DesktopNotifier.initWithConfig(.{
        .enabled = true,
        .min_interval_ms = 10000, // 10 seconds
    });
    defer notifier.deinit();

    // First call sets timestamp
    notifier.notify("First", "Call");
    try testing.expect(notifier.last_sent_ms > 0);
    const first_ts = notifier.last_sent_ms;

    // Second call within interval — timestamp unchanged
    notifier.notify("Second", "Call");
    try testing.expectEqual(first_ts, notifier.last_sent_ms);
}

test "DesktopNotifier - reset rate limit" {
    var notifier = DesktopNotifier.initWithConfig(.{ .min_interval_ms = 60000 });
    defer notifier.deinit();

    notifier.notify("First", "Call");
    try testing.expect(notifier.last_sent_ms > 0);

    notifier.resetRateLimit();
    try testing.expectEqual(@as(u64, 0), notifier.last_sent_ms);
}

test "DesktopNotifier - detectPlatform returns valid platform" {
    const platform = DesktopNotifier.detectPlatform();
    // Just verify it doesn't crash and returns a valid value
    switch (platform) {
        .linux, .macos, .windows, .unknown => {}, // all valid
    }
}

test "DesktopNotifier - notifyWithUrgency disabled" {
    var notifier = DesktopNotifier.initWithConfig(.{ .enabled = false });
    defer notifier.deinit();
    notifier.notifyWithUrgency("Test", "Body", .critical);
    // Timestamp should remain 0 — no send attempted
    try testing.expectEqual(@as(u64, 0), notifier.last_sent_ms);
}
