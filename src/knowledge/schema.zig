const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Source of a knowledge node
pub const KnowledgeSource = enum {
    file,
    graph,
    manual,
    ai_generated,
};

/// A single knowledge entry with metadata, tags, and citation tracking.
///
/// Reference: Second-brain knowledge node schema (F48)
pub const KnowledgeNode = struct {
    allocator: Allocator,
    id: []const u8,
    title: []const u8,
    content: []const u8,
    source_type: KnowledgeSource,
    source_path: ?[]const u8,
    tags: array_list_compat.ArrayList([]const u8),
    citations: array_list_compat.ArrayList([]const u8),
    confidence: f64,
    created_at: i64,
    updated_at: i64,
    access_count: u32,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        title: []const u8,
        content: []const u8,
        source_type: KnowledgeSource,
    ) !KnowledgeNode {
        const now = std.time.timestamp();
        return KnowledgeNode{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .content = try allocator.dupe(u8, content),
            .source_type = source_type,
            .source_path = null,
            .tags = array_list_compat.ArrayList([]const u8).init(allocator),
            .citations = array_list_compat.ArrayList([]const u8).init(allocator),
            .confidence = switch (source_type) {
                .file => 0.9,
                .manual => 1.0,
                .graph => 0.8,
                .ai_generated => 0.7,
            },
            .created_at = now,
            .updated_at = now,
            .access_count = 0,
        };
    }

    pub fn deinit(self: *KnowledgeNode) void {
        self.allocator.free(self.id);
        self.allocator.free(self.title);
        self.allocator.free(self.content);
        if (self.source_path) |p| self.allocator.free(p);
        for (self.tags.items) |t| self.allocator.free(t);
        self.tags.deinit();
        for (self.citations.items) |c| self.allocator.free(c);
        self.citations.deinit();
    }

    /// Add a tag to the node (duplicates the string)
    pub fn addTag(self: *KnowledgeNode, tag: []const u8) !void {
        try self.tags.append(try self.allocator.dupe(u8, tag));
    }

    /// Add a citation reference
    pub fn addCitation(self: *KnowledgeNode, citation: []const u8) !void {
        try self.citations.append(try self.allocator.dupe(u8, citation));
    }

    /// Record an access: increment count and update timestamp
    pub fn touch(self: *KnowledgeNode) void {
        self.access_count += 1;
        self.updated_at = std.time.timestamp();
    }

    /// Set the source path
    pub fn setSourcePath(self: *KnowledgeNode, path: []const u8) !void {
        if (self.source_path) |p| self.allocator.free(p);
        self.source_path = try self.allocator.dupe(u8, path);
    }
};

/// In-memory knowledge vault that stores nodes by ID.
/// The vault path is conceptual (raw/ + wiki/ directories) for future disk persistence.
///
/// Reference: Second-brain vault management (F48)
pub const KnowledgeVault = struct {
    allocator: Allocator,
    path: []const u8,
    nodes: std.StringHashMap(*KnowledgeNode),

    pub fn init(allocator: Allocator, path: []const u8) !KnowledgeVault {
        return KnowledgeVault{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .nodes = std.StringHashMap(*KnowledgeNode).init(allocator),
        };
    }

    pub fn deinit(self: *KnowledgeVault) void {
        // Collect node pointers before freeing the map
        var node_list = array_list_compat.ArrayList(*KnowledgeNode).init(self.allocator);
        defer node_list.deinit();
        {
            var iter = self.nodes.iterator();
            while (iter.next()) |entry| {
                node_list.append(entry.value_ptr.*) catch {};
            }
        }
        self.nodes.deinit();
        for (node_list.items) |node| {
            node.deinit();
            self.allocator.destroy(node);
        }
        self.allocator.free(self.path);
    }

    /// Add a node to the vault. Takes ownership of the node pointer.
    pub fn addNode(self: *KnowledgeVault, node: *KnowledgeNode) !void {
        try self.nodes.put(node.id, node);
    }

    /// Get a node by ID
    pub fn getNode(self: *KnowledgeVault, id: []const u8) ?*KnowledgeNode {
        return self.nodes.get(id);
    }

    /// Remove a node by ID and free it
    pub fn removeNode(self: *KnowledgeVault, id: []const u8) bool {
        const node = self.nodes.get(id) orelse return false;
        _ = self.nodes.remove(id);
        node.deinit();
        self.allocator.destroy(node);
        return true;
    }

    /// Return number of nodes in the vault
    pub fn count(self: *const KnowledgeVault) u32 {
        return @intCast(self.nodes.count());
    }

    /// Collect all unique tags across all nodes
    pub fn collectTags(self: *KnowledgeVault, allocator: Allocator) ![]const u8 {
        var tag_set = std.StringHashMap(void).init(allocator);
        defer {
            var iter = tag_set.iterator();
            while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
            tag_set.deinit();
        }

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            for (node.tags.items) |tag| {
                const gop = try tag_set.getOrPut(tag);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, tag);
                }
            }
        }

        var buf = array_list_compat.ArrayList(u8).init(allocator);
        defer buf.deinit();
        var tag_iter = tag_set.iterator();
        var first = true;
        while (tag_iter.next()) |entry| {
            if (!first) try buf.append(',');
            try buf.appendSlice(entry.key_ptr.*);
            first = false;
        }
        return buf.toOwnedSlice();
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "KnowledgeNode init/deinit" {
    var node = try KnowledgeNode.init(testing.allocator, "k1", "Test Node", "Some content", .file);
    defer node.deinit();
    try testing.expectEqualStrings("k1", node.id);
    try testing.expectEqualStrings("Test Node", node.title);
    try testing.expectEqual(KnowledgeSource.file, node.source_type);
    try testing.expect(node.confidence == 0.9);
    try testing.expectEqual(@as(u32, 0), node.access_count);
}

test "KnowledgeNode addTag and addCitation" {
    var node = try KnowledgeNode.init(testing.allocator, "k1", "T", "C", .manual);
    defer node.deinit();
    try node.addTag("zig");
    try node.addTag("systems");
    try node.addCitation("ref1");
    try testing.expectEqual(@as(usize, 2), node.tags.items.len);
    try testing.expectEqual(@as(usize, 1), node.citations.items.len);
    try testing.expectEqualStrings("zig", node.tags.items[0]);
    try testing.expectEqualStrings("ref1", node.citations.items[0]);
}

test "KnowledgeNode touch" {
    var node = try KnowledgeNode.init(testing.allocator, "k1", "T", "C", .file);
    defer node.deinit();
    const before = node.updated_at;
    node.touch();
    try testing.expect(node.updated_at >= before);
    try testing.expectEqual(@as(u32, 1), node.access_count);
}

test "KnowledgeNode confidence by source" {
    var n1 = try KnowledgeNode.init(testing.allocator, "k1", "T", "C", .file);
    defer n1.deinit();
    try testing.expect(n1.confidence == 0.9);

    var n2 = try KnowledgeNode.init(testing.allocator, "k2", "T", "C", .manual);
    defer n2.deinit();
    try testing.expect(n2.confidence == 1.0);

    var n3 = try KnowledgeNode.init(testing.allocator, "k3", "T", "C", .ai_generated);
    defer n3.deinit();
    try testing.expect(n3.confidence == 0.7);
}

test "KnowledgeVault init/deinit and basic operations" {
    var vault = try KnowledgeVault.init(testing.allocator, "/tmp/vault");
    defer vault.deinit();
    try testing.expectEqual(@as(u32, 0), vault.count());

    const node = try testing.allocator.create(KnowledgeNode);
    node.* = try KnowledgeNode.init(testing.allocator, "k1", "Title", "Content", .file);
    try vault.addNode(node);
    try testing.expectEqual(@as(u32, 1), vault.count());

    const retrieved = vault.getNode("k1");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Title", retrieved.?.title);

    const removed = vault.removeNode("k1");
    try testing.expect(removed);
    try testing.expectEqual(@as(u32, 0), vault.count());
    try testing.expect(vault.getNode("k1") == null);
}
