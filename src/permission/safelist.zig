const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A whitelist of shell commands that are considered safe for auto-approval.
///
/// Commands are matched as case-insensitive prefixes, so "ls -la /home"
/// matches the safe entry "ls". Git commands are restricted to read-only
/// subcommands only.
pub const SafeCommandList = struct {
    allocator: Allocator,
    /// Owned command prefix strings (allocator-backed).
    safe_commands: array_list_compat.ArrayList([]const u8),

    /// Hardcoded safe commands baked into the binary.
    const default_safe_commands = [_][]const u8{
        // Read-only file operations
        "ls",
        "pwd",
        "echo",
        "cat",
        "head",
        "tail",
        "wc",
        "sort",
        "uniq",
        "tee",
        // Search tools
        "find",
        "grep",
        "rg",
        "fd",
        "ag",
        // Git read-only subcommands
        "git status",
        "git log",
        "git diff",
        "git show",
        "git branch",
        "git remote",
        "git stash list",
        "git tag",
        "git describe",
        "git rev-parse",
        "git ls-files",
        "git blame",
        // System information
        "ps",
        "df",
        "du",
        "free",
        "uptime",
        "hostname",
        "whoami",
        "uname",
        "date",
        "env",
        "which",
        "type",
        // Development tool version queries
        "node --version",
        "node -v",
        "python --version",
        "python -V",
        "python3 --version",
        "zig version",
        "cargo --version",
        "npm --version",
        "npm list",
        "npm view",
        "yarn --version",
        "pnpm --version",
        // Network read-only diagnostics
        "ping",
        "traceroute",
        "dig",
        "nslookup",
        "host",
        "ifconfig",
        "ip addr",
        // Archive listing (read-only)
        "tar -tf",
        "tar --list",
        "unzip -l",
    };

    /// Initialize the safe command list with all hardcoded defaults.
    pub fn init(allocator: Allocator) SafeCommandList {
        var self = SafeCommandList{
            .allocator = allocator,
            .safe_commands = array_list_compat.ArrayList([]const u8).init(allocator),
        };
        errdefer self.deinit();

        // Pre-populate with hardcoded defaults — safe_commands now owns these strings.
        for (&default_safe_commands) |cmd| {
            self.safe_commands.append(allocator.dupe(u8, cmd) catch @panic("OOM")) catch @panic("OOM");
        }

        return self;
    }

    /// Free all owned command strings and the list itself.
    pub fn deinit(self: *SafeCommandList) void {
        for (self.safe_commands.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.safe_commands.deinit();
    }

    /// Check whether `command` is considered safe (auto-approve).
    ///
    /// Strips leading whitespace, lowercases, then checks if the result
    /// starts with any entry in the safe list.  Matching is prefix-based:
    /// "ls -la /home" is safe because it starts with "ls".
    pub fn isSafe(self: *const SafeCommandList, command: []const u8) bool {
        // Trim leading whitespace
        const trimmed = std.mem.trimLeft(u8, command, &std.ascii.whitespace);

        if (trimmed.len == 0) return false;

        // Lowercase into a temporary buffer for comparison
        var buf: [4096]u8 = undefined;
        if (trimmed.len > buf.len) return false;
        const lowered = std.ascii.lowerString(&buf, trimmed);

        for (self.safe_commands.items) |safe_prefix| {
            // safe_prefix entries are stored in lowercase already
            if (std.mem.startsWith(u8, lowered, safe_prefix)) {
                // Ensure the match ends at a word boundary or the end of the
                // lowered string.  This prevents "envy" from matching "env".
                const end = safe_prefix.len;
                if (end == lowered.len) return true;
                const next_char = lowered[end];
                if (next_char == ' ' or next_char == '\t' or next_char == '\n') return true;
            }
        }

        return false;
    }

    /// Append a user-defined safe command prefix.
    ///
    /// The string is duplicated and owned by the allocator.
    pub fn addCommand(self: *SafeCommandList, command: []const u8) !void {
        const owned = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned);

        // Lowercase so prefix matching in isSafe works correctly
        _ = std.ascii.lowerString(owned, owned);
        try self.safe_commands.append(owned);
    }

    /// Load additional safe commands from `config_dir/safelist.json`.
    ///
    /// Expected format: `["command1", "command2", ...]`
    ///
    /// If the file does not exist the call silently succeeds.
    /// Invalid JSON or non-array top-level values are treated as errors.
    pub fn loadFromFile(self: *SafeCommandList, config_dir: []const u8) !void {
        // Build path: config_dir/safelist.json
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/safelist.json", .{config_dir}) catch return;

        // Read file — NotFound is not an error
        const contents = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(contents);

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, contents, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return;

        for (root.array.items) |item| {
            if (item == .string) {
                try self.addCommand(item.string);
            }
        }
    }

    /// Return a slice of all safe command prefixes (for display purposes).
    pub fn getCommands(self: *const SafeCommandList) []const []const u8 {
        return self.safe_commands.items;
    }
};
