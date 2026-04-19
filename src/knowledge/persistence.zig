const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");

const Allocator = std.mem.Allocator;

/// Result of loading a vault from disk
pub const LoadResult = struct {
    nodes_loaded: u32 = 0,
    nodes_failed: u32 = 0,
    tags_found: u32 = 0,
};

/// File-based vault storage — persists KnowledgeVault to JSON files on disk.
///
/// Directory layout:
///   {vault_dir}/nodes/{id}.json   — one file per node
///   {vault_dir}/index.json        — vault metadata (node count, tags, timestamp)
///
/// Reference: Knowledge Vault Persistence (Phase 53)
pub const VaultPersistence = struct {
    allocator: Allocator,
    vault_dir: []const u8,

    pub fn init(allocator: Allocator, vault_dir: []const u8) VaultPersistence {
        return VaultPersistence{
            .allocator = allocator,
            .vault_dir = vault_dir,
        };
    }

    /// Save a single node to {vault_dir}/nodes/{id}.json
    pub fn saveNode(self: *VaultPersistence, node: *const schema.KnowledgeNode) !void {
        const nodes_dir = try std.fs.path.join(self.allocator, &.{ self.vault_dir, "nodes" });
        defer self.allocator.free(nodes_dir);
        try std.fs.cwd().makePath(nodes_dir);

        const json_str = try self.serializeNode(node);
        defer self.allocator.free(json_str);

        const file_path = try self.nodeFilePath(node.id);
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(json_str);
    }

    /// Load a single node from disk by ID. Returns null if file not found.
    pub fn loadNode(self: *VaultPersistence, id: []const u8) !?*schema.KnowledgeNode {
        const file_path = try self.nodeFilePath(id);
        defer self.allocator.free(file_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        const id_val = root.object.get("id") orelse return error.MissingField;
        if (id_val != .string) return error.InvalidType;

        const title_val = root.object.get("title") orelse return error.MissingField;
        if (title_val != .string) return error.InvalidType;

        const content_val = root.object.get("content") orelse return error.MissingField;
        if (content_val != .string) return error.InvalidType;

        const source_type_val = root.object.get("source_type") orelse return error.MissingField;
        if (source_type_val != .string) return error.InvalidType;

        const source_type: schema.KnowledgeSource = std.meta.stringToEnum(schema.KnowledgeSource, source_type_val.string) orelse return error.InvalidFormat;

        const node = try self.allocator.create(schema.KnowledgeNode);
        node.* = schema.KnowledgeNode.init(self.allocator, id_val.string, title_val.string, content_val.string, source_type) catch {
            self.allocator.destroy(node);
            return error.InitializationFailed;
        };

        // source_path
        if (root.object.get("source_path")) |sp_val| {
            if (sp_val == .string) {
                node.setSourcePath(sp_val.string) catch {};
            }
        }

        // confidence (may be stored as float or integer)
        if (root.object.get("confidence")) |conf_val| {
            switch (conf_val) {
                .float => |f| node.confidence = f,
                .integer => |i| node.confidence = @floatFromInt(i),
                else => {},
            }
        }

        // timestamps
        if (root.object.get("created_at")) |ca_val| {
            if (ca_val == .integer) node.created_at = ca_val.integer;
        }
        if (root.object.get("updated_at")) |ua_val| {
            if (ua_val == .integer) node.updated_at = ua_val.integer;
        }

        // access_count
        if (root.object.get("access_count")) |ac_val| {
            if (ac_val == .integer) {
                node.access_count = @intCast(ac_val.integer);
            }
        }

        // tags
        if (root.object.get("tags")) |tags_val| {
            if (tags_val == .array) {
                for (tags_val.array.items) |tag_val| {
                    if (tag_val == .string) {
                        node.addTag(tag_val.string) catch {};
                    }
                }
            }
        }

        // citations
        if (root.object.get("citations")) |cit_val| {
            if (cit_val == .array) {
                for (cit_val.array.items) |c_val| {
                    if (c_val == .string) {
                        node.addCitation(c_val.string) catch {};
                    }
                }
            }
        }

        return node;
    }

    /// Save all nodes + generate index.json
    pub fn saveVault(self: *VaultPersistence, vault: *schema.KnowledgeVault) !void {
        const nodes_dir = try std.fs.path.join(self.allocator, &.{ self.vault_dir, "nodes" });
        defer self.allocator.free(nodes_dir);
        try std.fs.cwd().makePath(nodes_dir);

        // Save each node
        var iter = vault.nodes.iterator();
        while (iter.next()) |entry| {
            try self.saveNode(entry.value_ptr.*);
        }

        // Write index
        try self.writeIndex(vault);
    }

    /// Load all nodes from disk into the vault. Returns load statistics.
    pub fn loadVault(self: *VaultPersistence, vault: *schema.KnowledgeVault) !LoadResult {
        var result = LoadResult{};

        const nodes_dir = try std.fs.path.join(self.allocator, &.{ self.vault_dir, "nodes" });
        defer self.allocator.free(nodes_dir);

        var dir = std.fs.cwd().openDir(nodes_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer dir.close();

        var walker = dir.walk(self.allocator) catch return result;
        defer walker.deinit();

        var tag_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = tag_set.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            tag_set.deinit();
        }

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".json")) continue;

            // Extract node ID from filename (strip .json extension)
            if (entry.basename.len <= 5) continue;
            const id = entry.basename[0 .. entry.basename.len - 5];

            const node = self.loadNode(id) catch {
                result.nodes_failed += 1;
                continue;
            };

            if (node) |n| {
                // Collect tags before adding to vault (vault takes ownership)
                for (n.tags.items) |tag| {
                    const gop = tag_set.getOrPut(tag) catch continue;
                    if (!gop.found_existing) {
                        gop.key_ptr.* = self.allocator.dupe(u8, tag) catch continue;
                    }
                }

                vault.addNode(n) catch {
                    n.deinit();
                    self.allocator.destroy(n);
                    result.nodes_failed += 1;
                    continue;
                };
                result.nodes_loaded += 1;
            } else {
                result.nodes_failed += 1;
            }
        }

        result.tags_found = @intCast(tag_set.count());
        return result;
    }

    /// Returns the file path for a node JSON file
    pub fn nodeFilePath(self: *VaultPersistence, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/nodes/{s}.json", .{ self.vault_dir, id });
    }

    /// Returns the path to the index file
    pub fn indexFilePath(self: *VaultPersistence) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/index.json", .{self.vault_dir});
    }

    /// Check if the vault directory exists on disk
    pub fn vaultExists(self: *VaultPersistence) bool {
        std.fs.cwd().access(self.vault_dir, .{}) catch return false;
        return true;
    }

    // --- Private helpers ---

    /// Serialize a KnowledgeNode to a JSON string
    fn serializeNode(self: *VaultPersistence, node: *const schema.KnowledgeNode) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("{");
        try writer.writeAll("\"id\":\"");
        try writeJsonString(writer, node.id);
        try writer.writeAll("\",\"title\":\"");
        try writeJsonString(writer, node.title);
        try writer.writeAll("\",\"content\":\"");
        try writeJsonString(writer, node.content);
        try writer.writeAll("\",\"source_type\":\"");
        try writer.writeAll(@tagName(node.source_type));
        try writer.writeAll("\"");

        // source_path (nullable)
        if (node.source_path) |sp| {
            try writer.writeAll(",\"source_path\":\"");
            try writeJsonString(writer, sp);
            try writer.writeAll("\"");
        } else {
            try writer.writeAll(",\"source_path\":null");
        }

        // tags array
        try writer.writeAll(",\"tags\":[");
        for (node.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try writeJsonString(writer, tag);
            try writer.writeAll("\"");
        }
        try writer.writeAll("]");

        // citations array
        try writer.writeAll(",\"citations\":[");
        for (node.citations.items, 0..) |cit, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try writeJsonString(writer, cit);
            try writer.writeAll("\"");
        }
        try writer.writeAll("]");

        try writer.print(",\"confidence\":{d}", .{node.confidence});
        try writer.print(",\"created_at\":{d}", .{node.created_at});
        try writer.print(",\"updated_at\":{d}", .{node.updated_at});
        try writer.print(",\"access_count\":{d}", .{node.access_count});
        try writer.writeAll("}");

        return buf.toOwnedSlice();
    }

    /// Write the index.json file with vault metadata
    fn writeIndex(self: *VaultPersistence, vault: *schema.KnowledgeVault) !void {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("{\"version\":\"0.25.0\"");
        try writer.print(",\"node_count\":{d}", .{vault.count()});
        try writer.print(",\"saved_at\":{d}", .{std.time.timestamp()});

        // Collect unique tags directly from vault nodes
        try writer.writeAll(",\"tags\":[");
        var tag_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = tag_set.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            tag_set.deinit();
        }

        var node_iter = vault.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            for (node.tags.items) |tag| {
                const gop = try tag_set.getOrPut(tag);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.allocator.dupe(u8, tag);
                }
            }
        }

        var tag_iter = tag_set.iterator();
        var first = true;
        while (tag_iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"");
            try writeJsonString(writer, entry.key_ptr.*);
            try writer.writeAll("\"");
            first = false;
        }
        try writer.writeAll("]}");

        const json_str = try buf.toOwnedSlice();
        defer self.allocator.free(json_str);

        const index_path = try self.indexFilePath();
        defer self.allocator.free(index_path);

        const file = try std.fs.cwd().createFile(index_path, .{});
        defer file.close();
        try file.writeAll(json_str);
    }
};

/// Write a string with JSON escaping to a writer
fn writeJsonString(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:04}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "VaultPersistence saveNode creates JSON file" {
    const test_dir = "/tmp/crushcode-test-vault-save-node";
    std.fs.cwd().deleteTree(test_dir) catch {};

    var persistence = VaultPersistence.init(testing.allocator, test_dir);
    var node = try schema.KnowledgeNode.init(testing.allocator, "test-1", "Test Node", "Test content", .file);
    defer node.deinit();
    try node.addTag("test-tag");
    try node.addCitation("ref-1");

    try persistence.saveNode(&node);

    // Verify file exists and contains expected JSON fields
    const file_path = try persistence.nodeFilePath("test-1");
    defer testing.allocator.free(file_path);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, file_path, 1024 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"id\":\"test-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"title\":\"Test Node\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"source_type\":\"file\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"tags\":[\"test-tag\"]") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"citations\":[\"ref-1\"]") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"confidence\":") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"access_count\":0") != null);

    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "VaultPersistence loadNode reads JSON file back correctly" {
    const test_dir = "/tmp/crushcode-test-vault-load-node";
    std.fs.cwd().deleteTree(test_dir) catch {};

    var persistence = VaultPersistence.init(testing.allocator, test_dir);
    var node = try schema.KnowledgeNode.init(testing.allocator, "load-1", "Load Test", "Some content here", .manual);
    defer node.deinit();
    try node.addTag("zig");
    try node.addTag("systems");
    try node.addCitation("cite-a");
    try node.setSourcePath("/path/to/source.zig");
    node.access_count = 42;

    try persistence.saveNode(&node);

    const loaded = try persistence.loadNode("load-1");
    try testing.expect(loaded != null);
    defer {
        loaded.?.deinit();
        testing.allocator.destroy(loaded.?);
    }

    try testing.expectEqualStrings("load-1", loaded.?.id);
    try testing.expectEqualStrings("Load Test", loaded.?.title);
    try testing.expectEqualStrings("Some content here", loaded.?.content);
    try testing.expectEqual(schema.KnowledgeSource.manual, loaded.?.source_type);
    try testing.expect(loaded.?.source_path != null);
    try testing.expectEqualStrings("/path/to/source.zig", loaded.?.source_path.?);
    try testing.expectEqual(@as(usize, 2), loaded.?.tags.items.len);
    try testing.expectEqualStrings("zig", loaded.?.tags.items[0]);
    try testing.expectEqualStrings("systems", loaded.?.tags.items[1]);
    try testing.expectEqual(@as(usize, 1), loaded.?.citations.items.len);
    try testing.expectEqualStrings("cite-a", loaded.?.citations.items[0]);
    try testing.expectEqual(@as(u32, 42), loaded.?.access_count);
    // Manual source has confidence 1.0
    try testing.expect(loaded.?.confidence == 1.0);

    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "VaultPersistence saveVault + loadVault round-trip preserves all fields" {
    const test_dir = "/tmp/crushcode-test-vault-roundtrip";
    std.fs.cwd().deleteTree(test_dir) catch {};

    var persistence = VaultPersistence.init(testing.allocator, test_dir);

    // Create vault with nodes
    var vault = try schema.KnowledgeVault.init(testing.allocator, test_dir);
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "rt-1", "First Node", "Content 1", .file);
    try n1.addTag("alpha");
    try n1.addTag("shared");
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "rt-2", "Second Node", "Content 2", .graph);
    try n2.addTag("beta");
    try n2.addTag("shared");
    try n2.addCitation("rt-1");
    try n2.setSourcePath("/path/to/graph.zig");
    try vault.addNode(n2);

    // Save
    try persistence.saveVault(&vault);
    try testing.expect(persistence.vaultExists());

    // Verify index file
    const index_path = try persistence.indexFilePath();
    defer testing.allocator.free(index_path);
    const idx_content = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(idx_content);
    try testing.expect(std.mem.indexOf(u8, idx_content, "\"node_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, idx_content, "\"version\":\"0.25.0\"") != null);

    // Load into a new vault
    var vault2 = try schema.KnowledgeVault.init(testing.allocator, test_dir);
    defer vault2.deinit();

    var persistence2 = VaultPersistence.init(testing.allocator, test_dir);
    const result = try persistence2.loadVault(&vault2);

    try testing.expectEqual(@as(u32, 2), result.nodes_loaded);
    try testing.expectEqual(@as(u32, 0), result.nodes_failed);
    try testing.expectEqual(@as(u32, 2), vault2.count());
    // 3 unique tags: alpha, beta, shared
    try testing.expectEqual(@as(u32, 3), result.tags_found);

    const loaded1 = vault2.getNode("rt-1");
    try testing.expect(loaded1 != null);
    try testing.expectEqualStrings("First Node", loaded1.?.title);
    try testing.expectEqualStrings("Content 1", loaded1.?.content);
    try testing.expectEqual(schema.KnowledgeSource.file, loaded1.?.source_type);
    try testing.expectEqual(@as(usize, 2), loaded1.?.tags.items.len);
    try testing.expect(loaded1.?.confidence == 0.9);

    const loaded2 = vault2.getNode("rt-2");
    try testing.expect(loaded2 != null);
    try testing.expectEqualStrings("Second Node", loaded2.?.title);
    try testing.expectEqual(schema.KnowledgeSource.graph, loaded2.?.source_type);
    try testing.expect(loaded2.?.source_path != null);
    try testing.expectEqualStrings("/path/to/graph.zig", loaded2.?.source_path.?);
    try testing.expectEqual(@as(usize, 1), loaded2.?.citations.items.len);
    try testing.expectEqualStrings("rt-1", loaded2.?.citations.items[0]);

    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "VaultPersistence loadVault handles missing directory gracefully" {
    var persistence = VaultPersistence.init(testing.allocator, "/tmp/crushcode-nonexistent-vault-xyz-999");
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/tmp/test");
    defer vault.deinit();

    const result = try persistence.loadVault(&vault);
    try testing.expectEqual(@as(u32, 0), result.nodes_loaded);
    try testing.expectEqual(@as(u32, 0), result.nodes_failed);
    try testing.expectEqual(@as(u32, 0), result.tags_found);
    try testing.expectEqual(@as(u32, 0), vault.count());
}

test "VaultPersistence vaultExists detection" {
    const test_dir = "/tmp/crushcode-test-vault-exists";
    std.fs.cwd().deleteTree(test_dir) catch {};

    var persistence = VaultPersistence.init(testing.allocator, test_dir);
    try testing.expect(!persistence.vaultExists());

    // Create the directory
    try std.fs.cwd().makePath(test_dir);
    try testing.expect(persistence.vaultExists());

    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "VaultPersistence loadNode returns null for missing file" {
    const test_dir = "/tmp/crushcode-test-vault-missing";
    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    var persistence = VaultPersistence.init(testing.allocator, test_dir);
    const loaded = try persistence.loadNode("nonexistent-id");
    try testing.expect(loaded == null);

    std.fs.cwd().deleteTree(test_dir) catch {};
}
