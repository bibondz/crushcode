const std = @import("std");
const json = std.json;
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Hardcoded default dangerous command patterns.
/// These are always loaded regardless of user configuration.
const default_patterns = [_][]const u8{
    "rm -rf /",
    "rm -rf /*",
    "rm -rf .",
    "rm -rf *",
    "mkfs",
    "format",
    "dd if=",
    "dd of=/dev/",
    ":(){ :|:& };:",
    "fork bomb",
    "> /dev/sda",
    "> /dev/hda",
    "chmod -R 777 /",
    "chown -R .* /",
};

/// Global command blocklist for dangerous shell commands.
/// Maintains a set of blocked patterns that are checked before command execution.
/// Patterns are matched case-insensitively as substrings within the command.
pub const CommandBlocklist = struct {
    allocator: Allocator,
    patterns: array_list_compat.ArrayList([]const u8),

    /// Initialize the blocklist with hardcoded dangerous patterns.
    /// All default patterns are duplicated into the provided allocator.
    pub fn init(allocator: Allocator) CommandBlocklist {
        var self = CommandBlocklist{
            .allocator = allocator,
            .patterns = array_list_compat.ArrayList([]const u8).init(allocator),
        };

        // Load hardcoded defaults — these cannot fail since we just dupe strings
        for (default_patterns) |pattern| {
            const owned = allocator.dupe(u8, pattern) catch continue;
            self.patterns.append(owned) catch {
                allocator.free(owned);
            };
        }

        return self;
    }

    /// Free all owned pattern strings and the pattern list.
    pub fn deinit(self: *CommandBlocklist) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit();
    }

    /// Check if a command matches any blocked pattern.
    /// Returns the matched pattern string if blocked, or null if the command is safe.
    /// Comparison is case-insensitive.
    pub fn isBlocked(self: *const CommandBlocklist, command: []const u8) ?[]const u8 {
        var lower_buf: [4096]u8 = undefined;
        if (command.len > lower_buf.len) return null;
        const lower_command = std.ascii.lowerString(&lower_buf, command);

        var pattern_buf: [4096]u8 = undefined;
        for (self.patterns.items) |pattern| {
            if (pattern.len > pattern_buf.len) continue;
            const lower_pattern = std.ascii.lowerString(&pattern_buf, pattern);

            if (std.mem.indexOf(u8, lower_command, lower_pattern)) |_| {
                return pattern;
            }
        }

        return null;
    }

    /// Add a user-defined pattern to the blocklist.
    /// The pattern string is duplicated and owned by the allocator.
    pub fn addPattern(self: *CommandBlocklist, pattern: []const u8) !void {
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);
        try self.patterns.append(owned);
    }

    /// Load additional patterns from a JSON file at `config_dir/blocklist.json`.
    /// Expected format: `["pattern1", "pattern2", ...]`
    /// If the file does not exist, silently succeeds (hardcoded defaults still apply).
    /// Invalid entries (non-string values) are skipped.
    pub fn loadFromFile(self: *CommandBlocklist, config_dir: []const u8) !void {
        // Build path: config_dir/blocklist.json
        var path_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();

        const w = path_buf.writer();
        try w.writeAll(config_dir);
        try w.writeAll("/blocklist.json");

        const file_path = path_buf.items;

        // Read file contents — gracefully handle missing file
        const contents = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(contents);

        // Parse as JSON value
        const parsed = json.parseFromSlice(json.Value, self.allocator, contents, .{}) catch |err| {
            if (err == error.InvalidCharacter) return;
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return;

        // Extract string entries and add as patterns
        for (root.array.items) |item| {
            if (item == .string) {
                self.addPattern(item.string) catch continue;
            }
        }
    }

    /// Return all currently loaded patterns as a slice.
    /// Useful for display or debugging purposes.
    pub fn getPatterns(self: *const CommandBlocklist) []const []const u8 {
        return self.patterns.items;
    }
};
