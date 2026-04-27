/// UserModel — persistent user preference tracking across sessions.
///
/// Tracks coding style, preferred tools, language, naming conventions, and
/// common tasks.  Persists to ~/.crushcode/USER.md as human-readable Markdown.
/// Loaded on startup, updated after sessions, and injected into system prompt.
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// ── PreferenceSource ────────────────────────────────────────────────────────

pub const PreferenceSource = enum {
    observed,
    explicit,
};

// ── UserPreference ──────────────────────────────────────────────────────────

pub const UserPreference = struct {
    key: []const u8,
    value: []const u8,
    source: PreferenceSource,
    confidence: f32,
    updated_at: u64,
};

// ── UserModel ───────────────────────────────────────────────────────────────

pub const UserModel = struct {
    allocator: Allocator,
    preferences: std.StringHashMap(UserPreference),
    file_path: []const u8,
    loaded: bool,

    // ── Lifecycle ──────────────────────────────────────────────────────────

    pub fn init(allocator: Allocator) !UserModel {
        const home = file_compat.getEnv("HOME") orelse "";
        const file_path: []const u8 = if (home.len > 0)
            try std.fs.path.join(allocator, &.{ home, ".crushcode", "USER.md" })
        else
            try allocator.dupe(u8, "USER.md");

        return UserModel{
            .allocator = allocator,
            .preferences = std.StringHashMap(UserPreference).init(allocator),
            .file_path = file_path,
            .loaded = false,
        };
    }

    pub fn deinit(self: *UserModel) void {
        var it = self.preferences.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.preferences.deinit();
        self.allocator.free(self.file_path);
    }

    // ── Persistence ────────────────────────────────────────────────────────

    /// Load preferences from USER.md file (Markdown table format).
    pub fn load(self: *UserModel) !void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                self.loaded = true;
                return;
            }
            return err;
        };
        defer self.allocator.free(content);

        // Parse Markdown table rows: | key | value | source | confidence |
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            // Skip header and separator rows
            if (!std.mem.startsWith(u8, trimmed, "|")) continue;
            if (std.mem.startsWith(u8, trimmed, "| Key")) continue;
            if (std.mem.startsWith(u8, trimmed, "|---")) continue;
            if (std.mem.startsWith(u8, trimmed, "|-")) continue;

            var parts = std.mem.splitSequence(u8, trimmed, "|");
            _ = parts.next(); // skip empty before first |
            const key_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const val_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const src_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const conf_str = std.mem.trim(u8, parts.next() orelse continue, " \t");

            if (key_str.len == 0 or val_str.len == 0) continue;

            const source: PreferenceSource = if (std.mem.eql(u8, src_str, "explicit"))
                .explicit
            else
                .observed;

            const confidence: f32 = std.fmt.parseFloat(f32, conf_str) catch 0.5;
            const now = @as(u64, @intCast(std.time.milliTimestamp()));

            const key_owned = try self.allocator.dupe(u8, key_str);
            errdefer self.allocator.free(key_owned);
            const val_owned = try self.allocator.dupe(u8, val_str);
            errdefer self.allocator.free(val_owned);

            // Free existing entry if present
            if (self.preferences.getPtr(key_str)) |existing| {
                self.allocator.free(existing.value);
                existing.* = .{
                    .key = key_owned,
                    .value = val_owned,
                    .source = source,
                    .confidence = confidence,
                    .updated_at = now,
                };
                self.allocator.free(key_owned); // key already in map, don't re-add
            } else {
                try self.preferences.put(key_owned, .{
                    .key = key_owned,
                    .value = val_owned,
                    .source = source,
                    .confidence = confidence,
                    .updated_at = now,
                });
            }
        }
        self.loaded = true;
    }

    /// Save preferences to USER.md as human-readable Markdown table.
    pub fn save(self: *UserModel) !void {
        // Ensure directory exists
        if (std.fs.path.dirname(self.file_path)) |dir_path| {
            std.fs.cwd().makePath(dir_path) catch {};
        }

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        w.writeAll("# User Preferences\n\n") catch return;
        w.writeAll("| Key | Value | Source | Confidence |\n") catch return;
        w.writeAll("|-----|-------|--------|------------|\n") catch return;

        var it = self.preferences.iterator();
        while (it.next()) |entry| {
            const pref = entry.value_ptr.*;
            const src_label: []const u8 = switch (pref.source) {
                .explicit => "explicit",
                .observed => "observed",
            };
            w.print("| {s} | {s} | {s} | {d:.2} |\n", .{ pref.key, pref.value, src_label, pref.confidence }) catch return;
        }

        w.writeAll("\n") catch return;

        const data = buf.items;
        const file = std.fs.cwd().createFile(self.file_path, .{ .truncate = true }) catch return;
        defer file.close();
        file.writeAll(data) catch {};
    }

    // ── Access ─────────────────────────────────────────────────────────────

    /// Get a preference value by key.  Returns null if not found.
    pub fn get(self: *UserModel, key: []const u8) ?[]const u8 {
        if (self.preferences.get(key)) |pref| {
            return pref.value;
        }
        return null;
    }

    /// Set a preference (creates or updates).  Caller owns nothing — values
    /// are copied internally.
    pub fn set(self: *UserModel, key: []const u8, value: []const u8, source: PreferenceSource) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        const val_owned = try self.allocator.dupe(u8, value);

        if (self.preferences.getPtr(key)) |existing| {
            self.allocator.free(existing.value);
            existing.* = .{
                .key = existing.key,
                .value = val_owned,
                .source = source,
                .confidence = 1.0,
                .updated_at = now,
            };
        } else {
            const key_owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_owned);
            try self.preferences.put(key_owned, .{
                .key = key_owned,
                .value = val_owned,
                .source = source,
                .confidence = 1.0,
                .updated_at = now,
            });
        }
    }

    // ── Observation ────────────────────────────────────────────────────────

    /// Observe user behaviour and infer preferences.  Call after each tool
    /// invocation to gradually build up a user profile.
    pub fn observe(self: *UserModel, event: []const u8, detail: []const u8) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));

        if (std.mem.eql(u8, event, "tool_used")) {
            // Track which tools the user prefers
            const tool_key = "preferred_tools";
            if (self.preferences.getPtr(tool_key)) |existing| {
                // Append if not already present
                if (!std.mem.containsAtLeast(u8, existing.value, 1, detail)) {
                    const new_val = try std.fmt.allocPrint(self.allocator, "{s}, {s}", .{ existing.value, detail });
                    self.allocator.free(existing.value);
                    existing.value = new_val;
                    existing.confidence = @min(existing.confidence + 0.1, 1.0);
                    existing.updated_at = now;
                }
            } else {
                const key_owned = try self.allocator.dupe(u8, tool_key);
                const val_owned = try self.allocator.dupe(u8, detail);
                try self.preferences.put(key_owned, .{
                    .key = key_owned,
                    .value = val_owned,
                    .source = .observed,
                    .confidence = 0.6,
                    .updated_at = now,
                });
            }
        } else if (std.mem.eql(u8, event, "language_detected")) {
            try self.setWithConfidence("preferred_language", detail, .observed, 0.8);
        } else if (std.mem.eql(u8, event, "naming_style")) {
            try self.setWithConfidence("naming_convention", detail, .observed, 0.7);
        } else if (std.mem.eql(u8, event, "coding_style")) {
            try self.setWithConfidence("coding_style", detail, .observed, 0.7);
        }
    }

    /// Internal helper — set a preference with a specific confidence value.
    fn setWithConfidence(self: *UserModel, key: []const u8, value: []const u8, source: PreferenceSource, confidence: f32) !void {
        if (confidence < 0.5) return; // Avoid noise

        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        const val_owned = try self.allocator.dupe(u8, value);

        if (self.preferences.getPtr(key)) |existing| {
            self.allocator.free(existing.value);
            // Increase confidence slightly on repeated observation
            const new_conf = @min(existing.confidence + 0.05, 1.0);
            existing.* = .{
                .key = existing.key,
                .value = val_owned,
                .source = source,
                .confidence = new_conf,
                .updated_at = now,
            };
        } else {
            const key_owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_owned);
            try self.preferences.put(key_owned, .{
                .key = key_owned,
                .value = val_owned,
                .source = source,
                .confidence = confidence,
                .updated_at = now,
            });
        }
    }

    // ── Prompt generation ──────────────────────────────────────────────────

    /// Build a system prompt section with current preferences.
    /// Returns an owned string that the caller must free, or null when empty.
    pub fn toPromptSection(self: *UserModel) !?[]const u8 {
        if (self.preferences.count() == 0) return null;

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        var it = self.preferences.iterator();
        while (it.next()) |entry| {
            const pref = entry.value_ptr.*;
            // Format key for display: replace underscores with spaces, title-case first letter
            const display_key = pref.key;
            const first: u8 = if (display_key.len > 0 and display_key[0] >= 'a' and display_key[0] <= 'z')
                display_key[0] - 32
            else if (display_key.len > 0)
                display_key[0]
            else
                ' ';

            w.print("- {c}{s}: {s}\n", .{ first, display_key[1..], pref.value }) catch return null;
        }

        return try self.allocator.dupe(u8, buf.items);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "UserModel init/deinit" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    um.deinit();
}

test "UserModel set/get roundtrip" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    defer um.deinit();

    try um.set("coding_style", "terse", .explicit);
    const val = um.get("coding_style");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("terse", val.?);

    // Missing key returns null
    try std.testing.expect(um.get("nonexistent") == null);
}

test "UserModel set overwrites previous value" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    defer um.deinit();

    try um.set("lang", "python", .explicit);
    try std.testing.expectEqualStrings("python", um.get("lang").?);

    try um.set("lang", "zig", .explicit);
    try std.testing.expectEqualStrings("zig", um.get("lang").?);
}

test "UserModel load/save roundtrip" {
    const allocator = std.testing.allocator;

    // Use /tmp path for test
    const tmp_path = "/tmp/crushcode_test_user_model.md";
    std.fs.cwd().deleteFile(tmp_path) catch {};

    var um = UserModel{
        .allocator = allocator,
        .preferences = std.StringHashMap(UserPreference).init(allocator),
        .file_path = try allocator.dupe(u8, tmp_path),
        .loaded = false,
    };
    defer {
        var it = um.preferences.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.value);
        }
        um.preferences.deinit();
        allocator.free(um.file_path);
    }

    // Set some preferences and save
    try um.set("coding_style", "terse", .explicit);
    try um.set("preferred_language", "zig", .observed);
    try um.save();

    // Load into a fresh model
    var um2 = UserModel{
        .allocator = allocator,
        .preferences = std.StringHashMap(UserPreference).init(allocator),
        .file_path = try allocator.dupe(u8, tmp_path),
        .loaded = false,
    };
    defer {
        var it2 = um2.preferences.iterator();
        while (it2.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.value);
        }
        um2.preferences.deinit();
        allocator.free(um2.file_path);
    }

    try um2.load();
    try std.testing.expectEqualStrings("terse", um2.get("coding_style").?);
    try std.testing.expectEqualStrings("zig", um2.get("preferred_language").?);

    // Clean up
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "UserModel observe updates confidence" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    defer um.deinit();

    try um.observe("tool_used", "edit");
    const tools = um.get("preferred_tools");
    try std.testing.expect(tools != null);
    try std.testing.expectEqualStrings("edit", tools.?);

    // Observe another tool — should append
    try um.observe("tool_used", "shell");
    const updated = um.get("preferred_tools");
    try std.testing.expect(updated != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, updated.?, 1, "edit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, updated.?, 1, "shell"));

    // Observe language
    try um.observe("language_detected", "zig");
    try std.testing.expectEqualStrings("zig", um.get("preferred_language").?);

    // Observe naming style
    try um.observe("naming_style", "camelCase");
    try std.testing.expectEqualStrings("camelCase", um.get("naming_convention").?);
}

test "UserModel toPromptSection generates valid output" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    defer um.deinit();

    try um.set("coding_style", "terse", .explicit);
    try um.set("preferred_language", "zig", .observed);

    const section = try um.toPromptSection();
    try std.testing.expect(section != null);
    defer allocator.free(section.?);

    try std.testing.expect(std.mem.containsAtLeast(u8, section.?, 1, "terse"));
    try std.testing.expect(std.mem.containsAtLeast(u8, section.?, 1, "zig"));
}

test "UserModel empty model returns null from toPromptSection" {
    const allocator = std.testing.allocator;
    var um = try UserModel.init(allocator);
    defer um.deinit();

    const result = try um.toPromptSection();
    try std.testing.expect(result == null);
}
