const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const posix = std.posix;

/// Write to stdout via file_compat (std.debug.print writes to stderr,
/// which is wrong for ANSI escape codes and interactive TUI output).
inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Terminal UI utilities for interactive sessions
/// ANSI color codes
pub const Color = enum(u8) {
    reset = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
};

/// Print ANSI color code
pub fn color(comptime c: Color) void {
    out("\x1b[{d}m", .{@intFromEnum(c)});
}

/// Print bold color
pub fn boldColor(comptime c: Color) void {
    out("\x1b[1;{d}m", .{@intFromEnum(c)});
}

/// Reset terminal formatting
pub fn reset() void {
    color(.reset);
}

/// Clear screen
pub fn clearScreen() void {
    out("\x1b[2J", .{});
}

/// Move cursor to home position
pub fn cursorHome() void {
    out("\x1b[H", .{});
}

/// Move cursor up n lines
pub fn cursorUp(n: u32) void {
    out("\x1b[{d}A", .{n});
}

/// Move cursor down n lines
pub fn cursorDown(n: u32) void {
    out("\x1b[{d}B", .{n});
}

/// Save cursor position
pub fn saveCursor() void {
    out("\x1b[s", .{});
}

/// Restore cursor position
pub fn restoreCursor() void {
    out("\x1b[u", .{});
}

/// Get terminal size
pub fn getTerminalSize() ?struct { rows: u16, cols: u16 } {
    // Try environment variables first (most portable)
    if (file_compat.getEnv("LINES")) |lines| {
        if (file_compat.getEnv("COLUMNS")) |cols| {
            const lines_int = std.fmt.parseInt(u16, lines, 10) catch return null;
            const cols_int = std.fmt.parseInt(u16, cols, 10) catch return null;
            return .{ .rows = lines_int, .cols = cols_int };
        }
    }
    return null;
}

/// Simple line editor for interactive input
pub const LineEditor = struct {
    buffer: array_list_compat.ArrayList(u8),
    cursor_pos: usize,

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        return .{
            .buffer = array_list_compat.ArrayList(u8).init(allocator),
            .cursor_pos = 0,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit();
    }

    pub fn insert(self: *LineEditor, ch: u8) void {
        if (self.cursor_pos == self.buffer.items.len) {
            self.buffer.append(ch) catch {};
        } else {
            self.buffer.insert(ch, self.cursor_pos) catch {};
        }
        self.cursor_pos += 1;
    }

    pub fn backspace(self: *LineEditor) bool {
        if (self.cursor_pos == 0) return false;
        if (self.cursor_pos <= self.buffer.items.len) {
            _ = self.buffer.remove(self.cursor_pos - 1);
        }
        if (self.cursor_pos > 0) self.cursor_pos -= 1;
        return true;
    }

    pub fn moveLeft(self: *LineEditor) bool {
        if (self.cursor_pos == 0) return false;
        self.cursor_pos -= 1;
        return true;
    }

    pub fn moveRight(self: *LineEditor) bool {
        if (self.cursor_pos >= self.buffer.items.len) return false;
        self.cursor_pos += 1;
        return true;
    }

    pub fn getLine(self: *LineEditor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *LineEditor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }
};

/// Print a prompt with color
pub fn printPrompt(prompt: []const u8) void {
    color(.cyan);
    out("{s}", .{prompt});
    reset();
}

/// Print success message
pub fn printSuccess(msg: []const u8) void {
    color(.green);
    out("{s}", .{msg});
    reset();
}

/// Print error message
pub fn printError(msg: []const u8) void {
    color(.red);
    out("{s}", .{msg});
    reset();
}

/// Print warning message
pub fn printWarning(msg: []const u8) void {
    color(.yellow);
    out("{s}", .{msg});
    reset();
}

/// Print info message
pub fn printInfo(msg: []const u8) void {
    color(.blue);
    out("{s}", .{msg});
    reset();
}

/// Draw a separator line
pub fn drawSeparator() void {
    const size = getTerminalSize();
    const width = if (size) |s| s.cols else 80;
    out("\x1b[90m", .{});
    for (0..width) |_| out("-", .{});
    out("\x1b[0m\n", .{});
}

/// Draw a box with title
pub fn drawBox(title: []const u8, content: []const u8) void {
    drawSeparator();
    color(.magenta);
    out(" {s} ", .{title});
    reset();
    out("\n");
    drawSeparator();
    out("{s}\n", .{content});
    drawSeparator();
}

/// Run interactive TUI mode
pub fn runInteractive() !void {
    clearScreen();
    cursorHome();

    // Print welcome header
    boldColor(.cyan);
    out("╔══════════════════════════════════════╗\n", .{});
    out("║       Crushcode Interactive Mode     ║\n", .{});
    out("╚══════════════════════════════════════╝\n", .{});
    reset();

    drawSeparator();

    color(.green);
    out("Commands available:\n", .{});
    reset();
    out("  chat     - Start AI chat session\n", .{});
    out("  shell    - Execute shell command\n", .{});
    out("  read     - Read file content\n", .{});
    out("  write    - Write to file\n", .{});
    out("  git      - Git operations\n", .{});
    out("  skill    - Run built-in skills\n", .{});
    out("  help     - Show this help\n", .{});
    out("  exit     - Exit TUI\n", .{});

    drawSeparator();

    color(.yellow);
    out("Type 'exit' to leave interactive mode.\n", .{});
    reset();

    // Simple input loop
    const allocator = std.heap.page_allocator;
    var editor = LineEditor.init(allocator);
    defer editor.deinit();

    while (true) {
        out("\n", .{});
        printPrompt("crushcode> ");

        // For now, just read a line (would need raw mode for full editor)
        var input = array_list_compat.ArrayList(u8).init(allocator);
        defer input.deinit();

        // Read from stdin
        const stdin = file_compat.File.stdin();
        const reader = stdin.reader();

        // Read a line
        const line = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024) catch |err| {
            if (err == error.EndOfStream) break;
            printError("Read error\n");
            break;
        };

        if (line) |l| {
            defer allocator.free(l);

            if (std.mem.eql(u8, std.mem.trim(u8, l, " "), "exit")) {
                color(.cyan);
                out("Goodbye!\n", .{});
                reset();
                break;
            }

            if (std.mem.eql(u8, std.mem.trim(u8, l, " "), "help")) {
                color(.green);
                out("Available: chat, shell, read, write, git, skill, exit\n", .{});
                reset();
                continue;
            }

            if (l.len > 0) {
                color(.yellow);
                out("Use 'crushcode {s}' from command line\n", .{std.mem.trim(u8, l, " ")});
                reset();
            }
        }
    }
}

/// Progress indicator
pub const Progress = struct {
    label: []const u8,
    current: u32,
    total: u32,

    pub fn init(label: []const u8, total: u32) Progress {
        return .{
            .label = label,
            .current = 0,
            .total = total,
        };
    }

    pub fn update(self: *Progress, current: u32) void {
        self.current = current;
        const percent = if (self.total > 0) @divExact(self.current * 100, self.total) else 0;
        color(.cyan);
        out("\r{s}: [{s}] {d}%", .{
            self.label,
            "##########",
            percent,
        });
        reset();
    }

    pub fn finish(self: *Progress) void {
        self.update(self.total);
        out("\n", .{});
    }
};

/// Spinner for ongoing operations
pub const Spinner = struct {
    label: []const u8,
    frame: u8,
    timer: u64,

    pub fn init(label: []const u8) Spinner {
        return .{
            .label = label,
            .frame = 0,
            .timer = 0,
        };
    }

    /// Spin to next frame - call in a loop
    pub fn spin(self: *Spinner) void {
        const frames = [_]u8{ '|', '/', '-', '\\' };
        self.frame = (self.frame + 1) % frames.len;

        // Clear and rewrite line
        out("\r{s} {c}", .{ self.label, frames[self.frame] });
    }

    /// Stop the spinner
    pub fn stop(self: *Spinner) void {
        out("\r{s} Done!\n", .{self.label});
    }
};

/// Interactive selection UI
pub const Selection = struct {
    items: []const []const u8,
    selected: usize,

    pub fn init(items: []const []const u8) Selection {
        return .{
            .items = items,
            .selected = 0,
        };
    }

    /// Render the selection menu
    pub fn render(self: *Selection) void {
        for (self.items, 0..) |item, i| {
            if (i == self.selected) {
                color(.green);
                out("> {s}\n", .{item});
                reset();
            } else {
                out("  {s}\n", .{item});
            }
        }
        color(.cyan);
        out("\nUse arrow keys (↑↓) to select, Enter to confirm\n", .{});
        reset();
    }

    /// Move selection up
    pub fn moveUp(self: *Selection) void {
        if (self.selected > 0) {
            self.selected -= 1;
        }
    }

    /// Move selection down
    pub fn moveDown(self: *Selection) void {
        if (self.selected < self.items.len - 1) {
            self.selected += 1;
        }
    }

    /// Get selected item
    pub fn getSelected(self: *Selection) []const u8 {
        return self.items[self.selected];
    }
};
