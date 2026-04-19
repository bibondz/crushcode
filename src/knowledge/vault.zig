const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");
const persistence_mod = @import("knowledge_persistence");

const Allocator = std.mem.Allocator;

/// Vault management — handles the raw/ + wiki/ conceptual separation
/// and index generation for a knowledge vault.
///
/// Reference: Second-brain vault management (F48)
pub const VaultManager = struct {
    allocator: Allocator,
    vault: *schema.KnowledgeVault,

    pub fn init(allocator: Allocator, vault: *schema.KnowledgeVault) VaultManager {
        return VaultManager{
            .allocator = allocator,
            .vault = vault,
        };
    }

    /// Generate a markdown index of all nodes in the vault
    pub fn generateIndex(self: *VaultManager) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("# Knowledge Vault Index\n\n", .{});
        try writer.print("Path: {s}\n", .{self.vault.path});
        try writer.print("Total nodes: {d}\n\n", .{self.vault.count()});

        // Group by source type
        var node_iter = self.vault.nodes.iterator();
        var entries = array_list_compat.ArrayList(*schema.KnowledgeNode).init(self.allocator);
        defer entries.deinit();
        while (node_iter.next()) |entry| {
            try entries.append(entry.value_ptr.*);
        }

        // Sort by title for consistent output
        std.sort.insertion(*schema.KnowledgeNode, entries.items, {}, cmpNodeByTitle);

        try writer.print("## Nodes\n\n", .{});
        for (entries.items) |node| {
            const source_label = @tagName(node.source_type);
            try writer.print("- **{s}** ({s}) confidence: {d:.2} accesses: {d}\n", .{
                node.title,
                source_label,
                node.confidence,
                node.access_count,
            });
            if (node.tags.items.len > 0) {
                try writer.print("  tags: ", .{});
                for (node.tags.items, 0..) |tag, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{tag});
                }
                try writer.print("\n", .{});
            }
        }

        return buf.toOwnedSlice();
    }

    /// Get vault statistics
    pub fn getStats(self: *VaultManager) VaultStats {
        var stats = VaultStats{};
        stats.total_nodes = self.vault.count();

        var iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;
            switch (node.source_type) {
                .file => stats.file_nodes += 1,
                .graph => stats.graph_nodes += 1,
                .manual => stats.manual_nodes += 1,
                .ai_generated => stats.ai_nodes += 1,
            }
            stats.total_confidence += node.confidence;
            if (node.confidence < 0.3) stats.low_confidence_nodes += 1;
            stats.total_tags += @intCast(node.tags.items.len);
            stats.total_citations += @intCast(node.citations.items.len);
            stats.total_accesses += node.access_count;
        }

        if (stats.total_nodes > 0) {
            stats.avg_confidence = stats.total_confidence / @as(f64, @floatFromInt(stats.total_nodes));
        }

        return stats;
    }

    /// Save the vault to disk at the given directory path
    pub fn saveToFile(self: *VaultManager, dir_path: []const u8) !void {
        var pers = persistence_mod.VaultPersistence.init(self.allocator, dir_path);
        try pers.saveVault(self.vault);
    }

    /// Load nodes from disk into the vault
    pub fn loadFromFile(self: *VaultManager, dir_path: []const u8) !persistence_mod.LoadResult {
        var pers = persistence_mod.VaultPersistence.init(self.allocator, dir_path);
        return pers.loadVault(self.vault);
    }

    fn cmpNodeByTitle(_: void, a: *schema.KnowledgeNode, b: *schema.KnowledgeNode) bool {
        return std.mem.lessThan(u8, a.title, b.title);
    }
};

pub const VaultStats = struct {
    total_nodes: u32 = 0,
    file_nodes: u32 = 0,
    graph_nodes: u32 = 0,
    manual_nodes: u32 = 0,
    ai_nodes: u32 = 0,
    total_tags: u32 = 0,
    total_citations: u32 = 0,
    total_accesses: u32 = 0,
    total_confidence: f64 = 0.0,
    avg_confidence: f64 = 0.0,
    low_confidence_nodes: u32 = 0,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "VaultManager generateIndex" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Alpha Node", "content a", .file);
    try n1.addTag("test");
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "k2", "Beta Node", "content b", .manual);
    try vault.addNode(n2);

    var mgr = VaultManager.init(testing.allocator, &vault);
    const idx = try mgr.generateIndex();
    defer testing.allocator.free(idx);

    try testing.expect(std.mem.indexOf(u8, idx, "Knowledge Vault Index") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "Alpha Node") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "Beta Node") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "Total nodes: 2") != null);
}

test "VaultManager getStats" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "T1", "C", .file);
    try n1.addTag("a");
    try n1.addTag("b");
    try vault.addNode(n1);

    var mgr = VaultManager.init(testing.allocator, &vault);
    const stats = mgr.getStats();
    try testing.expectEqual(@as(u32, 1), stats.total_nodes);
    try testing.expectEqual(@as(u32, 1), stats.file_nodes);
    try testing.expectEqual(@as(u32, 2), stats.total_tags);
    try testing.expect(stats.avg_confidence > 0.0);
}
