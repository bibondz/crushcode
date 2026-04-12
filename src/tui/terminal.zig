const std = @import("std");
const file_compat = @import("file_compat");

const builtin = @import("builtin");
const os_tag = builtin.target.os.tag;

pub const Terminal = struct {
    tty_in: file_compat.File,
    tty_out: file_compat.File,
    allocator: std.mem.Allocator,
    original_state: OriginalState,
    supports_alt_screen: bool,

    const OriginalState = struct {
        // POSIX: saved termios
        termios: if (os_tag != .windows) std.posix.termios else void,
        // Windows: saved console mode (future: use std.os.windows API)
    };

    /// Detect if the terminal supports alternate screen buffer
    fn detectAltScreen() bool {
        // Windows Terminal sets WT_SESSION, ConEmu sets ConEmuANSI
        if (os_tag == .windows) {
            if (std.posix.getenv("WT_SESSION")) |_| return true;
            if (std.posix.getenv("ConEmuANSI")) |v| {
                if (v.len > 0 and v[0] == 'O' and v[1] == 'N') return true;
            }
            return false; // CMD/legacy PowerShell: no alt screen
        }
        // POSIX: most modern terminals support it
        // Check TERM for known non-supporting terminals
        if (std.posix.getenv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) return false;
        }
        return true;
    }

    /// Initialize terminal for TUI mode.
    pub fn init(allocator: std.mem.Allocator) !Terminal {
        const stdin = file_compat.File.stdin();
        const stdout = file_compat.File.stdout();
        const supports_alt = detectAltScreen();

        var original_state: OriginalState = undefined;

        if (os_tag != .windows) {
            // POSIX: enable raw mode via termios
            const original = try std.posix.tcgetattr(stdin.handle);

            var raw = original;
            raw.lflag.ECHO = false; // Don't echo input
            raw.lflag.ICANON = false; // Byte-by-byte mode
            raw.lflag.ISIG = false; // Disable signal generation
            raw.lflag.IEXTEN = false; // Disable Ctrl-V paste
            raw.iflag.IXON = false; // Disable flow control
            raw.iflag.ICRNL = false; // Don't translate CR to NL
            raw.iflag.BRKINT = false; // Don't send SIGINT on break
            raw.oflag.OPOST = false; // Don't post-process output
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0; // Non-blocking read
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 100ms timeout for escape sequences

            try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);
            original_state.termios = original;
        } else {
            // Windows: use virtual terminal processing
            // Zig's std.os.windows provides SetConsoleMode
            // For now, just set a void state — Windows raw mode needs
            // kernel32:SetConsoleMode(handle, ENABLE_VIRTUAL_TERMINAL_INPUT)
            original_state.termios = {};
        }

        const out = stdout.writer();

        // Enter alternate screen only if supported
        if (supports_alt) {
            out.print("\x1b[?1049h", .{}) catch {};
        }

        // Hide cursor (widely supported)
        out.print("\x1b[?25l", .{}) catch {};

        return .{
            .tty_in = stdin,
            .tty_out = stdout,
            .allocator = allocator,
            .original_state = original_state,
            .supports_alt_screen = supports_alt,
        };
    }

    /// Restore the terminal to its original state.
    pub fn deinit(self: *Terminal) void {
        const out = self.tty_out.writer();

        // Show cursor
        out.print("\x1b[?25h", .{}) catch {};

        // Reset all formatting
        out.print("\x1b[0m", .{}) catch {};

        // Exit alternate screen only if we entered it
        if (self.supports_alt_screen) {
            out.print("\x1b[?1049l", .{}) catch {};
        } else {
            // On terminals without alt screen, clear screen and go home
            out.print("\x1b[2J\x1b[H", .{}) catch {};
        }

        // Restore original terminal settings
        if (os_tag != .windows) {
            std.posix.tcsetattr(self.tty_in.handle, .FLUSH, self.original_state.termios) catch {};
        }
        // Windows: would restore console mode here
    }

    /// Get the terminal window size.
    pub fn getSize(self: *const Terminal) struct { width: u16, height: u16 } {
        if (os_tag != .windows) {
            var ws: std.posix.winsize = undefined;
            const result = std.posix.system.ioctl(
                self.tty_out.handle,
                std.posix.T.IOCGWINSZ,
                @intFromPtr(&ws),
            );
            if (result == 0) {
                return .{ .width = ws.col, .height = ws.row };
            }
        }
        // Windows fallback: would use GetConsoleScreenBufferInfo
        // Universal fallback: check environment variables
        if (std.posix.getenv("COLUMNS")) |cols| {
            if (std.posix.getenv("LINES")) |lines| {
                const w = std.fmt.parseInt(u16, cols, 10) catch 80;
                const h = std.fmt.parseInt(u16, lines, 10) catch 24;
                return .{ .width = w, .height = h };
            }
        }
        return .{ .width = 80, .height = 24 };
    }

    /// Get the terminal writer.
    pub fn writer(self: *Terminal) file_compat.File.Writer {
        return self.tty_out.writer();
    }

    /// Flush pending output.
    pub fn flush(self: *Terminal) void {
        // No-op: TTY handles buffering automatically
        _ = self;
    }

    /// Check if terminal supports 24-bit color
    pub fn supportsTrueColor(self: *Terminal) bool {
        _ = self;
        if (std.posix.getenv("COLORTERM")) |ct| {
            if (std.mem.indexOf(u8, ct, "truecolor") != null or
                std.mem.indexOf(u8, ct, "24bit") != null)
                return true;
        }
        return false;
    }
};
