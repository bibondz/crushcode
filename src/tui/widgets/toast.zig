const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_helpers = @import("widget_helpers");

const vxfw = vaxis.vxfw;

/// Maximum number of visible toasts at once.
pub const max_visible: usize = 5;

/// Default auto-dismiss duration in milliseconds.
pub const default_duration_ms: i64 = 4000;

/// Toast severity levels with associated styling.
pub const Severity = enum {
    info,
    success,
    warning,
    err,

    pub fn icon(self: Severity) []const u8 {
        return switch (self) {
            .info => "ℹ",
            .success => "✔",
            .warning => "⚠",
            .err => "✖",
        };
    }

    pub fn fgColor(self: Severity, theme: *const theme_mod.Theme) vaxis.Color {
        return switch (self) {
            .info => theme.accent,
            .success => theme.tool_success,
            .warning => theme.toast_warning_fg,
            .err => theme.tool_error,
        };
    }

    pub fn bgColor(self: Severity, theme: *const theme_mod.Theme) vaxis.Color {
        return switch (self) {
            .info => theme.toast_info_bg,
            .success => theme.toast_success_bg,
            .warning => theme.toast_warning_bg,
            .err => theme.toast_error_bg,
        };
    }
};

/// A single toast notification entry.
pub const Toast = struct {
    message: []const u8,
    severity: Severity,
    created_ms: i64,
    duration_ms: i64,

    pub fn init(message: []const u8, severity: Severity) Toast {
        return .{
            .message = message,
            .severity = severity,
            .created_ms = std.time.milliTimestamp(),
            .duration_ms = default_duration_ms,
        };
    }

    pub fn initWithDuration(message: []const u8, severity: Severity, duration_ms: i64) Toast {
        return .{
            .message = message,
            .severity = severity,
            .created_ms = std.time.milliTimestamp(),
            .duration_ms = duration_ms,
        };
    }

    /// Whether this toast should be dismissed (auto-expired).
    pub fn isExpired(self: *const Toast) bool {
        const now = std.time.milliTimestamp();
        return (now - self.created_ms) >= self.duration_ms;
    }

    /// Progress of auto-dismiss: 0.0 (just created) to 1.0 (expired).
    pub fn progress(self: *const Toast) f32 {
        const now = std.time.milliTimestamp();
        const elapsed: f32 = @floatFromInt(@max(0, now - self.created_ms));
        const duration: f32 = @floatFromInt(@max(1, self.duration_ms));
        return @min(1.0, elapsed / duration);
    }
};

/// ToastStack — manages a stack of toast notifications with auto-dismiss.
///
/// Usage:
///   1. Create: `var stack = ToastStack.init(allocator, theme);`
///   2. Push: `stack.push("File saved", .success);`
///   3. Call `tick()` each frame to auto-expire old toasts.
///   4. Render via `ToastStackWidget{ .stack = &stack }`.
///   5. Call `deinit()` when done.
pub const ToastStack = struct {
    toasts: std.ArrayList(Toast),
    theme: *const theme_mod.Theme,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, theme: *const theme_mod.Theme) ToastStack {
        return .{
            .toasts = std.ArrayList(Toast).empty,
            .theme = theme,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToastStack) void {
        self.toasts.deinit(self.allocator);
    }

    /// Add a toast notification.
    pub fn push(self: *ToastStack, message: []const u8, severity: Severity) !void {
        try self.toasts.append(self.allocator, Toast.init(message, severity));
        // Cap at 2x max_visible (allow some overflow for animation)
        while (self.toasts.items.len > max_visible * 2) {
            _ = self.toasts.orderedRemove(0);
        }
    }

    /// Add a toast with custom duration.
    pub fn pushWithDuration(self: *ToastStack, message: []const u8, severity: Severity, duration_ms: i64) !void {
        try self.toasts.append(self.allocator, Toast.initWithDuration(message, severity, duration_ms));
        while (self.toasts.items.len > max_visible * 2) {
            _ = self.toasts.orderedRemove(0);
        }
    }

    /// Remove expired toasts. Call each frame/tick.
    pub fn tick(self: *ToastStack) void {
        // Remove from front (oldest) while expired
        while (self.toasts.items.len > 0 and self.toasts.items[0].isExpired()) {
            _ = self.toasts.orderedRemove(0);
        }
    }

    /// Get the visible slice (up to max_visible newest toasts).
    pub fn visible(self: *const ToastStack) []const Toast {
        const start = if (self.toasts.items.len > max_visible) self.toasts.items.len - max_visible else 0;
        return self.toasts.items[start..];
    }

    /// Whether there are any active toasts.
    pub fn isActive(self: *const ToastStack) bool {
        return self.toasts.items.len > 0;
    }
};

/// ToastStackWidget — renders the toast stack as a vxfw widget.
///
/// Shows up to `max_visible` toasts, stacked vertically.
/// Each toast has: [icon] [message] [progress bar]
pub const ToastStackWidget = struct {
    stack: *ToastStack,

    pub fn widget(self: *const ToastStackWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ToastStackWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const ToastStackWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const vis = self.stack.visible();
        if (vis.len == 0) {
            return vxfw.Surface{
                .size = .{ .width = 0, .height = 0 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const width = max.width;
        const toast_height: u16 = 1;
        const total_height: u16 = @intCast(vis.len * toast_height);

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = total_height });
        const children = try ctx.arena.alloc(vxfw.SubSurface, vis.len);

        for (0..vis.len) |idx| {
            const toast = &vis[idx];
            const toast_ctx = ctx.withConstraints(
                .{ .width = width, .height = toast_height },
                .{ .width = width, .height = toast_height },
            );
            const toast_surface = try drawSingleToast(toast, self.stack.theme, toast_ctx);
            children[idx] = .{
                .origin = .{ .row = @intCast(idx * toast_height), .col = 0 },
                .surface = toast_surface,
            };
        }

        return .{
            .size = .{ .width = width, .height = total_height },
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }

    fn drawSingleToast(toast: *const Toast, theme: *const theme_mod.Theme, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const severity = toast.severity;
        const progress_val = toast.progress();
        const arena = ctx.arena;

        // Build progress bar string: filled "#" + empty "-"
        const bar_max: usize = 10;
        const filled: usize = @intFromFloat(@as(f32, @floatFromInt(bar_max)) * (1.0 - progress_val));
        const empty: usize = bar_max - filled;

        const bar_text = try buildProgressBar(arena, filled, empty);

        const bg = severity.bgColor(theme);

        // Build segments: [icon] [space] [message] [bar]
        var seg_count: usize = 0;
        const segs = try arena.alloc(vaxis.Segment, 4);

        // Icon
        segs[seg_count] = .{
            .text = severity.icon(),
            .style = .{ .fg = severity.fgColor(theme), .bg = bg, .bold = true },
        };
        seg_count += 1;

        // Space
        segs[seg_count] = .{
            .text = " ",
            .style = .{ .bg = bg },
        };
        seg_count += 1;

        // Message
        segs[seg_count] = .{
            .text = toast.message,
            .style = .{ .fg = theme.toast_msg_fg, .bg = bg },
        };
        seg_count += 1;

        // Progress bar
        segs[seg_count] = .{
            .text = bar_text,
            .style = .{ .fg = severity.fgColor(theme), .bg = bg, .dim = true },
        };
        seg_count += 1;

        const rich = vxfw.RichText{
            .text = segs[0..seg_count],
            .softwrap = false,
            .width_basis = .longest_line,
        };

        return rich.draw(ctx);
    }

    /// Build a progress bar string with `filled` solid chars and `empty` hollow chars.
    fn buildProgressBar(arena: std.mem.Allocator, filled: usize, empty: usize) std.mem.Allocator.Error![]const u8 {
        // Use ASCII: # for filled, - for empty
        var buf = try arena.alloc(u8, 1 + filled + empty);
        buf[0] = ' ';
        @memset(buf[1 .. 1 + filled], '#');
        @memset(buf[1 + filled .. 1 + filled + empty], '-');
        return buf;
    }
};
