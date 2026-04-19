/// LayeredMemory — 4-layer memory architecture for AI coding assistant.
///
/// Layers (different lifetimes and persistence strategies):
///   session  — current conversation context (ephemeral, cleared on exit)
///   working  — project-specific state (persists across sessions within project)
///   insights — long-term pattern recognition with confidence scoring (permanent)
///   project  — per-project context tracking (persistent, project-scoped)
///
/// Reference: Firstbrain research #48
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// ── Enums ──────────────────────────────────────────────────────────────────────

pub const MemoryLayer = enum {
    session,
    working,
    insights,
    project,
};

// ── DistillationTrigger ────────────────────────────────────────────────────────

pub const DistillationTrigger = struct {
    min_changes: u32 = 10,
    min_related: u32 = 3,
    min_confidence: f64 = 0.5,
};

// ── MemoryStats ────────────────────────────────────────────────────────────────

pub const MemoryStats = struct {
    session_count: u32,
    working_count: u32,
    insights_count: u32,
    project_count: u32,
    total: u32,
    avg_confidence: f64,
    low_confidence_count: u32,
};

// ── MemoryEntry ────────────────────────────────────────────────────────────────

pub const MemoryEntry = struct {
    allocator: Allocator,
    id: []const u8,
    layer: MemoryLayer,
    key: []const u8,
    value: []const u8,
    confidence: f64,
    created_at: i64,
    updated_at: i64,
    access_count: u32,
    source: []const u8,
    tags: array_list_compat.ArrayList([]const u8),

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        layer: MemoryLayer,
        key: []const u8,
        value: []const u8,
        source: []const u8,
        tags: []const []const u8,
    ) !MemoryEntry {
        const now = std.time.timestamp();
        var tag_list = array_list_compat.ArrayList([]const u8).init(allocator);
        errdefer tag_list.deinit();
        for (tags) |t| {
            try tag_list.append(try allocator.dupe(u8, t));
        }
        return MemoryEntry{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .layer = layer,
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .confidence = 0.5,
            .created_at = now,
            .updated_at = now,
            .access_count = 0,
            .source = try allocator.dupe(u8, source),
            .tags = tag_list,
        };
    }

    pub fn deinit(self: *MemoryEntry) void {
        self.allocator.free(self.id);
        self.allocator.free(self.key);
        self.allocator.free(self.value);
        self.allocator.free(self.source);
        for (self.tags.items) |t| self.allocator.free(t);
        self.tags.deinit();
    }

    /// Update the confidence score, clamping to [0.0, 1.0].
    pub fn updateConfidence(self: *MemoryEntry, delta: f64) void {
        self.confidence += delta;
        if (self.confidence < 0.0) self.confidence = 0.0;
        if (self.confidence > 1.0) self.confidence = 1.0;
        self.updated_at = std.time.timestamp();
    }

    /// Increment access count and bump the updated_at timestamp.
    pub fn touch(self: *MemoryEntry) void {
        self.access_count += 1;
        self.updated_at = std.time.timestamp();
    }

    /// Check if this entry has a specific tag.
    pub fn hasTag(self: *const MemoryEntry, tag: []const u8) bool {
        for (self.tags.items) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
        return false;
    }
};

// ── LayeredMemory ──────────────────────────────────────────────────────────────

pub const LayeredMemory = struct {
    allocator: Allocator,
    session_entries: array_list_compat.ArrayList(*MemoryEntry),
    working_entries: array_list_compat.ArrayList(*MemoryEntry),
    insights_entries: array_list_compat.ArrayList(*MemoryEntry),
    project_entries: array_list_compat.ArrayList(*MemoryEntry),
    change_count: u32,
    distill_config: DistillationTrigger,
    project_dir: []const u8,
    next_id: u32,

    pub fn init(allocator: Allocator, project_dir: []const u8) !LayeredMemory {
        return LayeredMemory{
            .allocator = allocator,
            .session_entries = array_list_compat.ArrayList(*MemoryEntry).init(allocator),
            .working_entries = array_list_compat.ArrayList(*MemoryEntry).init(allocator),
            .insights_entries = array_list_compat.ArrayList(*MemoryEntry).init(allocator),
            .project_entries = array_list_compat.ArrayList(*MemoryEntry).init(allocator),
            .change_count = 0,
            .distill_config = .{},
            .project_dir = try allocator.dupe(u8, project_dir),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *LayeredMemory) void {
        self.clearLayer(.session);
        self.clearLayer(.working);
        self.clearLayer(.insights);
        self.clearLayer(.project);
        self.session_entries.deinit();
        self.working_entries.deinit();
        self.insights_entries.deinit();
        self.project_entries.deinit();
        self.allocator.free(self.project_dir);
    }

    fn entriesForLayer(self: *LayeredMemory, layer: MemoryLayer) *array_list_compat.ArrayList(*MemoryEntry) {
        return switch (layer) {
            .session => &self.session_entries,
            .working => &self.working_entries,
            .insights => &self.insights_entries,
            .project => &self.project_entries,
        };
    }

    /// Generate a unique ID for a new entry.
    fn nextEntryId(self: *LayeredMemory) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "mem-{d}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    /// Store a value in the specified layer with optional tags.
    pub fn store(
        self: *LayeredMemory,
        layer: MemoryLayer,
        key: []const u8,
        value: []const u8,
        source: []const u8,
        tags: []const []const u8,
    ) !*MemoryEntry {
        const id = try self.nextEntryId();
        errdefer self.allocator.free(id);

        const entry = try self.allocator.create(MemoryEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = try MemoryEntry.init(self.allocator, id, layer, key, value, source, tags);
        self.allocator.free(id); // MemoryEntry made its own copy

        try self.entriesForLayer(layer).append(entry);
        self.change_count += 1;
        return entry;
    }

    /// Retrieve an entry by key from a specific layer.
    pub fn retrieve(self: *LayeredMemory, layer: MemoryLayer, key: []const u8) ?*MemoryEntry {
        const list = self.entriesForLayer(layer);
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    /// Search across all layers by substring match in key or value.
    /// Caller owns the returned slice.
    pub fn search(self: *LayeredMemory, query: []const u8) ![]*MemoryEntry {
        var results = array_list_compat.ArrayList(*MemoryEntry).init(self.allocator);
        errdefer results.deinit();

        const all_layers = [_]MemoryLayer{ .session, .working, .insights, .project };
        for (&all_layers) |layer| {
            const list = self.entriesForLayer(layer);
            for (list.items) |entry| {
                if (std.mem.indexOf(u8, entry.key, query) != null or
                    std.mem.indexOf(u8, entry.value, query) != null)
                {
                    try results.append(entry);
                }
            }
        }
        return results.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Find all entries with a specific tag across all layers.
    /// Caller owns the returned slice.
    pub fn getByTag(self: *LayeredMemory, tag: []const u8) ![]*MemoryEntry {
        var results = array_list_compat.ArrayList(*MemoryEntry).init(self.allocator);
        errdefer results.deinit();

        const all_layers = [_]MemoryLayer{ .session, .working, .insights, .project };
        for (&all_layers) |layer| {
            const list = self.entriesForLayer(layer);
            for (list.items) |entry| {
                if (entry.hasTag(tag)) {
                    try results.append(entry);
                }
            }
        }
        return results.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Find an entry by ID across all layers.
    fn findById(self: *LayeredMemory, entry_id: []const u8) ?struct { *MemoryEntry, MemoryLayer } {
        const all_layers = [_]MemoryLayer{ .session, .working, .insights, .project };
        for (&all_layers) |layer| {
            const list = self.entriesForLayer(layer);
            for (list.items) |entry| {
                if (std.mem.eql(u8, entry.id, entry_id)) {
                    return .{ entry, layer };
                }
            }
        }
        return null;
    }

    /// Promote an entry from working → insights layer. Requires confidence >= 0.5.
    pub fn promote(self: *LayeredMemory, entry_id: []const u8) !void {
        const found = self.findById(entry_id) orelse return error.EntryNotFound;
        const entry = found[0];
        const current_layer = found[1];

        if (current_layer != .working) return error.InvalidLayerForPromotion;
        if (entry.confidence < self.distill_config.min_confidence) return error.InsufficientConfidence;

        // Remove from working list
        const working = &self.working_entries;
        for (working.items, 0..) |e, i| {
            if (e == entry) {
                _ = working.orderedRemove(i);
                break;
            }
        }

        // Update layer tag and add to insights
        entry.layer = .insights;
        try self.insights_entries.append(entry);
    }

    /// Demote an entry from insights → working layer (confidence decay).
    pub fn demote(self: *LayeredMemory, entry_id: []const u8) !void {
        const found = self.findById(entry_id) orelse return error.EntryNotFound;
        const entry = found[0];
        const current_layer = found[1];

        if (current_layer != .insights) return error.InvalidLayerForDemotion;

        // Remove from insights list
        const insights = &self.insights_entries;
        for (insights.items, 0..) |e, i| {
            if (e == entry) {
                _ = insights.orderedRemove(i);
                break;
            }
        }

        // Update layer tag and add to working
        entry.layer = .working;
        try self.working_entries.append(entry);
    }

    /// Update the confidence score of an entry by a delta value.
    pub fn updateConfidence(self: *LayeredMemory, entry_id: []const u8, delta: f64) !void {
        const found = self.findById(entry_id) orelse return error.EntryNotFound;
        found[0].updateConfidence(delta);
    }

    /// Touch an entry — increment access count and update timestamp.
    pub fn touch(self: *LayeredMemory, entry_id: []const u8) !void {
        const found = self.findById(entry_id) orelse return error.EntryNotFound;
        found[0].touch();
    }

    /// Auto-distillation: find related working entries, consolidate into insights.
    /// Groups working entries with >= min_related shared tags.
    /// Returns the count of insights created.
    pub fn distill(self: *LayeredMemory) !usize {
        var insights_created: usize = 0;

        // Only auto-distill if enough changes accumulated
        if (self.change_count < self.distill_config.min_changes) {
            // Still allow manual distillation by proceeding even with fewer changes
            // but return 0 if there's nothing to distill
            if (self.working_entries.items.len < self.distill_config.min_related) return 0;
        }

        // Build tag-to-entries map for working entries
        var tag_groups = std.StringHashMap(*array_list_compat.ArrayList(usize)).init(self.allocator);
        defer {
            var iter = tag_groups.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            tag_groups.deinit();
        }

        for (self.working_entries.items, 0..) |entry, idx| {
            for (entry.tags.items) |tag| {
                const owned_tag = try self.allocator.dupe(u8, tag);
                errdefer self.allocator.free(owned_tag);

                const gop = try tag_groups.getOrPut(owned_tag);
                if (!gop.found_existing) {
                    const list = try self.allocator.create(array_list_compat.ArrayList(usize));
                    list.* = array_list_compat.ArrayList(usize).init(self.allocator);
                    gop.value_ptr.* = list;
                } else {
                    self.allocator.free(owned_tag);
                }
                try gop.value_ptr.*.append(idx);
            }
        }

        // Find tags with >= min_related entries
        var grouped_indices = std.AutoHashMap(usize, void).init(self.allocator);
        defer grouped_indices.deinit();

        var tag_iter = tag_groups.iterator();
        while (tag_iter.next()) |entry| {
            if (entry.value_ptr.*.items.len >= self.distill_config.min_related) {
                for (entry.value_ptr.*.items) |idx| {
                    try grouped_indices.put(idx, {});
                }
            }
        }

        if (grouped_indices.count() == 0) return 0;

        // Collect all related entries
        var related = array_list_compat.ArrayList(*MemoryEntry).init(self.allocator);
        defer related.deinit();

        var gi = grouped_indices.iterator();
        while (gi.next()) |entry| {
            if (entry.key_ptr.* < self.working_entries.items.len) {
                try related.append(self.working_entries.items[entry.key_ptr.*]);
            }
        }

        if (related.items.len < self.distill_config.min_related) return 0;

        // Build a summary insight from the related entries
        var value_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer value_buf.deinit();
        const writer = value_buf.writer();
        writer.print("Distilled from {d} related entries: ", .{related.items.len}) catch {};
        for (related.items, 0..) |entry, i| {
            if (i > 0) writer.print("; ", .{}) catch {};
            writer.print("{s}={s}", .{ entry.key, entry.value }) catch {};
        }

        // Collect union of tags
        var all_tags = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer all_tags.deinit();
        for (related.items) |entry| {
            for (entry.tags.items) |t| {
                var already = false;
                for (all_tags.items) |at| {
                    if (std.mem.eql(u8, at, t)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try all_tags.append(t);
            }
        }

        // Compute avg confidence
        var avg_conf: f64 = 0.0;
        for (related.items) |e| avg_conf += e.confidence;
        avg_conf /= @as(f64, @floatFromInt(related.items.len));
        if (avg_conf > 1.0) avg_conf = 1.0;
        if (avg_conf < 0.3) avg_conf = 0.3;

        // Create the insight entry
        const insight = try self.store(
            .insights,
            "distilled-insight",
            value_buf.items,
            "distillation",
            all_tags.items,
        );
        insight.confidence = avg_conf;
        insights_created += 1;

        self.change_count = 0;
        return insights_created;
    }

    /// Clear all entries in a specific layer.
    pub fn clearLayer(self: *LayeredMemory, layer: MemoryLayer) void {
        const list = self.entriesForLayer(layer);
        for (list.items) |entry| {
            entry.deinit();
            self.allocator.destroy(entry);
        }
        list.clearRetainingCapacity();
    }

    /// Compute statistics across all layers.
    pub fn getStats(self: *LayeredMemory) MemoryStats {
        var stats = MemoryStats{
            .session_count = @intCast(self.session_entries.items.len),
            .working_count = @intCast(self.working_entries.items.len),
            .insights_count = @intCast(self.insights_entries.items.len),
            .project_count = @intCast(self.project_entries.items.len),
            .total = 0,
            .avg_confidence = 0.0,
            .low_confidence_count = 0,
        };
        stats.total = stats.session_count + stats.working_count + stats.insights_count + stats.project_count;

        var total_conf: f64 = 0.0;
        var conf_count: u32 = 0;

        const all_layers = [_]MemoryLayer{ .session, .working, .insights, .project };
        for (&all_layers) |layer| {
            const list = self.entriesForLayer(layer);
            for (list.items) |entry| {
                total_conf += entry.confidence;
                conf_count += 1;
                if (entry.confidence < 0.3) {
                    stats.low_confidence_count += 1;
                }
            }
        }

        if (conf_count > 0) {
            stats.avg_confidence = total_conf / @as(f64, @floatFromInt(conf_count));
        }

        return stats;
    }

    /// Persist working/insights/project layers to `.crushcode/memory/`.
    /// Session layer is not persisted (ephemeral).
    pub fn saveToDisk(self: *LayeredMemory) !void {
        const mem_dir = try std.fs.path.join(self.allocator, &.{ self.project_dir, ".crushcode", "memory" });
        defer self.allocator.free(mem_dir);

        std.fs.cwd().makePath(mem_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Save working.txt
        try self.saveLayerToFile(.working, try std.fs.path.join(self.allocator, &.{ mem_dir, "working.txt" }));
        // Save insights.txt
        try self.saveLayerToFile(.insights, try std.fs.path.join(self.allocator, &.{ mem_dir, "insights.txt" }));
        // Save project.txt
        try self.saveLayerToFile(.project, try std.fs.path.join(self.allocator, &.{ mem_dir, "project.txt" }));
    }

    fn saveLayerToFile(self: *LayeredMemory, layer: MemoryLayer, file_path: []const u8) !void {
        defer self.allocator.free(file_path);
        const list = self.entriesForLayer(layer);
        if (list.items.len == 0) return;

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        for (list.items, 0..) |entry, i| {
            if (i > 0) try writer.writeByte('\n');
            // Escape || in value by replacing with |
            try writer.print("{s}||", .{entry.key});
            try self.writeEscaped(writer, entry.value);
            if (layer == .insights) {
                try writer.print("||{d:.4}", .{entry.confidence});
            }
            try writer.print("||{s}||", .{entry.source});
            for (entry.tags.items, 0..) |tag, ti| {
                if (ti > 0) try writer.writeByte(',');
                try writer.print("{s}", .{tag});
            }
        }

        const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(buf.items);
    }

    fn writeEscaped(self: *LayeredMemory, writer: anytype, value: []const u8) !void {
        _ = self;
        // Replace || sequences with single | to preserve format
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            if (value[i] == '|' and i + 1 < value.len and value[i + 1] == '|') {
                try writer.writeByte('|');
                i += 1;
            } else if (value[i] == '\n') {
                try writer.writeAll("\\n");
            } else if (value[i] == '\r') {
                try writer.writeAll("\\r");
            } else {
                try writer.writeByte(value[i]);
            }
        }
    }

    /// Load persisted memory entries from `.crushcode/memory/`.
    pub fn loadFromDisk(self: *LayeredMemory) !void {
        const mem_dir = try std.fs.path.join(self.allocator, &.{ self.project_dir, ".crushcode", "memory" });
        defer self.allocator.free(mem_dir);

        // Load working.txt
        self.loadLayerFromFile(.working, try std.fs.path.join(self.allocator, &.{ mem_dir, "working.txt" })) catch {};
        // Load insights.txt
        self.loadLayerFromFile(.insights, try std.fs.path.join(self.allocator, &.{ mem_dir, "insights.txt" })) catch {};
        // Load project.txt
        self.loadLayerFromFile(.project, try std.fs.path.join(self.allocator, &.{ mem_dir, "project.txt" })) catch {};
    }

    fn loadLayerFromFile(self: *LayeredMemory, layer: MemoryLayer, file_path: []const u8) !void {
        defer self.allocator.free(file_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            self.parseEntryLine(layer, line) catch continue;
        }
    }

    fn parseEntryLine(self: *LayeredMemory, layer: MemoryLayer, line: []const u8) !void {
        // Format: key||value||source||tags (working/project)
        // Format: key||value||confidence||source||tags (insights)
        const parts = try self.splitOnDelimiter(line, "||");

        switch (layer) {
            .insights => {
                if (parts.len < 4) return;
                const key = parts[0];
                const value = parts[1];
                const confidence = std.fmt.parseFloat(f64, parts[2]) catch 0.5;
                const source = if (parts.len > 3) parts[3] else "unknown";
                const tags_str = if (parts.len > 4) parts[4] else "";

                var tags = array_list_compat.ArrayList([]const u8).init(self.allocator);
                defer tags.deinit();
                if (tags_str.len > 0) {
                    var titer = std.mem.splitScalar(u8, tags_str, ',');
                    while (titer.next()) |t| {
                        const trimmed = std.mem.trim(u8, t, " \t");
                        if (trimmed.len > 0) try tags.append(trimmed);
                    }
                }

                const entry = try self.store(layer, key, value, source, tags.items);
                entry.confidence = confidence;
            },
            else => {
                if (parts.len < 3) return;
                const key = parts[0];
                const value = parts[1];
                const source = parts[2];
                const tags_str = if (parts.len > 3) parts[3] else "";

                var tags = array_list_compat.ArrayList([]const u8).init(self.allocator);
                defer tags.deinit();
                if (tags_str.len > 0) {
                    var titer = std.mem.splitScalar(u8, tags_str, ',');
                    while (titer.next()) |t| {
                        const trimmed = std.mem.trim(u8, t, " \t");
                        if (trimmed.len > 0) try tags.append(trimmed);
                    }
                }

                _ = try self.store(layer, key, value, source, tags.items);
            },
        }
    }

    /// Split a string on a multi-char delimiter.
    /// Caller must free the returned slice and each element.
    fn splitOnDelimiter(self: *LayeredMemory, input: []const u8, delim: []const u8) ![][]const u8 {
        var parts = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer parts.deinit();

        var start: usize = 0;
        while (start < input.len) {
            if (std.mem.indexOf(u8, input[start..], delim)) |pos| {
                try parts.append(input[start .. start + pos]);
                start += pos + delim.len;
            } else {
                try parts.append(input[start..]);
                break;
            }
        }
        return parts.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Print all layers and their entries to stdout.
    pub fn printLayers(self: *LayeredMemory) void {
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Layered Memory ===\n", .{}) catch {};
        stdout.print("  Project dir: {s}\n", .{self.project_dir}) catch {};
        stdout.print("  Changes:     {d}\n\n", .{self.change_count}) catch {};

        const layer_names = [_]struct { MemoryLayer, []const u8 }{
            .{ .session, "Session (ephemeral)" },
            .{ .working, "Working (project-scoped)" },
            .{ .insights, "Insights (permanent)" },
            .{ .project, "Project (persistent)" },
        };

        for (&layer_names) |ln| {
            const list = self.entriesForLayer(ln[0]);
            stdout.print("--- {s} ({d} entries) ---\n", .{ ln[1], list.items.len }) catch {};
            for (list.items, 0..) |entry, idx| {
                stdout.print("  {d}. [{s}] {s} = {s}", .{
                    idx + 1,
                    entry.id,
                    entry.key,
                    entry.value,
                }) catch {};
                if (ln[0] == .insights) {
                    stdout.print(" (conf: {d:.2})", .{entry.confidence}) catch {};
                }
                if (entry.tags.items.len > 0) {
                    stdout.print(" [", .{}) catch {};
                    for (entry.tags.items, 0..) |t, ti| {
                        if (ti > 0) stdout.print(",", .{}) catch {};
                        stdout.print("{s}", .{t}) catch {};
                    }
                    stdout.print("]", .{}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }

        const stats = self.getStats();
        stdout.print("\n--- Stats ---\n", .{}) catch {};
        stdout.print("  Total: {d} | Avg confidence: {d:.2} | Low confidence: {d}\n", .{
            stats.total,
            stats.avg_confidence,
            stats.low_confidence_count,
        }) catch {};
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MemoryEntry - init and deinit" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{ "test", "unit" };
    var entry = try MemoryEntry.init(allocator, "mem-1", .session, "test_key", "test_value", "test", &tags);
    defer entry.deinit();

    try testing.expectEqualStrings("mem-1", entry.id);
    try testing.expectEqual(MemoryLayer.session, entry.layer);
    try testing.expectEqualStrings("test_key", entry.key);
    try testing.expectEqualStrings("test_value", entry.value);
    try testing.expectEqualStrings("test", entry.source);
    try testing.expectEqual(@as(usize, 2), entry.tags.items.len);
    try testing.expectEqualStrings("test", entry.tags.items[0]);
    try testing.expectEqualStrings("unit", entry.tags.items[1]);
}

test "MemoryEntry - updateConfidence clamps" {
    const allocator = std.testing.allocator;
    var entry = try MemoryEntry.init(allocator, "mem-1", .insights, "k", "v", "test", &.{});
    defer entry.deinit();

    try testing.expectEqual(@as(f64, 0.5), entry.confidence);

    entry.updateConfidence(0.8);
    try testing.expectEqual(@as(f64, 1.0), entry.confidence);

    entry.updateConfidence(-1.5);
    try testing.expectEqual(@as(f64, 0.0), entry.confidence);
}

test "MemoryEntry - touch increments access count" {
    const allocator = std.testing.allocator;
    var entry = try MemoryEntry.init(allocator, "mem-1", .session, "k", "v", "test", &.{});
    defer entry.deinit();

    try testing.expectEqual(@as(u32, 0), entry.access_count);
    entry.touch();
    try testing.expectEqual(@as(u32, 1), entry.access_count);
    entry.touch();
    try testing.expectEqual(@as(u32, 2), entry.access_count);
}

test "MemoryEntry - hasTag" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{ "alpha", "beta" };
    var entry = try MemoryEntry.init(allocator, "mem-1", .session, "k", "v", "test", &tags);
    defer entry.deinit();

    try testing.expect(entry.hasTag("alpha"));
    try testing.expect(entry.hasTag("beta"));
    try testing.expect(!entry.hasTag("gamma"));
}

test "LayeredMemory - store and retrieve in each layer" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    _ = try lm.store(.session, "sess-key", "session val", "test", &.{});
    _ = try lm.store(.working, "work-key", "working val", "test", &.{"project"});
    _ = try lm.store(.insights, "ins-key", "insight val", "test", &.{"pattern"});
    _ = try lm.store(.project, "proj-key", "project val", "test", &.{});

    const s = lm.retrieve(.session, "sess-key");
    try testing.expect(s != null);
    try testing.expectEqualStrings("session val", s.?.value);
    try testing.expectEqual(MemoryLayer.session, s.?.layer);

    const w = lm.retrieve(.working, "work-key");
    try testing.expect(w != null);
    try testing.expectEqualStrings("working val", w.?.value);

    const i = lm.retrieve(.insights, "ins-key");
    try testing.expect(i != null);
    try testing.expectEqualStrings("insight val", i.?.value);

    const p = lm.retrieve(.project, "proj-key");
    try testing.expect(p != null);
    try testing.expectEqualStrings("project val", p.?.value);

    // Non-existent key
    try testing.expect(lm.retrieve(.session, "nope") == null);
}

test "LayeredMemory - search across layers" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    _ = try lm.store(.session, "user_pref_theme", "dark", "test", &.{});
    _ = try lm.store(.working, "project_lang", "Zig", "test", &.{});
    _ = try lm.store(.insights, "pattern_mvc", "uses MVC", "test", &.{});

    const results = try lm.search("theme");
    defer allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("dark", results[0].value);

    const results2 = try lm.search("Zig");
    defer allocator.free(results2);
    try testing.expectEqual(@as(usize, 1), results2.len);

    const results3 = try lm.search("nonexistent");
    defer allocator.free(results3);
    try testing.expectEqual(@as(usize, 0), results3.len);
}

test "LayeredMemory - getByTag" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    _ = try lm.store(.working, "k1", "v1", "test", &.{"rust"});
    _ = try lm.store(.session, "k2", "v2", "test", &.{"rust"});
    _ = try lm.store(.insights, "k3", "v3", "test", &.{"zig"});

    const rust_entries = try lm.getByTag("rust");
    defer allocator.free(rust_entries);
    try testing.expectEqual(@as(usize, 2), rust_entries.len);

    const zig_entries = try lm.getByTag("zig");
    defer allocator.free(zig_entries);
    try testing.expectEqual(@as(usize, 1), zig_entries.len);
}

test "LayeredMemory - promote from working to insights" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.working, "promote-key", "val", "test", &.{});
    entry.confidence = 0.8;

    try testing.expectEqual(@as(u32, 1), lm.working_entries.items.len);
    try testing.expectEqual(@as(u32, 0), lm.insights_entries.items.len);

    try lm.promote(entry.id);

    try testing.expectEqual(@as(u32, 0), lm.working_entries.items.len);
    try testing.expectEqual(@as(u32, 1), lm.insights_entries.items.len);
    try testing.expectEqual(MemoryLayer.insights, lm.insights_entries.items[0].layer);
}

test "LayeredMemory - promote rejects low confidence" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.working, "low-conf", "val", "test", &.{});
    entry.confidence = 0.3;

    try testing.expectError(error.InsufficientConfidence, lm.promote(entry.id));
}

test "LayeredMemory - promote rejects non-working layer" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.session, "sess-key", "val", "test", &.{});
    entry.confidence = 0.9;

    try testing.expectError(error.InvalidLayerForPromotion, lm.promote(entry.id));
}

test "LayeredMemory - demote from insights to working" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.insights, "demote-key", "val", "test", &.{});
    entry.confidence = 0.9;

    try lm.demote(entry.id);

    try testing.expectEqual(@as(u32, 0), lm.insights_entries.items.len);
    try testing.expectEqual(@as(u32, 1), lm.working_entries.items.len);
    try testing.expectEqual(MemoryLayer.working, lm.working_entries.items[0].layer);
}

test "LayeredMemory - updateConfidence" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.working, "conf-key", "val", "test", &.{});
    try testing.expectEqual(@as(f64, 0.5), entry.confidence);

    try lm.updateConfidence(entry.id, 0.3);
    try testing.expectEqual(@as(f64, 0.8), entry.confidence);

    try testing.expectError(error.EntryNotFound, lm.updateConfidence("nonexistent", 0.1));
}

test "LayeredMemory - touch" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const entry = try lm.store(.session, "touch-key", "val", "test", &.{});
    try testing.expectEqual(@as(u32, 0), entry.access_count);

    try lm.touch(entry.id);
    try testing.expectEqual(@as(u32, 1), entry.access_count);

    try testing.expectError(error.EntryNotFound, lm.touch("nonexistent"));
}

test "LayeredMemory - distillation creates insights from related working entries" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    lm.distill_config.min_related = 3;
    lm.distill_config.min_changes = 1;

    // Add 3 working entries with shared tag "pattern"
    _ = try lm.store(.working, "p1", "val1", "conversation", &.{"pattern"});
    _ = try lm.store(.working, "p2", "val2", "conversation", &.{"pattern"});
    _ = try lm.store(.working, "p3", "val3", "conversation", &.{"pattern"});

    const count = try lm.distill();
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(u32, 1), lm.insights_entries.items.len);
    try testing.expectEqualStrings("distilled-insight", lm.insights_entries.items[0].key);
    try testing.expectEqualStrings("distillation", lm.insights_entries.items[0].source);
}

test "LayeredMemory - distillation returns 0 with too few related" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    lm.distill_config.min_related = 3;

    _ = try lm.store(.working, "p1", "v1", "test", &.{"pattern"});
    _ = try lm.store(.working, "p2", "v2", "test", &.{"pattern"});

    const count = try lm.distill();
    try testing.expectEqual(@as(usize, 0), count);
}

test "LayeredMemory - clearLayer" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    _ = try lm.store(.session, "s1", "v1", "test", &.{});
    _ = try lm.store(.session, "s2", "v2", "test", &.{});
    _ = try lm.store(.working, "w1", "v1", "test", &.{});

    try testing.expectEqual(@as(u32, 2), lm.session_entries.items.len);

    lm.clearLayer(.session);
    try testing.expectEqual(@as(u32, 0), lm.session_entries.items.len);

    // Working should be unaffected
    try testing.expectEqual(@as(u32, 1), lm.working_entries.items.len);
}

test "LayeredMemory - stats calculation" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    _ = try lm.store(.session, "s1", "v", "test", &.{});
    _ = try lm.store(.working, "w1", "v", "test", &.{});
    const ins = try lm.store(.insights, "i1", "v", "test", &.{});
    ins.confidence = 0.8;
    _ = try lm.store(.project, "p1", "v", "test", &.{});

    const stats = lm.getStats();
    try testing.expectEqual(@as(u32, 1), stats.session_count);
    try testing.expectEqual(@as(u32, 1), stats.working_count);
    try testing.expectEqual(@as(u32, 1), stats.insights_count);
    try testing.expectEqual(@as(u32, 1), stats.project_count);
    try testing.expectEqual(@as(u32, 4), stats.total);
    try testing.expect(stats.avg_confidence > 0.0);
}

test "LayeredMemory - stats with low confidence" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const e1 = try lm.store(.working, "k1", "v", "test", &.{});
    e1.confidence = 0.1;
    const e2 = try lm.store(.working, "k2", "v", "test", &.{});
    e2.confidence = 0.9;

    const stats = lm.getStats();
    try testing.expectEqual(@as(u32, 1), stats.low_confidence_count);
}

test "LayeredMemory - save/load round-trip" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/crushcode-layered-mem-test";

    // Clean up any previous test data
    std.fs.cwd().deleteTree(test_dir) catch {};

    // Create and populate
    {
        var lm = try LayeredMemory.init(allocator, test_dir);
        defer lm.deinit();

        _ = try lm.store(.working, "lang", "Zig", "manual", &.{"config"});
        _ = try lm.store(.working, "editor", "nvim", "manual", &.{"config"});

        const ins = try lm.store(.insights, "pattern-x", "Uses event loop", "distillation", &.{ "pattern", "architecture" });
        ins.confidence = 0.85;

        _ = try lm.store(.project, "project-name", "crushcode", "manual", &.{"meta"});

        try lm.saveToDisk();
    }

    // Load and verify
    {
        var lm = try LayeredMemory.init(allocator, test_dir);
        defer lm.deinit();

        try lm.loadFromDisk();

        const w = lm.retrieve(.working, "lang");
        try testing.expect(w != null);
        try testing.expectEqualStrings("Zig", w.?.value);

        const ins = lm.retrieve(.insights, "pattern-x");
        try testing.expect(ins != null);
        try testing.expectEqualStrings("Uses event loop", ins.?.value);
        // Confidence should be approximately preserved
        try testing.expect(@abs(ins.?.confidence - 0.85) < 0.01);

        const p = lm.retrieve(.project, "project-name");
        try testing.expect(p != null);
        try testing.expectEqualStrings("crushcode", p.?.value);

        // Session should be empty (not persisted)
        try testing.expectEqual(@as(u32, 0), lm.session_entries.items.len);
    }

    // Clean up
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "DistillationTrigger defaults" {
    const dt = DistillationTrigger{};
    try testing.expectEqual(@as(u32, 10), dt.min_changes);
    try testing.expectEqual(@as(u32, 3), dt.min_related);
    try testing.expectEqual(@as(f64, 0.5), dt.min_confidence);
}

test "MemoryLayer enum values" {
    try testing.expectEqual(MemoryLayer.session, @as(MemoryLayer, @enumFromInt(0)));
    try testing.expectEqual(MemoryLayer.working, @as(MemoryLayer, @enumFromInt(1)));
    try testing.expectEqual(MemoryLayer.insights, @as(MemoryLayer, @enumFromInt(2)));
    try testing.expectEqual(MemoryLayer.project, @as(MemoryLayer, @enumFromInt(3)));
}

test "MemoryStats zero state" {
    const allocator = std.testing.allocator;
    var lm = try LayeredMemory.init(allocator, "/tmp/test-crushcode");
    defer lm.deinit();

    const stats = lm.getStats();
    try testing.expectEqual(@as(u32, 0), stats.session_count);
    try testing.expectEqual(@as(u32, 0), stats.working_count);
    try testing.expectEqual(@as(u32, 0), stats.insights_count);
    try testing.expectEqual(@as(u32, 0), stats.project_count);
    try testing.expectEqual(@as(u32, 0), stats.total);
    try testing.expectEqual(@as(f64, 0.0), stats.avg_confidence);
    try testing.expectEqual(@as(u32, 0), stats.low_confidence_count);
}
