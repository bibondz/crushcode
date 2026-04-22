const std = @import("std");
const json = std.json;
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;
const tool_classifier = @import("tool_classifier.zig");

/// Granular risk tier used by the auto-classifier for finer-grained decisions.
pub const RiskTier = enum {
    low,
    medium,
    high,
    critical,

    pub fn fromString(str: []const u8) ?RiskTier {
        return std.meta.stringToEnum(RiskTier, str);
    }

    pub fn toString(self: RiskTier) []const u8 {
        return @tagName(self);
    }
};

/// Records the approval history for a tool+pattern pair.
pub const PatternRecord = struct {
    tool_name: []const u8,
    pattern: []const u8,
    approved_count: u32,
    denied_count: u32,
    last_seen: i64,

    pub fn deinit(self: *PatternRecord, allocator: Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.pattern);
    }

    /// Approval rate as a value in [0, 1].
    pub fn approvalRate(self: PatternRecord) f32 {
        const total: f32 = @as(f32, @floatFromInt(self.approved_count + self.denied_count));
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.approved_count)) / total;
    }
};

/// A single entry in the tool-usage transcript (sliding window).
pub const TranscriptEntry = struct {
    tool_name: []const u8,
    arguments_summary: []const u8,
    was_approved: bool,
    timestamp: i64,

    pub fn deinit(self: *TranscriptEntry, allocator: Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.arguments_summary);
    }
};

const PatternList = array_list_compat.ArrayList(PatternRecord);
const TranscriptList = array_list_compat.ArrayList(TranscriptEntry);

/// Maximum number of transcript entries kept in the sliding window.
const MAX_TRANSCRIPT_SIZE: usize = 100;

/// Default approval threshold — patterns must be approved ≥90 % of the time
/// AND seen at least 3 times to qualify for auto-approval.
const DEFAULT_APPROVAL_THRESHOLD: f32 = 0.9;
const DEFAULT_MIN_OCCURRENCES: u32 = 3;

/// Auto-approve classifier that analyses recent tool-usage patterns to
/// determine whether the current operation is safe to auto-approve.
pub const AutoClassifier = struct {
    allocator: Allocator,
    patterns: PatternList,
    recent_transcript: TranscriptList,
    approval_threshold: f32,
    min_occurrences: u32,
    initialized: bool,

    pub fn init(allocator: Allocator) AutoClassifier {
        return AutoClassifier{
            .allocator = allocator,
            .patterns = PatternList.init(allocator),
            .recent_transcript = TranscriptList.init(allocator),
            .approval_threshold = DEFAULT_APPROVAL_THRESHOLD,
            .min_occurrences = DEFAULT_MIN_OCCURRENCES,
            .initialized = true,
        };
    }

    pub fn deinit(self: *AutoClassifier) void {
        for (self.patterns.items) |*rec| rec.deinit(self.allocator);
        self.patterns.deinit();
        for (self.recent_transcript.items) |*entry| entry.deinit(self.allocator);
        self.recent_transcript.deinit();
        self.initialized = false;
    }

    // ------------------------------------------------------------------
    // Transcript recording
    // ------------------------------------------------------------------

    /// Append a transcript entry to the sliding window.
    /// Trims the oldest entry when the window exceeds `MAX_TRANSCRIPT_SIZE`.
    pub fn recordTranscript(self: *AutoClassifier, entry: TranscriptEntry) !void {
        // Evict oldest entries when the window is full.
        while (self.recent_transcript.items.len >= MAX_TRANSCRIPT_SIZE) {
            var old = self.recent_transcript.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.recent_transcript.append(entry);
    }

    // ------------------------------------------------------------------
    // Pattern recalculation
    // ------------------------------------------------------------------

    /// Recalculate pattern approval rates from the current transcript window.
    /// Existing patterns are cleared and rebuilt.
    pub fn updatePatterns(self: *AutoClassifier) void {
        // Clear existing patterns.
        for (self.patterns.items) |*rec| rec.deinit(self.allocator);
        self.patterns.clearRetainingCapacity();

        // Accumulate counts per (tool_name, pattern_prefix).
        for (self.recent_transcript.items) |entry| {
            const prefix = extractPatternPrefix(entry.tool_name, entry.arguments_summary);

            // Find or create a matching pattern record.
            var found: ?usize = null;
            for (self.patterns.items, 0..) |*rec, i| {
                if (std.mem.eql(u8, rec.tool_name, entry.tool_name) and
                    std.mem.eql(u8, rec.pattern, prefix))
                {
                    found = i;
                    break;
                }
            }

            if (found) |idx| {
                var rec = &self.patterns.items[idx];
                if (entry.was_approved) {
                    rec.approved_count += 1;
                } else {
                    rec.denied_count += 1;
                }
                rec.last_seen = entry.timestamp;
            } else {
                const tool_copy = self.allocator.dupe(u8, entry.tool_name) catch continue;
                errdefer self.allocator.free(tool_copy);
                const prefix_copy = self.allocator.dupe(u8, prefix) catch {
                    self.allocator.free(tool_copy);
                    continue;
                };
                const rec = PatternRecord{
                    .tool_name = tool_copy,
                    .pattern = prefix_copy,
                    .approved_count = if (entry.was_approved) 1 else 0,
                    .denied_count = if (!entry.was_approved) 1 else 0,
                    .last_seen = entry.timestamp,
                };
                self.patterns.append(rec) catch {
                    self.allocator.free(tool_copy);
                    self.allocator.free(prefix_copy);
                    continue;
                };
            }
        }
    }

    // ------------------------------------------------------------------
    // Auto-approval decision
    // ------------------------------------------------------------------

    /// Decide whether the given tool invocation should be auto-approved.
    pub fn shouldAutoApprove(self: *AutoClassifier, tool_name: []const u8, arguments: []const u8) bool {
        // Read-only tools are always safe.
        if (isSafeReadTool(tool_name)) return true;

        // For everything else, check the pattern history.
        const prefix = extractPatternPrefix(tool_name, arguments);

        var total_count: u32 = 0;
        var approved: u32 = 0;
        for (self.patterns.items) |rec| {
            if (std.mem.eql(u8, rec.tool_name, tool_name) and
                std.mem.eql(u8, rec.pattern, prefix))
            {
                total_count = rec.approved_count + rec.denied_count;
                approved = rec.approved_count;
                break;
            }
        }

        if (total_count < self.min_occurrences) return false;

        const rate: f32 = @as(f32, @floatFromInt(approved)) / @as(f32, @floatFromInt(total_count));
        return rate >= self.approval_threshold;
    }

    // ------------------------------------------------------------------
    // Safe read-only tool whitelist
    // ------------------------------------------------------------------

    /// Returns true for tools that never modify state and can always be
    /// auto-approved regardless of transcript history.
    pub fn isSafeReadTool(tool_name: []const u8) bool {
        const safe_tools = [_][]const u8{
            "read_file",
            "glob",
            "grep",
            "search_files",
            "list_directory",
            "file_info",
            "git_status",
            "git_diff",
            "git_log",
            "web_fetch",
            "web_search",
            "image_display",
            "todo_write",
            "question",
        };

        for (safe_tools) |name| {
            if (std.mem.eql(u8, tool_name, name)) return true;
        }

        // LSP tools are all read-only.
        if (std.mem.startsWith(u8, tool_name, "lsp_")) return true;

        return false;
    }

    // ------------------------------------------------------------------
    // Risk classification
    // ------------------------------------------------------------------

    /// Classify the risk tier of a tool invocation.
    pub fn classifyRisk(self: *AutoClassifier, tool_name: []const u8, arguments: []const u8) RiskTier {
        _ = self;

        // Low: read-only tools — always safe.
        if (isSafeReadTool(tool_name)) return .low;

        // Shell commands need individual classification.
        if (std.mem.eql(u8, tool_name, "shell")) {
            return tool_classifier.classifyShellCommand(arguments);
        }

        // File writes to previously-approved paths → medium.
        const tier = tool_classifier.classifyTool(tool_name);
        if (tier == .write) return .medium;

        // Destructive tools (delete_file, etc.) → high.
        if (tier == .destructive) return .high;

        // Unknown tools default to high (conservative).
        return .high;
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    /// Load pattern records from a JSON file.
    pub fn loadPatterns(self: *AutoClassifier, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        const parsed = try json.parseFromSlice(json.Value, self.allocator, contents, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        // Clear existing patterns.
        for (self.patterns.items) |*rec| rec.deinit(self.allocator);
        self.patterns.clearRetainingCapacity();

        if (root.object.get("patterns")) |patterns_val| {
            if (patterns_val != .array) return error.InvalidFormat;
            for (patterns_val.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;

                const tool_name_val = obj.get("tool_name") orelse continue;
                if (tool_name_val != .string) continue;

                const pattern_val = obj.get("pattern") orelse continue;
                if (pattern_val != .string) continue;

                const approved_count: u32 = blk: {
                    if (obj.get("approved_count")) |v| {
                        if (v == .integer) break :blk @intCast(v.integer);
                    }
                    break :blk 0;
                };
                const denied_count: u32 = blk: {
                    if (obj.get("denied_count")) |v| {
                        if (v == .integer) break :blk @intCast(v.integer);
                    }
                    break :blk 0;
                };
                const last_seen: i64 = blk: {
                    if (obj.get("last_seen")) |v| {
                        if (v == .integer) break :blk v.integer;
                    }
                    break :blk 0;
                };

                const rec = PatternRecord{
                    .tool_name = try self.allocator.dupe(u8, tool_name_val.string),
                    .pattern = try self.allocator.dupe(u8, pattern_val.string),
                    .approved_count = approved_count,
                    .denied_count = denied_count,
                    .last_seen = last_seen,
                };
                try self.patterns.append(rec);
            }
        }
    }

    /// Persist pattern records to a JSON file.
    pub fn savePatterns(self: *AutoClassifier, path: []const u8) !void {
        // Ensure parent directory exists.
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        var patterns_array = json.Array.init(self.allocator);
        defer patterns_array.deinit();

        for (self.patterns.items) |rec| {
            var obj = json.ObjectMap.init(self.allocator);
            defer obj.deinit();

            try obj.put("tool_name", .{ .string = rec.tool_name });
            try obj.put("pattern", .{ .string = rec.pattern });
            try obj.put("approved_count", .{ .integer = @intCast(rec.approved_count) });
            try obj.put("denied_count", .{ .integer = @intCast(rec.denied_count) });
            try obj.put("last_seen", .{ .integer = rec.last_seen });

            try patterns_array.append(.{ .object = obj });
        }

        var root_obj = json.ObjectMap.init(self.allocator);
        defer root_obj.deinit();
        try root_obj.put("patterns", .{ .array = patterns_array });

        const root_value = json.Value{ .object = root_obj };

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var writer = file.writer(&write_buffer);
        try std.json.stringify(root_value, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.flush();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// Extract a representative prefix from the arguments for pattern matching.
    /// For file paths, uses the directory prefix; for commands, uses the first
    /// whitespace-delimited token(s).
    fn extractPatternPrefix(tool_name: []const u8, arguments: []const u8) []const u8 {
        _ = tool_name;

        // Take up to 64 chars or the first newline, whichever comes first.
        const end = @min(arguments.len, 64);
        var slice = arguments[0..end];
        if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| {
            slice = arguments[0..nl];
        }

        // For file-like arguments, strip the filename and keep the directory.
        if (std.mem.lastIndexOfScalar(u8, slice, '/')) |sep| {
            if (sep > 0) return arguments[0..sep];
        }

        return slice;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AutoClassifier init/deinit" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();
    try std.testing.expect(classifier.initialized);
}

test "isSafeReadTool identifies read-only tools" {
    try std.testing.expect(AutoClassifier.isSafeReadTool("read_file") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("glob") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("grep") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("lsp_diagnostics") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("web_fetch") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("todo_write") == true);
    try std.testing.expect(AutoClassifier.isSafeReadTool("shell") == false);
    try std.testing.expect(AutoClassifier.isSafeReadTool("write_file") == false);
    try std.testing.expect(AutoClassifier.isSafeReadTool("delete_file") == false);
}

test "shouldAutoApprove always approves safe read tools" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    try std.testing.expect(classifier.shouldAutoApprove("read_file", "/tmp/test.txt") == true);
    try std.testing.expect(classifier.shouldAutoApprove("glob", "**/*.zig") == true);
    try std.testing.expect(classifier.shouldAutoApprove("grep", "pattern") == true);
}

test "shouldAutoApprove requires minimum occurrences for write tools" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    // No history — should not auto-approve write tools.
    try std.testing.expect(classifier.shouldAutoApprove("write_file", "/tmp/test.txt") == false);
    try std.testing.expect(classifier.shouldAutoApprove("shell", "ls") == false);
}

test "shouldAutoApprove approves after sufficient history" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    const tool = "write_file";
    const args = "/tmp/test.txt";

    // Record 3 approved invocations.
    for (0..3) |_| {
        const entry = TranscriptEntry{
            .tool_name = try allocator.dupe(u8, tool),
            .arguments_summary = try allocator.dupe(u8, args),
            .was_approved = true,
            .timestamp = std.time.timestamp(),
        };
        try classifier.recordTranscript(entry);
    }
    classifier.updatePatterns();

    // Now should auto-approve.
    try std.testing.expect(classifier.shouldAutoApprove(tool, args) == true);
}

test "shouldAutoApprove denies if approval rate is too low" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    const tool = "write_file";
    const args = "/tmp/secret.txt";

    // 2 approved, 2 denied → 50 % rate, below 90 % threshold.
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const entry = TranscriptEntry{
            .tool_name = try allocator.dupe(u8, tool),
            .arguments_summary = try allocator.dupe(u8, args),
            .was_approved = true,
            .timestamp = std.time.timestamp(),
        };
        try classifier.recordTranscript(entry);
    }
    i = 0;
    while (i < 2) : (i += 1) {
        const entry = TranscriptEntry{
            .tool_name = try allocator.dupe(u8, tool),
            .arguments_summary = try allocator.dupe(u8, args),
            .was_approved = false,
            .timestamp = std.time.timestamp(),
        };
        try classifier.recordTranscript(entry);
    }
    classifier.updatePatterns();

    try std.testing.expect(classifier.shouldAutoApprove(tool, args) == false);
}

test "classifyRisk returns correct tiers" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    try std.testing.expect(classifier.classifyRisk("read_file", "") == .low);
    try std.testing.expect(classifier.classifyRisk("glob", "**/*.zig") == .low);
    try std.testing.expect(classifier.classifyRisk("write_file", "/tmp/test.txt") == .medium);
    try std.testing.expect(classifier.classifyRisk("delete_file", "/tmp/test.txt") == .high);
    try std.testing.expect(classifier.classifyRisk("shell", "ls") == .low);
    try std.testing.expect(classifier.classifyRisk("shell", "rm -rf /") == .critical);
    try std.testing.expect(classifier.classifyRisk("unknown_tool", "") == .high);
}

test "transcript sliding window limits entries" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const tool = try std.fmt.allocPrint(allocator, "tool_{d}", .{i});
        defer allocator.free(tool);
        const entry = TranscriptEntry{
            .tool_name = try allocator.dupe(u8, tool),
            .arguments_summary = try allocator.dupe(u8, ""),
            .was_approved = true,
            .timestamp = std.time.timestamp(),
        };
        try classifier.recordTranscript(entry);
    }

    try std.testing.expect(classifier.recent_transcript.items.len == 100);
}

test "savePatterns and loadPatterns roundtrip" {
    const allocator = std.testing.allocator;
    var classifier = AutoClassifier.init(allocator);
    defer classifier.deinit();

    // Add some patterns manually.
    const rec = PatternRecord{
        .tool_name = try allocator.dupe(u8, "write_file"),
        .pattern = try allocator.dupe(u8, "/tmp"),
        .approved_count = 5,
        .denied_count = 1,
        .last_seen = 1000,
    };
    try classifier.patterns.append(rec);

    // Save.
    const tmp_path = "/tmp/crushcode_test_patterns.json";
    try classifier.savePatterns(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Load into a fresh classifier.
    var classifier2 = AutoClassifier.init(allocator);
    defer classifier2.deinit();
    try classifier2.loadPatterns(tmp_path);

    try std.testing.expect(classifier2.patterns.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, classifier2.patterns.items[0].tool_name, "write_file"));
    try std.testing.expect(classifier2.patterns.items[0].approved_count == 5);
    try std.testing.expect(classifier2.patterns.items[0].denied_count == 1);
}

test "RiskTier fromString/toString roundtrip" {
    try std.testing.expect(RiskTier.fromString("low").? == .low);
    try std.testing.expect(RiskTier.fromString("medium").? == .medium);
    try std.testing.expect(RiskTier.fromString("high").? == .high);
    try std.testing.expect(RiskTier.fromString("critical").? == .critical);
    try std.testing.expect(RiskTier.fromString("unknown") == null);

    try std.testing.expect(std.mem.eql(u8, RiskTier.low.toString(), "low"));
    try std.testing.expect(std.mem.eql(u8, RiskTier.critical.toString(), "critical"));
}
