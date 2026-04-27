/// FeedbackStore — task outcome tracking and quality rating for self-improvement.
///
/// Records task outcomes (success/failure/partial), computes quality scores,
/// and persists history to ~/.crushcode/feedback.json.  Provides statistics,
/// recommended tools per task type, and a prompt section for learned preferences.
const file_compat = @import("file_compat");
const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ── TaskOutcome ──────────────────────────────────────────────────────────────

pub const TaskOutcome = enum {
    success,
    failure,
    partial,
};

// ── FeedbackEntry ────────────────────────────────────────────────────────────

pub const FeedbackEntry = struct {
    task_id: []const u8,
    task_type: []const u8,
    tools_used: []const u8, // comma-separated tool names
    outcome: TaskOutcome,
    quality_score: f32,
    error_message: []const u8,
    timestamp: u64,
    user_rating: ?u8,
};

// ── TypeStats ────────────────────────────────────────────────────────────────

pub const TypeStats = struct {
    count: u32,
    success_count: u32,
    avg_quality: f32,
};

// ── FeedbackStore ────────────────────────────────────────────────────────────

pub const FeedbackStore = struct {
    allocator: Allocator,
    entries: array_list_compat.ArrayList(FeedbackEntry),
    file_path: []const u8,
    max_entries: u32,

    pub fn init(allocator: Allocator) !FeedbackStore {
        const home = file_compat.getEnv("HOME") orelse "";
        const file_path: []const u8 = if (home.len > 0)
            try std.fs.path.join(allocator, &.{ home, ".crushcode", "feedback.json" })
        else
            try allocator.dupe(u8, "feedback.json");

        return FeedbackStore{
            .allocator = allocator,
            .entries = array_list_compat.ArrayList(FeedbackEntry).init(allocator),
            .file_path = file_path,
            .max_entries = 1000,
        };
    }

    pub fn deinit(self: *FeedbackStore) void {
        self.clearEntries();
        self.entries.deinit();
        self.allocator.free(self.file_path);
    }

    fn clearEntries(self: *FeedbackStore) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.task_id);
            self.allocator.free(e.task_type);
            self.allocator.free(e.tools_used);
            self.allocator.free(e.error_message);
        }
    }

    // ── Persistence ────────────────────────────────────────────────────────

    /// Load feedback history from disk.
    pub fn load(self: *FeedbackStore) !void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 4 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(content);

        const parsed = std.json.parseFromSlice(
            []const JsonEntry,
            self.allocator,
            content,
            .{ .ignore_unknown_fields = true },
        ) catch return;
        defer parsed.deinit();

        self.clearEntries();
        self.entries.clearRetainingCapacity();

        for (parsed.value) |je| {
            const entry = FeedbackEntry{
                .task_id = je.task_id,
                .task_type = je.task_type,
                .tools_used = je.tools_used,
                .outcome = je.outcome,
                .quality_score = je.quality_score,
                .error_message = je.error_message,
                .timestamp = je.timestamp,
                .user_rating = je.user_rating,
            };
            self.entries.append(entry) catch continue;
        }
    }

    /// Save feedback history to disk.
    pub fn save(self: *FeedbackStore) !void {
        if (std.fs.path.dirname(self.file_path)) |dir_path| {
            std.fs.cwd().makePath(dir_path) catch {};
        }

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        w.writeAll("[") catch return;
        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) w.writeAll(",") catch return;
            const rating_str: []const u8 = if (entry.user_rating) |r|
                try std.fmt.allocPrint(self.allocator, "{d}", .{r})
            else
                "null";
            defer {
                if (entry.user_rating != null) self.allocator.free(rating_str);
            }
            w.print(
                \\{{"task_id":"{s}","task_type":"{s}","tools_used":"{s}","outcome":"{s}","quality_score":{d:.2},"error_message":"{s}","timestamp":{d},"user_rating":{s}}}
            , .{
                entry.task_id,
                entry.task_type,
                entry.tools_used,
                @tagName(entry.outcome),
                entry.quality_score,
                entry.error_message,
                entry.timestamp,
                rating_str,
            }) catch return;
        }
        w.writeAll("]") catch return;

        const file = std.fs.cwd().createFile(self.file_path, .{ .truncate = true }) catch return;
        defer file.close();
        file.writeAll(buf.items) catch {};
    }

    // ── Recording ──────────────────────────────────────────────────────────

    /// Record a task outcome.
    pub fn record(self: *FeedbackStore, task_type: []const u8, tools: []const []const u8, outcome: TaskOutcome, quality: f32, err_msg: []const u8) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));

        // Build task_id from timestamp + task_type
        const task_id = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ task_type, now });

        // Build comma-separated tools string
        var tools_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer tools_buf.deinit();
        const tw = tools_buf.writer();
        for (tools, 0..) |tool, i| {
            if (i > 0) tw.writeAll(",") catch {};
            tw.writeAll(tool) catch {};
        }
        const tools_str = try self.allocator.dupe(u8, tools_buf.items);

        // Compute quality score
        var computed_quality: f32 = quality;
        if (quality <= 0.0) {
            computed_quality = switch (outcome) {
                .success => @min(0.8 + @as(f32, @floatFromInt(tools.len)) * 0.1, 1.0),
                .partial => 0.5,
                .failure => if (err_msg.len > 0) @max(0.2 - 0.1, 0.0) else 0.2,
            };
        }

        const type_owned = try self.allocator.dupe(u8, task_type);
        const err_owned = try self.allocator.dupe(u8, err_msg);

        const entry = FeedbackEntry{
            .task_id = task_id,
            .task_type = type_owned,
            .tools_used = tools_str,
            .outcome = outcome,
            .quality_score = computed_quality,
            .error_message = err_owned,
            .timestamp = now,
            .user_rating = null,
        };

        try self.entries.append(entry);

        // Trim to max_entries
        while (self.entries.items.len > self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.task_id);
            self.allocator.free(old.task_type);
            self.allocator.free(old.tools_used);
            self.allocator.free(old.error_message);
        }

        self.save() catch {};
    }

    /// Record a user rating for a task by task_id.
    pub fn rateTask(self: *FeedbackStore, task_id: []const u8, rating: u8) !void {
        if (rating < 1 or rating > 5) return error.InvalidRating;
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.task_id, task_id)) {
                e.user_rating = rating;
                // Adjust quality based on user rating
                e.quality_score = @as(f32, @floatFromInt(rating)) / 5.0;
                self.save() catch {};
                return;
            }
        }
        return error.TaskNotFound;
    }

    // ── Statistics ─────────────────────────────────────────────────────────

    /// Get success rate for a specific task type.
    pub fn getSuccessRate(self: *FeedbackStore, task_type: []const u8) f32 {
        var total: u32 = 0;
        var success: u32 = 0;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.task_type, task_type)) {
                total += 1;
                if (e.outcome == .success) success += 1;
            }
        }
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(success)) / @as(f32, @floatFromInt(total));
    }

    /// Get per-type statistics for all types present in the entries.
    pub fn getTypeStats(self: *FeedbackStore) !std.StringHashMap(TypeStats) {
        var map = std.StringHashMap(TypeStats).init(self.allocator);
        errdefer map.deinit();

        for (self.entries.items) |e| {
            const gop = try map.getOrPut(e.task_type);
            if (!gop.found_existing) {
                gop.value_ptr.* = TypeStats{ .count = 0, .success_count = 0, .avg_quality = 0.0 };
            }
            gop.value_ptr.count += 1;
            if (e.outcome == .success) gop.value_ptr.success_count += 1;
            gop.value_ptr.avg_quality += e.quality_score;
        }

        // Compute averages
        var it = map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.count > 0) {
                entry.value_ptr.avg_quality /= @as(f32, @floatFromInt(entry.value_ptr.count));
            }
        }

        return map;
    }

    /// Get recommended tools for a task type (highest success rate combos).
    /// Returns up to 3 tool combination strings, ordered by success rate.
    pub fn getRecommendedTools(self: *FeedbackStore, task_type: []const u8) ![][]const u8 {
        // Collect tool combos and their success counts
        var combo_map = std.StringHashMap(struct { success: u32, total: u32 }).init(self.allocator);
        defer {
            var it = combo_map.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            combo_map.deinit();
        }

        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.task_type, task_type)) continue;
            const gop = try combo_map.getOrPut(e.tools_used);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .success = 0, .total = 0 };
                // Need to dupe the key since e.tools_used is owned by the entry
                const owned_key = try self.allocator.dupe(u8, e.tools_used);
                gop.key_ptr.* = owned_key;
            }
            gop.value_ptr.total += 1;
            if (e.outcome == .success) gop.value_ptr.success += 1;
        }

        // Collect into array for sorting
        var results = array_list_compat.ArrayList(struct { tools: []const u8, rate: f32 }).init(self.allocator);
        defer results.deinit();

        var it = combo_map.iterator();
        while (it.next()) |entry| {
            const rate: f32 = if (entry.value_ptr.total > 0)
                @as(f32, @floatFromInt(entry.value_ptr.success)) / @as(f32, @floatFromInt(entry.value_ptr.total))
            else
                0.0;
            try results.append(.{ .tools = entry.key_ptr.*, .rate = rate });
        }

        // Sort by rate descending (simple bubble sort — small N)
        const items = results.items;
        for (0..items.len) |i| {
            for (i + 1..items.len) |j| {
                if (items[j].rate > items[i].rate) {
                    const tmp = items[i];
                    items[i] = items[j];
                    items[j] = tmp;
                }
            }
        }

        const limit = @min(items.len, 3);
        var out = array_list_compat.ArrayList([]const u8).init(self.allocator);
        for (items[0..limit]) |item| {
            try out.append(item.tools);
        }
        return try out.toOwnedSlice();
    }

    /// Build a prompt section with learned preferences.
    /// Returns an owned string that the caller must free, or null when empty.
    pub fn toPromptSection(self: *FeedbackStore) !?[]const u8 {
        if (self.entries.items.len == 0) return null;

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        var type_stats = try self.getTypeStats();
        defer type_stats.deinit();

        var it = type_stats.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll("\n");
            first = false;

            const rate: f32 = if (entry.value_ptr.count > 0)
                @as(f32, @floatFromInt(entry.value_ptr.success_count)) / @as(f32, @floatFromInt(entry.value_ptr.count)) * 100.0
            else
                0.0;

            // Capitalize first letter of task_type
            const tt = entry.key_ptr.*;
            const first_char: u8 = if (tt.len > 0 and tt[0] >= 'a' and tt[0] <= 'z')
                tt[0] - 32
            else if (tt.len > 0)
                tt[0]
            else
                '?';

            try w.print("- {c}{s} tasks: {d:.0}% success (avg quality: {d:.2})\n", .{
                first_char,
                if (tt.len > 0) tt[1..] else "",
                rate,
                entry.value_ptr.avg_quality,
            });

            // Show recommended tools
            const tools_list = try self.getRecommendedTools(tt);
            defer self.allocator.free(tools_list);
            if (tools_list.len > 0) {
                try w.writeAll("  Recommended tools: ");
                for (tools_list, 0..) |t, i| {
                    if (i > 0) try w.writeAll(" | ");
                    // Convert comma-separated to arrow-separated for display
                    var parts = std.mem.splitSequence(u8, t, ",");
                    var part_first = true;
                    while (parts.next()) |part| {
                        if (!part_first) try w.writeAll(" → ");
                        part_first = false;
                        try w.writeAll(part);
                    }
                }
                try w.writeAll("\n");
            }
        }

        if (buf.items.len == 0) return null;
        return try self.allocator.dupe(u8, buf.items);
    }

    /// Format stats for display in /feedback command.
    pub fn formatStats(self: *FeedbackStore) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        const total: u32 = @intCast(self.entries.items.len);
        var success_count: u32 = 0;
        var failure_count: u32 = 0;
        var partial_count: u32 = 0;
        var total_quality: f32 = 0.0;

        for (self.entries.items) |e| {
            switch (e.outcome) {
                .success => success_count += 1,
                .failure => failure_count += 1,
                .partial => partial_count += 1,
            }
            total_quality += e.quality_score;
        }

        const avg_quality: f32 = if (total > 0) total_quality / @as(f32, @floatFromInt(total)) else 0.0;
        const overall_rate: f32 = if (total > 0) @as(f32, @floatFromInt(success_count)) / @as(f32, @floatFromInt(total)) * 100.0 else 0.0;

        try w.print(
            \\Feedback Statistics:
            \\  Total tasks:    {d}
            \\  Success:        {d} ({d:.0}%)
            \\  Partial:        {d}
            \\  Failure:        {d}
            \\  Avg quality:    {d:.2}
            \\
        , .{ total, success_count, overall_rate, partial_count, failure_count, avg_quality });

        // Per-type breakdown
        var type_stats = try self.getTypeStats();
        defer type_stats.deinit();

        if (type_stats.count() > 0) {
            try w.writeAll("\nBreakdown by task type:\n");
            var it = type_stats.iterator();
            while (it.next()) |entry| {
                const rate: f32 = if (entry.value_ptr.count > 0)
                    @as(f32, @floatFromInt(entry.value_ptr.success_count)) / @as(f32, @floatFromInt(entry.value_ptr.count)) * 100.0
                else
                    0.0;
                try w.print("  {s}: {d} tasks, {d:.0}% success, quality {d:.2}\n", .{
                    entry.key_ptr.*,
                    entry.value_ptr.count,
                    rate,
                    entry.value_ptr.avg_quality,
                });
            }
        }

        return try self.allocator.dupe(u8, buf.items);
    }

    /// Format recent N entries for display.
    pub fn formatRecent(self: *FeedbackStore, limit: usize) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        const start = if (self.entries.items.len > limit) self.entries.items.len - limit else 0;
        if (start >= self.entries.items.len) {
            try w.writeAll("No feedback entries recorded yet.\n");
            return try self.allocator.dupe(u8, buf.items);
        }

        try w.writeAll("Recent feedback entries:\n");
        for (self.entries.items[start..]) |e| {
            const outcome_label: []const u8 = switch (e.outcome) {
                .success => "✓",
                .failure => "✗",
                .partial => "◐",
            };
            const rating_str: []const u8 = if (e.user_rating) |r|
                try std.fmt.allocPrint(self.allocator, " | rated {d}/5", .{r})
            else
                "";
            defer {
                if (e.user_rating != null) self.allocator.free(rating_str);
            }

            try w.print("  {s} [{s}] {s} — quality: {d:.2}{s}\n", .{
                outcome_label,
                e.task_type,
                e.task_id,
                e.quality_score,
                rating_str,
            });
            if (e.tools_used.len > 0) {
                try w.print("    tools: {s}\n", .{e.tools_used});
            }
            if (e.error_message.len > 0) {
                try w.print("    error: {s}\n", .{e.error_message});
            }
        }

        return try self.allocator.dupe(u8, buf.items);
    }
};

// ── JSON Entry (for serialization) ───────────────────────────────────────────

const JsonEntry = struct {
    task_id: []const u8,
    task_type: []const u8,
    tools_used: []const u8,
    outcome: TaskOutcome,
    quality_score: f32,
    error_message: []const u8,
    timestamp: u64,
    user_rating: ?u8,
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "FeedbackStore init/deinit" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();
    try std.testing.expect(fs.entries.items.len == 0);
}

test "FeedbackStore record and getSuccessRate" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const tools_success = &[_][]const u8{"read", "edit"};
    const tools_failure = &[_][]const u8{"bash"};

    try fs.record("edit", tools_success, .success, 0.0, "");
    try fs.record("edit", tools_failure, .failure, 0.0, "file not found");
    try fs.record("edit", tools_success, .success, 0.0, "");

    const rate = fs.getSuccessRate("edit");
    try std.testing.expect(rate > 0.6); // 2/3
    try std.testing.expect(rate < 0.7);

    // Missing type returns 0.0
    try std.testing.expect(fs.getSuccessRate("nonexistent") == 0.0);
}

test "FeedbackStore record computes quality score" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const tools = &[_][]const u8{"read"};
    try fs.record("edit", tools, .success, 0.0, "");
    try std.testing.expect(fs.entries.items[0].quality_score >= 0.8);
    try std.testing.expect(fs.entries.items[0].quality_score <= 1.0);

    try fs.record("fix", &[_][]const u8{}, .partial, 0.0, "");
    try std.testing.expect(fs.entries.items[1].quality_score == 0.5);

    try fs.record("deploy", &[_][]const u8{}, .failure, 0.0, "timeout");
    try std.testing.expect(fs.entries.items[2].quality_score >= 0.0);
    try std.testing.expect(fs.entries.items[2].quality_score <= 0.3);
}

test "FeedbackStore load/save roundtrip" {
    const allocator = std.testing.allocator;

    // Use /tmp path for test
    const tmp_path = "/tmp/crushcode_test_feedback.json";
    std.fs.cwd().deleteFile(tmp_path) catch {};

    var fs = FeedbackStore{
        .allocator = allocator,
        .entries = array_list_compat.ArrayList(FeedbackEntry).init(allocator),
        .file_path = try allocator.dupe(u8, tmp_path),
        .max_entries = 1000,
    };
    defer {
        for (fs.entries.items) |*e| {
            allocator.free(e.task_id);
            allocator.free(e.task_type);
            allocator.free(e.tools_used);
            allocator.free(e.error_message);
        }
        fs.entries.deinit();
        allocator.free(fs.file_path);
    }

    const tools = &[_][]const u8{"read", "edit"};
    try fs.record("edit", tools, .success, 0.9, "");
    try fs.save();

    // Load into fresh store
    var fs2 = FeedbackStore{
        .allocator = allocator,
        .entries = array_list_compat.ArrayList(FeedbackEntry).init(allocator),
        .file_path = try allocator.dupe(u8, tmp_path),
        .max_entries = 1000,
    };
    defer {
        for (fs2.entries.items) |*e| {
            allocator.free(e.task_id);
            allocator.free(e.task_type);
            allocator.free(e.tools_used);
            allocator.free(e.error_message);
        }
        fs2.entries.deinit();
        allocator.free(fs2.file_path);
    }

    try fs2.load();
    try std.testing.expectEqual(@as(usize, 1), fs2.entries.items.len);
    try std.testing.expect(fs2.entries.items[0].quality_score == 0.9);
    try std.testing.expectEqualStrings("edit", fs2.entries.items[0].task_type);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "FeedbackStore rateTask" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const tools = &[_][]const u8{"edit"};
    try fs.record("edit", tools, .success, 0.8, "");

    const task_id = fs.entries.items[0].task_id;
    try fs.rateTask(task_id, 4);
    try std.testing.expect(fs.entries.items[0].user_rating == 4);
    try std.testing.expect(fs.entries.items[0].quality_score == 4.0 / 5.0);

    // Invalid rating
    try std.testing.expectError(error.InvalidRating, fs.rateTask(task_id, 0));
    try std.testing.expectError(error.InvalidRating, fs.rateTask(task_id, 6));

    // Nonexistent task
    try std.testing.expectError(error.TaskNotFound, fs.rateTask("nonexistent", 3));
}

test "FeedbackStore getRecommendedTools returns ordered results" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    // Add multiple entries for "edit" type with different tool combos
    const combo_a = &[_][]const u8{"read", "edit"};
    const combo_b = &[_][]const u8{"bash"};

    try fs.record("edit", combo_a, .success, 0.9, "");
    try fs.record("edit", combo_a, .success, 0.9, "");
    try fs.record("edit", combo_b, .failure, 0.2, "failed");

    const recommended = try fs.getRecommendedTools("edit");
    defer allocator.free(recommended);
    try std.testing.expect(recommended.len > 0);
    // First should be the higher-success combo
    try std.testing.expect(std.mem.containsAtLeast(u8, recommended[0], 1, "read"));
}

test "FeedbackStore toPromptSection with data" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const tools = &[_][]const u8{"read", "edit"};
    try fs.record("edit", tools, .success, 0.85, "");
    try fs.record("refactor", tools, .success, 0.78, "");

    const section = try fs.toPromptSection();
    try std.testing.expect(section != null);
    defer allocator.free(section.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, section.?, 1, "edit"));
    try std.testing.expect(std.mem.containsAtLeast(u8, section.?, 1, "refactor"));
}

test "FeedbackStore toPromptSection empty store returns null" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const result = try fs.toPromptSection();
    try std.testing.expect(result == null);
}

test "FeedbackStore formatStats" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    const tools = &[_][]const u8{"bash"};
    try fs.record("build", tools, .success, 0.9, "");
    try fs.record("build", tools, .failure, 0.2, "compile error");

    const stats = try fs.formatStats();
    defer allocator.free(stats);
    try std.testing.expect(std.mem.containsAtLeast(u8, stats, 1, "Total tasks"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stats, 1, "build"));
}

test "FeedbackStore formatRecent" {
    const allocator = std.testing.allocator;
    var fs = try FeedbackStore.init(allocator);
    defer fs.deinit();

    // Empty store
    const empty = try fs.formatRecent(10);
    defer allocator.free(empty);
    try std.testing.expect(std.mem.containsAtLeast(u8, empty, 1, "No feedback"));

    const tools = &[_][]const u8{"edit"};
    try fs.record("edit", tools, .success, 0.9, "");

    const recent = try fs.formatRecent(10);
    defer allocator.free(recent);
    try std.testing.expect(std.mem.containsAtLeast(u8, recent, 1, "Recent"));
}

test "FeedbackStore max_entries trimming" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/crushcode_test_feedback_trim.json";
    std.fs.cwd().deleteFile(tmp_path) catch {};

    var fs = FeedbackStore{
        .allocator = allocator,
        .entries = array_list_compat.ArrayList(FeedbackEntry).init(allocator),
        .file_path = try allocator.dupe(u8, tmp_path),
        .max_entries = 3,
    };
    defer {
        for (fs.entries.items) |*e| {
            allocator.free(e.task_id);
            allocator.free(e.task_type);
            allocator.free(e.tools_used);
            allocator.free(e.error_message);
        }
        fs.entries.deinit();
        allocator.free(fs.file_path);
    }

    const tools = &[_][]const u8{"edit"};
    try fs.record("edit", tools, .success, 0.9, "");
    try fs.record("edit", tools, .success, 0.8, "");
    try fs.record("edit", tools, .success, 0.7, "");
    try fs.record("edit", tools, .success, 0.6, "");

    try std.testing.expectEqual(@as(usize, 3), fs.entries.items.len);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}
