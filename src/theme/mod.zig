/// Theme system inspired by ripgrep's --colors
/// Supports: element:fg:attr format (e.g., "path:fg:green", "match:bg:yellow:bold")
const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Color mode (ripgrep-compatible)
pub const ColorMode = enum {
    /// Auto-detect (enable if TTY)
    auto,
    /// Always enable colors
    always,
    /// Never enable colors
    never,

    pub fn fromString(str: []const u8) ?ColorMode {
        if (std.mem.eql(u8, str, "auto")) return .auto;
        if (std.mem.eql(u8, str, "always")) return .always;
        if (std.mem.eql(u8, str, "never")) return .never;
        return null;
    }
};

/// ANSI color codes
pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    // Bright colors
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
    // Reset
    reset = 0,

    pub fn fromString(str: []const u8) ?Color {
        const mapping = std.ComptimeStringMap(Color, .{
            .{ "black", .black },
            .{ "red", .red },
            .{ "green", .green },
            .{ "yellow", .yellow },
            .{ "blue", .blue },
            .{ "magenta", .magenta },
            .{ "cyan", .cyan },
            .{ "white", .white },
            .{ "bright-black", .bright_black },
            .{ "bright-red", .bright_red },
            .{ "bright-green", .bright_green },
            .{ "bright-yellow", .bright_yellow },
            .{ "bright-blue", .bright_blue },
            .{ "bright-magenta", .bright_magenta },
            .{ "bright-cyan", .bright_cyan },
            .{ "bright-white", .bright_white },
        });
        return mapping.get(str);
    }
};

/// Text attributes (bold, italic, etc.)
pub const Attribute = enum(u8) {
    bold = 1,
    dim = 2,
    italic = 3,
    underline = 4,
    blink = 5,
    reverse = 7,
    hidden = 8,
    strikethrough = 9,

    pub fn fromString(str: []const u8) ?Attribute {
        const mapping = std.ComptimeStringMap(Attribute, .{
            .{ "bold", .bold },
            .{ "dim", .dim },
            .{ "italic", .italic },
            .{ "underline", .underline },
            .{ "blink", .blink },
            .{ "reverse", .reverse },
            .{ "hidden", .hidden },
            .{ "strikethrough", .strikethrough },
        });
        return mapping.get(str);
    }
};

/// UI element types for theming
pub const Element = enum {
    path,
    line,
    column,
    match,
    separator,
    header,
    prompt,
    err, // "error" is reserved
    warning,
    info,
    success,
    tool,
    thinking,
    diff_add,
    diff_delete,
    context,

    pub fn fromString(str: []const u8) ?Element {
        const mapping = std.ComptimeStringMap(Element, .{
            .{ "path", .path },
            .{ "line", .line },
            .{ "column", .column },
            .{ "match", .match },
            .{ "separator", .separator },
            .{ "header", .header },
            .{ "prompt", .prompt },
            .{ "error", .err },
            .{ "warning", .warning },
            .{ "info", .info },
            .{ "success", .success },
            .{ "tool", .tool },
            .{ "thinking", .thinking },
            .{ "diff-add", .diff_add },
            .{ "diff-delete", .diff_delete },
            .{ "context", .context },
        });
        return mapping.get(str);
    }
};

/// A single style specification
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    attrs: array_list_compat.ArrayList(Attribute),

    pub fn init(allocator: Allocator) Style {
        return .{
            .attrs = array_list_compat.ArrayList(Attribute).init(allocator),
        };
    }

    pub fn deinit(self: *Style) void {
        self.attrs.deinit();
    }

    /// Convert style to ANSI escape sequence
    pub fn toAnsi(self: *const Style, allocator: Allocator) []const u8 {
        if (self.fg == null and self.bg == null and self.attrs.items.len == 0) {
            return "";
        }

        var codes = array_list_compat.ArrayList(u8).init(allocator);
        defer codes.deinit();
        const w = codes.writer();

        w.writeAll("\x1b[") catch return "";
        var first = true;

        if (self.fg) |fg| {
            w.print("{d}", .{@intFromEnum(fg)}) catch return "";
            first = false;
        }
        if (self.bg) |bg| {
            if (!first) w.writeAll(";") catch return "";
            w.print("{d}", .{@as(u8, @intFromEnum(bg)) + 10}) catch return "";
            first = false;
        }
        for (self.attrs.items) |attr| {
            if (!first) w.writeAll(";") catch return "";
            w.print("{d}", .{@intFromEnum(attr)}) catch return "";
            first = false;
        }

        w.writeAll("m") catch return "";
        return codes.items;
    }
};

/// Theme configuration
pub const Theme = struct {
    allocator: Allocator,
    styles: std.StringHashMap(Style),
    mode: ColorMode,
    is_tty: bool,

    pub fn init(allocator: Allocator, mode: ColorMode) Theme {
        return .{
            .allocator = allocator,
            .styles = std.StringHashMap(Style).init(allocator),
            .mode = mode,
            .is_tty = std.io.getStdErr().isTty(),
        };
    }

    pub fn deinit(self: Theme) void {
        var styles = self.styles;
        var iter = styles.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        styles.deinit();
    }

    /// Check if colors should be enabled
    pub fn isEnabled(self: *const Theme) bool {
        switch (self.mode) {
            .always => return true,
            .never => return false,
            .auto => return self.is_tty,
        }
    }

    /// Parse a color specification string (ripgrep-style)
    /// Format: element:fg:attr or element:fg:bg:attr
    pub fn parseSpec(self: *Theme, spec: []const u8) !void {
        var parts = std.mem.splitSequence(u8, spec, ":");
        const element_str = parts.next() orelse return error.InvalidSpec;
        _ = Element.fromString(element_str) orelse return error.InvalidElement;

        var fg: ?Color = null;
        var bg: ?Color = null;
        var attrs = array_list_compat.ArrayList(Attribute).init(self.allocator);

        while (parts.next()) |part| {
            if (Color.fromString(part)) |c| {
                if (fg == null) {
                    fg = c;
                } else if (bg == null) {
                    bg = c;
                }
            } else if (Attribute.fromString(part)) |a| {
                try attrs.append(a);
            }
        }

        var style = Style.init(self.allocator);
        style.fg = fg;
        style.bg = bg;
        style.attrs = attrs;

        const key = try self.allocator.dupe(u8, element_str);
        try self.styles.put(key, style);
    }

    /// Get style for an element
    pub fn getStyle(self: *Theme, element: Element) ?*Style {
        const key = @tagName(element);
        return self.styles.getPtr(key);
    }

    /// Apply style to string, return ANSI-escaped string
    pub fn apply(self: *Theme, element: Element, text: []const u8, allocator: Allocator) ![]const u8 {
        if (!self.isEnabled()) {
            return allocator.dupe(u8, text);
        }

        const style = self.getStyle(element) orelse {
            return allocator.dupe(u8, text);
        };

        const prefix = style.toAnsi(allocator);
        const suffix = "\x1b[0m";

        var result = array_list_compat.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(prefix);
        try result.appendSlice(text);
        try result.appendSlice(suffix);

        return result.toOwnedSlice();
    }
};

/// Create default theme with common colors
pub fn createDefaultTheme(allocator: Allocator, mode: ColorMode) !*Theme {
    var theme = try allocator.create(Theme);
    theme.* = Theme.init(allocator, mode);
    errdefer allocator.destroy(theme);

    // Default color scheme
    const defaults = [_]struct { elem: []const u8, spec: []const u8 }{
        .{ .elem = "path", .spec = "path:fg:green" },
        .{ .elem = "line", .spec = "line:fg:blue" },
        .{ .elem = "column", .spec = "column:fg:cyan" },
        .{ .elem = "match", .spec = "match:fg:yellow:bold" },
        .{ .elem = "error", .spec = "error:fg:red" },
        .{ .elem = "warning", .spec = "warning:fg:yellow" },
        .{ .elem = "success", .spec = "success:fg:green" },
        .{ .elem = "tool", .spec = "tool:fg:cyan" },
        .{ .elem = "thinking", .spec = "thinking:fg:dim" },
        .{ .elem = "diff-add", .spec = "diff-add:fg:green" },
        .{ .elem = "diff-delete", .spec = "diff-delete:fg:red" },
    };

    for (defaults) |def| {
        try theme.parseSpec(def.spec);
    }

    return theme;
}

/// Check if stdout is a TTY (for auto color mode)
pub fn isStdoutTty() bool {
    return std.io.getStdOut().isTty();
}

/// Detect appropriate color mode based on environment
pub fn detectColorMode(args_mode: ?ColorMode, env_no_color: bool) ColorMode {
    if (args_mode) |mode| {
        return mode;
    }
    if (env_no_color or !isStdoutTty()) {
        return .never;
    }
    return .auto;
}
