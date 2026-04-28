//! Configurable keybindings for the TUI.
//!
//! Loads key mappings from `~/.crushcode/keymap.toml`. If the file doesn't
//! exist, built-in defaults are used. The config uses action names as keys
//! and vaxis key notation as values.
//!
//! Example keymap.toml:
//!   [keymap]
//!   send_message = "enter"
//!   new_line = "ctrl+j"
//!   history_up = "up"
//!   history_down = "down"
//!   cancel = "escape"
//!   accept_suggestion = "tab"
//!   toggle_sidebar = "ctrl+b"

const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Action names that can be remapped.
pub const Action = enum {
    send_message,
    new_line,
    history_up,
    history_down,
    cancel,
    accept_suggestion,
    toggle_sidebar,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
    palette,
    compact,
    help,
};

/// Default key bindings (action → key name string).
const defaults = std.StaticStringMap([]const u8).initComptime(.{
    .{ "send_message", "enter" },
    .{ "new_line", "ctrl+j" },
    .{ "history_up", "up" },
    .{ "history_down", "down" },
    .{ "cancel", "escape" },
    .{ "accept_suggestion", "tab" },
    .{ "toggle_sidebar", "ctrl+b" },
    .{ "scroll_up", "k" },
    .{ "scroll_down", "j" },
    .{ "page_up", "page_up" },
    .{ "page_down", "page_down" },
    .{ "palette", "ctrl+p" },
    .{ "compact", "ctrl+k" },
    .{ "help", "f1" },
});

/// Loaded keymap: action name → key string.
/// Falls back to defaults for unmapped actions.
pub const Keymap = struct {
    allocator: Allocator,
    bindings: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) !Keymap {
        var km = Keymap{
            .allocator = allocator,
            .bindings = std.StringHashMap([]const u8).init(allocator),
        };

        // Load defaults first
        var default_iter = defaults.iterator();
        while (default_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = try allocator.dupe(u8, entry.value_ptr.*);
            km.bindings.put(key, val) catch {};
        }

        // Try to load user config
        km.loadFromConfig() catch {};

        return km;
    }

    pub fn deinit(self: *Keymap) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.bindings.deinit();
    }

    /// Get the key string for an action. Returns default if not found.
    pub fn get(self: *const Keymap, action: []const u8) []const u8 {
        return self.bindings.get(action) orelse "unknown";
    }

    /// Check if an action is mapped to a specific key string.
    pub fn isBoundTo(self: *const Keymap, action: Action, key_name: []const u8) bool {
        const action_name = @tagName(action);
        const bound = self.bindings.get(action_name) orelse return false;
        return std.mem.eql(u8, bound, key_name);
    }

    fn loadFromConfig(self: *Keymap) !void {
        const allocator = self.allocator;

        // Build config path: ~/.crushcode/keymap.toml
        const home = file_compat.getEnv(allocator, "HOME") orelse return error.HomeNotFound;
        defer allocator.free(home);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/.crushcode/keymap.toml", .{home});
        defer allocator.free(config_path);

        const file = std.fs.cwd().openFile(config_path, .{}) catch return;
        defer file.close();

        const contents = file.readToEndAlloc(allocator, 4096) catch return;
        defer allocator.free(contents);

        // Simple TOML parsing: look for [keymap] section and key = "value" entries
        var in_keymap_section = false;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.eql(u8, trimmed, "[keymap]")) {
                in_keymap_section = true;
                continue;
            }
            if (trimmed[0] == '[') {
                in_keymap_section = false;
                continue;
            }

            if (!in_keymap_section) continue;

            // Parse key = "value"
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val_raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Strip quotes from value
            if (val_raw.len < 2) continue;
            const val = if ((val_raw[0] == '"' and val_raw[val_raw.len - 1] == '"') or
                (val_raw[0] == '\'' and val_raw[val_raw.len - 1] == '\''))
                val_raw[1 .. val_raw.len - 1]
            else
                val_raw;

            // Update binding
            if (self.bindings.getPtr(key)) |existing| {
                self.allocator.free(existing.*);
                existing.* = try allocator.dupe(u8, val);
            } else {
                const duped_key = try allocator.dupe(u8, key);
                const duped_val = try allocator.dupe(u8, val);
                self.bindings.put(duped_key, duped_val) catch {};
            }
        }
    }
};
