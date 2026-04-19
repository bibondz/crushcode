const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");

const Allocator = std.mem.Allocator;

/// A single search result with relevance scoring
pub const QueryResult = struct {
    node_id: []const u8,
    title: []const u8,
    relevance: f64,
    snippet: []const u8,
    source: ?[]const u8,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.title);
        allocator.free(self.snippet);
        if (self.source) |s| allocator.free(s);
    }
};

/// Citation tracking result
pub const CitationResult = struct {
    node: *schema.KnowledgeNode,
    citing_nodes: array_list_compat.ArrayList(*schema.KnowledgeNode),

    pub fn deinit(self: *CitationResult) void {
        self.citing_nodes.deinit();
    }
};

/// Search and synthesize knowledge with citation tracking.
/// Pure text matching — no LLM calls.
///
/// Reference: Second-brain query patterns (F48)
pub const KnowledgeQuerier = struct {
    allocator: Allocator,
    vault: *schema.KnowledgeVault,

    pub fn init(allocator: Allocator, vault: *schema.KnowledgeVault) KnowledgeQuerier {
        return KnowledgeQuerier{
            .allocator = allocator,
            .vault = vault,
        };
    }

    /// Search the knowledge base for matching nodes
    pub fn query(self: *KnowledgeQuerier, search_text: []const u8, max_results: u32) ![]QueryResult {
        // Tokenize search text into words (>2 chars)
        var search_words = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer search_words.deinit();
        var word_iter = std.mem.splitScalar(u8, search_text, ' ');
        while (word_iter.next()) |word| {
            if (word.len > 2) {
                const lower = try toLower(self.allocator, word);
                try search_words.append(lower);
            }
        }

        if (search_words.items.len == 0) return &.{};

        // Score each node
        var scored = array_list_compat.ArrayList(struct { *schema.KnowledgeNode, f64 }).init(self.allocator);
        defer scored.deinit();

        var node_iter = self.vault.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            var total_score: f64 = 0.0;

            const title_lower = try toLower(self.allocator, node.title);
            defer self.allocator.free(title_lower);

            for (search_words.items) |qword| {
                // Title match (weight 3.0)
                if (std.mem.indexOf(u8, title_lower, qword)) |_| {
                    total_score += 3.0;
                }

                // Tag match (weight 2.5)
                for (node.tags.items) |tag| {
                    const tag_lower = try toLower(self.allocator, tag);
                    defer self.allocator.free(tag_lower);
                    if (std.mem.indexOf(u8, tag_lower, qword)) |_| {
                        total_score += 2.5;
                    }
                }

                // Content match (weight 1.0)
                const content_lower = try toLower(self.allocator, node.content);
                defer self.allocator.free(content_lower);
                if (std.mem.indexOf(u8, content_lower, qword)) |_| {
                    total_score += 1.0;
                }

                // Citation match (weight 0.5)
                for (node.citations.items) |citation| {
                    const cit_lower = try toLower(self.allocator, citation);
                    defer self.allocator.free(cit_lower);
                    if (std.mem.indexOf(u8, cit_lower, qword)) |_| {
                        total_score += 0.5;
                    }
                }
            }

            if (total_score > 0.0) {
                try scored.append(.{ node, total_score });
            }
        }

        // Sort by relevance descending
        std.sort.insertion(@TypeOf(scored.items[0]), scored.items, {}, cmpScoredDesc);

        // Build results
        const limit = @min(max_results, @as(u32, @intCast(scored.items.len)));
        const results = try self.allocator.alloc(QueryResult, limit);
        for (results, 0..limit) |*r, i| {
            const node = scored.items[i][0];
            const score = scored.items[i][1];
            r.* = QueryResult{
                .node_id = try self.allocator.dupe(u8, node.id),
                .title = try self.allocator.dupe(u8, node.title),
                .relevance = score,
                .snippet = try self.generateSnippet(node.content, search_words.items),
                .source = if (node.source_path) |p| try self.allocator.dupe(u8, p) else null,
            };
            // Touch the node to record access
            node.touch();
        }

        // Free the search word copies
        for (search_words.items) |w| self.allocator.free(w);

        return results;
    }

    /// Query nodes by tag
    pub fn queryByTag(self: *KnowledgeQuerier, tag: []const u8) ![]*schema.KnowledgeNode {
        var results = array_list_compat.ArrayList(*schema.KnowledgeNode).init(self.allocator);
        defer results.deinit();

        var iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;
            for (node.tags.items) |t| {
                if (std.mem.eql(u8, t, tag)) {
                    try results.append(node);
                    break;
                }
            }
        }

        return results.toOwnedSlice();
    }

    /// Get a node with all nodes that cite it
    pub fn getNodeWithCitations(self: *KnowledgeQuerier, node_id: []const u8) !?CitationResult {
        const node = self.vault.getNode(node_id) orelse return null;

        var citing = array_list_compat.ArrayList(*schema.KnowledgeNode).init(self.allocator);

        // Find all nodes that reference this node's ID in their citations
        var iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            const other = entry.value_ptr.*;
            if (std.mem.eql(u8, other.id, node_id)) continue;
            for (other.citations.items) |cit| {
                if (std.mem.eql(u8, cit, node_id)) {
                    try citing.append(other);
                    break;
                }
            }
        }

        return CitationResult{
            .node = node,
            .citing_nodes = citing,
        };
    }

    // --- Private helpers ---

    /// Generate a snippet: first 200 chars around best matching position
    fn generateSnippet(self: *KnowledgeQuerier, content: []const u8, search_words: []const []const u8) ![]const u8 {
        if (content.len == 0) return try self.allocator.dupe(u8, "");

        const content_lower = try toLower(self.allocator, content);
        defer self.allocator.free(content_lower);

        // Find the best matching position
        var best_pos: usize = 0;
        var best_count: usize = 0;

        // Sliding window approach: check every 50-char offset
        var offset: usize = 0;
        while (offset < content.len) : (offset += 50) {
            var count: usize = 0;
            const end = @min(offset + 200, content.len);
            const window = content_lower[offset..end];
            for (search_words) |word| {
                if (std.mem.indexOf(u8, window, word)) |_| {
                    count += 1;
                }
            }
            if (count > best_count) {
                best_count = count;
                best_pos = offset;
            }
        }

        const snippet_start = best_pos;
        const snippet_end = @min(snippet_start + 200, content.len);
        const snippet = content[snippet_start..snippet_end];

        // Add ellipsis if truncated
        if (snippet_end < content.len) {
            return std.fmt.allocPrint(self.allocator, "{s}...", .{snippet});
        }
        return try self.allocator.dupe(u8, snippet);
    }

    fn cmpScoredDesc(_: void, a: @TypeOf(@as(struct { *schema.KnowledgeNode, f64 }, undefined)), b: @TypeOf(@as(struct { *schema.KnowledgeNode, f64 }, undefined))) bool {
        return a[1] > b[1];
    }

    fn toLower(allocator: Allocator, text: []const u8) ![]const u8 {
        const result = try allocator.alloc(u8, text.len);
        for (text, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "KnowledgeQuerier query" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Zig Programming", "Zig is a systems programming language", .file);
    try n1.addTag("programming");
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "k2", "Rust Guide", "Rust is another systems language", .file);
    try n2.addTag("programming");
    try vault.addNode(n2);

    var querier = KnowledgeQuerier.init(testing.allocator, &vault);
    const results = try querier.query("zig programming", 10);
    defer {
        for (results) |*r| r.deinit(testing.allocator);
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
    // First result should be the Zig node (title match gives it higher score)
    try testing.expect(std.mem.indexOf(u8, results[0].title, "Zig") != null);
    try testing.expect(results[0].relevance > 0.0);
}

test "KnowledgeQuerier queryByTag" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "T1", "C", .file);
    try n1.addTag("zig");
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "k2", "T2", "C", .file);
    try n2.addTag("rust");
    try vault.addNode(n2);

    var querier = KnowledgeQuerier.init(testing.allocator, &vault);
    const results = try querier.queryByTag("zig");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("k1", results[0].id);
}

test "KnowledgeQuerier getNodeWithCitations" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();

    const n1 = try testing.allocator.create(schema.KnowledgeNode);
    n1.* = try schema.KnowledgeNode.init(testing.allocator, "k1", "Base", "Base content", .file);
    try vault.addNode(n1);

    const n2 = try testing.allocator.create(schema.KnowledgeNode);
    n2.* = try schema.KnowledgeNode.init(testing.allocator, "k2", "Derived", "Derived content", .file);
    try n2.addCitation("k1");
    try vault.addNode(n2);

    var querier = KnowledgeQuerier.init(testing.allocator, &vault);
    var result = try querier.getNodeWithCitations("k1");
    try testing.expect(result != null);
    defer result.?.deinit();
    try testing.expectEqualStrings("k1", result.?.node.id);
    try testing.expectEqual(@as(usize, 1), result.?.citing_nodes.items.len);
    try testing.expectEqualStrings("k2", result.?.citing_nodes.items[0].id);
}
