const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const parser = @import("parser.zig");
pub const algorithms = @import("algorithms.zig");

/// Codebase knowledge graph — represents code structure as a searchable graph
///
/// Reference: Graphify NetworkX graph building with confidence tags
/// Provides significant token compression (71.5x) vs raw source for AI context
pub const KnowledgeGraph = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(*types.GraphNode),
    edges: array_list_compat.ArrayList(*types.GraphEdge),
    communities: array_list_compat.ArrayList(*types.Community),
    file_count: u32,
    total_source_tokens: u64,
    pagerank_cache: ?algorithms.PageRankResult,

    pub fn init(allocator: Allocator) KnowledgeGraph {
        return KnowledgeGraph{
            .allocator = allocator,
            .nodes = std.StringHashMap(*types.GraphNode).init(allocator),
            .edges = array_list_compat.ArrayList(*types.GraphEdge).init(allocator),
            .communities = array_list_compat.ArrayList(*types.Community).init(allocator),
            .file_count = 0,
            .total_source_tokens = 0,
            .pagerank_cache = null,
        };
    }

    /// Add a node to the graph
    pub fn addNode(self: *KnowledgeGraph, node: *types.GraphNode) !void {
        try self.nodes.put(node.id, node);
        self.invalidatePageRankCache();
    }

    /// Add an edge between two nodes
    pub fn addEdge(self: *KnowledgeGraph, edge: *types.GraphEdge) !void {
        try self.edges.append(edge);
        self.invalidatePageRankCache();
    }

    /// Get a node by ID
    pub fn getNode(self: *KnowledgeGraph, id: []const u8) ?*types.GraphNode {
        return self.nodes.get(id);
    }

    /// Get all nodes of a specific type
    pub fn getNodesByType(self: *KnowledgeGraph, node_type: types.NodeType, allocator: Allocator) ![]*types.GraphNode {
        var result = array_list_compat.ArrayList(*types.GraphNode).init(allocator);
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.*.node_type == node_type) {
                try result.append(entry.value_ptr.*);
            }
        }
        return result.toOwnedSlice();
    }

    /// Get edges from a node
    pub fn getEdgesFrom(self: *KnowledgeGraph, node_id: []const u8, allocator: Allocator) ![]*types.GraphEdge {
        var result = array_list_compat.ArrayList(*types.GraphEdge).init(allocator);
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.source_id, node_id)) {
                try result.append(edge);
            }
        }
        return result.toOwnedSlice();
    }

    /// Get edges to a node
    pub fn getEdgesTo(self: *KnowledgeGraph, node_id: []const u8, allocator: Allocator) ![]*types.GraphEdge {
        var result = array_list_compat.ArrayList(*types.GraphEdge).init(allocator);
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.target_id, node_id)) {
                try result.append(edge);
            }
        }
        return result.toOwnedSlice();
    }

    /// Index a source file into the graph
    pub fn indexFile(self: *KnowledgeGraph, file_path: []const u8) !void {
        var src_parser = parser.SourceParser.init(self.allocator);
        const result_opt = src_parser.parseFile(file_path) catch return orelse return;
        var result = result_opt;
        defer result.deinit();
        self.file_count += 1;

        // Extract module name from file path
        const module_name = self.extractModuleName(file_path);
        const module_id_tmp = try std.fmt.allocPrint(self.allocator, "mod.{s}", .{module_name});

        // Add module node (GraphNode.init dupes the id, so free the tmp after)
        const mod_node = try self.allocator.create(types.GraphNode);
        mod_node.* = try types.GraphNode.init(self.allocator, module_id_tmp, module_name, .module, file_path, 1);
        try self.addNode(mod_node);
        self.allocator.free(module_id_tmp);

        // Process symbols
        for (result.symbols.items) |sym| {
            const node_id = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, sym.name });
            // node_id is now owned by the GraphNode and will be freed by deinit
            const node = try self.allocator.create(types.GraphNode);
            node.* = types.GraphNode{
                .id = node_id,
                .name = try self.allocator.dupe(u8, sym.name),
                .node_type = sym.symbol_type,
                .file_path = try self.allocator.dupe(u8, file_path),
                .line = sym.line,
                .end_line = sym.end_line,
                .signature = if (sym.signature) |s| try self.allocator.dupe(u8, s) else null,
                .doc_comment = if (sym.doc_comment) |d| try self.allocator.dupe(u8, d) else null,
                .token_count = sym.end_line - sym.line + 1,
                .allocator = self.allocator,
            };
            try self.addNode(node);

            // Add contains edge: module → symbol
            const edge = try self.allocator.create(types.GraphEdge);
            edge.* = try types.GraphEdge.init(self.allocator, mod_node.id, node.id, .contains, .extracted);
            try self.addEdge(edge);

            self.total_source_tokens += node.token_count;
        }

        // Process imports
        for (result.imports.items) |imp| {
            const edge = try self.allocator.create(types.GraphEdge);
            edge.* = try types.GraphEdge.init(self.allocator, mod_node.id, imp, .imports, .extracted);
            try self.addEdge(edge);
        }
    }

    /// Detect communities (clusters of related nodes) using simple connectivity analysis
    /// Reference: Graphify Leiden community detection
    pub fn detectCommunities(self: *KnowledgeGraph) !void {
        // Simple community detection: group by file path
        var file_groups = std.StringHashMap(array_list_compat.ArrayList([]const u8)).init(self.allocator);
        defer {
            var iter = file_groups.iterator();
            while (iter.next()) |entry| {
                for (entry.value_ptr.items) |id| self.allocator.free(id);
                entry.value_ptr.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            file_groups.deinit();
        }

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            const gop = try file_groups.getOrPut(node.file_path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, node.file_path);
                gop.value_ptr.* = array_list_compat.ArrayList([]const u8).init(self.allocator);
            }
            try gop.value_ptr.append(try self.allocator.dupe(u8, node.id));
        }

        var community_id: u32 = 0;
        var group_iter = file_groups.iterator();
        while (group_iter.next()) |entry| {
            if (entry.value_ptr.items.len < 2) continue;

            const community = try self.allocator.create(types.Community);
            const c_name = self.extractModuleName(entry.key_ptr.*);
            community.* = types.Community.init(self.allocator, community_id, c_name);
            community_id += 1;

            for (entry.value_ptr.items) |node_id| {
                try community.addNode(node_id);
            }

            // Calculate cohesion based on internal edges
            var internal_edges: u32 = 0;
            for (self.edges.items) |edge| {
                for (entry.value_ptr.items) |nid| {
                    if (std.mem.eql(u8, edge.source_id, nid)) {
                        for (entry.value_ptr.items) |nid2| {
                            if (std.mem.eql(u8, edge.target_id, nid2)) {
                                internal_edges += 1;
                            }
                        }
                    }
                }
            }
            const max_possible: f32 = @floatFromInt(entry.value_ptr.items.len * (entry.value_ptr.items.len - 1));
            community.cohesion = if (max_possible > 0) @as(f32, @floatFromInt(internal_edges)) / max_possible else 0.0;

            try self.communities.append(community);
        }
    }

    /// Generate a compressed representation of the graph for AI context
    /// Returns a string with significant token compression vs raw source
    pub fn toCompressedContext(self: *KnowledgeGraph, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("=== Codebase Knowledge Graph ===\n", .{});
        try writer.print("Files: {d} | Nodes: {d} | Edges: {d} | Communities: {d}\n\n", .{
            self.file_count,
            self.nodes.count(),
            self.edges.items.len,
            self.communities.items.len,
        });

        // Communities overview
        if (self.communities.items.len > 0) {
            try writer.print("## Architecture (Communities)\n", .{});
            for (self.communities.items) |community| {
                try writer.print("  [{d}] {s} ({d} symbols, cohesion: {d:.2})\n", .{
                    community.id,
                    community.name,
                    community.node_ids.items.len,
                    community.cohesion,
                });
            }
            try writer.print("\n", .{});
        }

        // Module-level view
        try writer.print("## Modules\n", .{});
        var mod_iter = self.nodes.iterator();
        while (mod_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.node_type != .module) continue;
            try writer.print("  {s} ({s})\n", .{ node.name, node.file_path });
        }

        // Symbol summary
        try writer.print("\n## Symbols\n", .{});
        var sym_iter = self.nodes.iterator();
        while (sym_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.node_type == .module) continue;
            const type_label = @tagName(node.node_type);
            try writer.print("  {s} [{s}] {s}:{d}", .{ node.id, type_label, node.file_path, node.line });
            if (node.doc_comment) |doc| {
                try writer.print(" — {s}", .{doc});
            }
            try writer.print("\n", .{});
        }

        return buf.toOwnedSlice();
    }

    /// Calculate token compression ratio
    pub fn compressionRatio(self: *KnowledgeGraph) f64 {
        if (self.total_source_tokens == 0) return 0.0;
        const graph_tokens: f64 = @floatFromInt(self.nodes.count() * 5 + self.edges.items.len * 3);
        const source_tokens: f64 = @floatFromInt(self.total_source_tokens);
        return source_tokens / graph_tokens;
    }

    /// Print graph statistics
    pub fn printStats(self: *KnowledgeGraph) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Knowledge Graph Statistics ===\n", .{}) catch {};
        stdout.print("  Files indexed: {d}\n", .{self.file_count}) catch {};
        stdout.print("  Nodes: {d}\n", .{self.nodes.count()}) catch {};
        stdout.print("  Edges: {d}\n", .{self.edges.items.len}) catch {};
        stdout.print("  Communities: {d}\n", .{self.communities.items.len}) catch {};

        // Count by type
        var type_counts = std.AutoHashMap(types.NodeType, u32).init(self.allocator);
        defer type_counts.deinit();
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const t = entry.value_ptr.*.node_type;
            const gop = type_counts.getOrPut(t) catch continue;
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        stdout.print("\n  By type:\n", .{}) catch {};
        var tc_iter = type_counts.iterator();
        while (tc_iter.next()) |entry| {
            stdout.print("    {s}: {d}\n", .{ @tagName(entry.key_ptr.*), entry.value_ptr.* }) catch {};
        }

        const ratio = self.compressionRatio();
        if (ratio > 0) {
            stdout.print("\n  Compression ratio: {d:.1}x\n", .{ratio}) catch {};
        }
    }

    /// Compute PageRank for all nodes using default parameters
    pub fn computePageRank(self: *KnowledgeGraph, allocator: Allocator) !algorithms.PageRankResult {
        return algorithms.computePageRank(.{ .nodes = &self.nodes, .edges = &self.edges }, allocator, 0.85, 30, 0.001);
    }

    /// Find bridge nodes (articulation points) whose removal would disconnect the graph
    pub fn findBridges(self: *KnowledgeGraph, allocator: Allocator) ![][]const u8 {
        return algorithms.findBridges(.{ .nodes = &self.nodes, .edges = &self.edges }, allocator);
    }

    /// Find nodes similar to a given node using Jaccard similarity on neighbor sets
    pub fn findSimilar(self: *KnowledgeGraph, allocator: Allocator, node_id: []const u8, max_results: u32) ![]types.SimilarityResult {
        var results = array_list_compat.ArrayList(types.SimilarityResult).init(allocator);
        defer results.deinit();

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const other_id = entry.key_ptr.*;
            if (std.mem.eql(u8, other_id, node_id)) continue;

            const sim = algorithms.computeJaccardSimilarity(.{ .nodes = &self.nodes, .edges = &self.edges }, node_id, other_id);
            if (sim > 0.0) {
                try results.append(.{
                    .node_id = other_id,
                    .similarity = sim,
                });
            }
        }

        // Sort by similarity descending
        std.sort.insertion(types.SimilarityResult, results.items, {}, cmpSimilarityDesc);

        const limit = @min(max_results, @as(u32, @intCast(results.items.len)));
        const result = try allocator.alloc(types.SimilarityResult, limit);
        for (result, 0..limit) |*r, i| {
            r.* = results.items[i];
        }
        return result;
    }

    /// Comparison for sorting SimilarityResult descending
    fn cmpSimilarityDesc(_: void, a: types.SimilarityResult, b: types.SimilarityResult) bool {
        return a.similarity > b.similarity;
    }

    /// Find path between two nodes using BFS
    pub fn findPaths(self: *KnowledgeGraph, allocator: Allocator, from_id: []const u8, to_id: []const u8, max_hops: u32) ![][]const u8 {
        return algorithms.findPaths(.{ .nodes = &self.nodes, .edges = &self.edges }, allocator, from_id, to_id, max_hops);
    }

    /// Cluster nodes by tags (file paths)
    pub fn clusterByTags(self: *KnowledgeGraph, allocator: Allocator) ![]algorithms.TagCluster {
        return algorithms.clusterByTags(.{ .nodes = &self.nodes, .edges = &self.edges }, allocator);
    }

    /// Invalidate cached PageRank results (call when graph structure changes)
    fn invalidatePageRankCache(self: *KnowledgeGraph) void {
        if (self.pagerank_cache) |*cache| {
            cache.deinit();
            self.pagerank_cache = null;
        }
    }

    /// Compute or return cached PageRank results
    fn ensurePageRankCache(self: *KnowledgeGraph, allocator: Allocator) !*const algorithms.PageRankResult {
        if (self.pagerank_cache == null) {
            self.pagerank_cache = try self.computePageRank(allocator);
        }
        return &self.pagerank_cache.?;
    }

    /// Determine file-type weight multiplier based on file extension
    /// Source files (.zig) are baseline 1.0x, config/docs are reduced
    fn fileTypeWeight(file_path: []const u8) f32 {
        // Find the last dot in the filename to extract extension
        const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
        const filename = if (last_slash > 0) file_path[last_slash + 1 ..] else file_path;
        const last_dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return 0.5;
        const ext = filename[last_dot..];

        if (std.mem.eql(u8, ext, ".zig")) return 1.0;
        if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return 0.7;
        if (std.mem.eql(u8, ext, ".zon") or std.mem.eql(u8, ext, ".json")) return 0.8;
        return 0.5;
    }

    /// Check if a node belongs to any community
    fn nodeInCommunity(self: *KnowledgeGraph, node_id: []const u8) bool {
        for (self.communities.items) |community| {
            for (community.node_ids.items) |cid| {
                if (std.mem.eql(u8, cid, node_id)) return true;
            }
        }
        return false;
    }

    /// Convert text to lowercase (manual impl for Zig 0.15 compat)
    fn toLower(allocator: Allocator, text: []const u8) ![]const u8 {
        const result = try allocator.alloc(u8, text.len);
        for (text, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    /// Score nodes by relevance to a query string
    /// Returns top max_results scored nodes sorted by descending relevance
    /// This is a thin wrapper around scoreRelevanceAdvanced with null PageRank
    pub fn scoreRelevance(
        self: *KnowledgeGraph,
        allocator: Allocator,
        query: []const u8,
        max_results: u32,
    ) ![]types.RelevanceScore {
        return self.scoreRelevanceAdvanced(allocator, query, max_results, null);
    }

    /// Advanced relevance scoring with PageRank centrality, file-type weighting,
    /// community bonus, and recency bias layered on top of keyword matching.
    /// Accepts optional pre-computed PageRank results to avoid recomputation.
    pub fn scoreRelevanceAdvanced(
        self: *KnowledgeGraph,
        allocator: Allocator,
        query: []const u8,
        max_results: u32,
        pagerank: ?algorithms.PageRankResult,
    ) ![]types.RelevanceScore {
        const query_lower = try toLower(allocator, query);
        defer allocator.free(query_lower);

        // Split query into words (>2 chars only)
        var query_words = array_list_compat.ArrayList([]const u8).init(allocator);
        defer query_words.deinit();
        var word_iter = std.mem.splitScalar(u8, query_lower, ' ');
        while (word_iter.next()) |word| {
            if (word.len > 2) {
                try query_words.append(word);
            }
        }

        // Resolve PageRank data: use provided, or compute and cache
        var pr_result: ?algorithms.PageRankResult = pagerank;
        if (pr_result == null) {
            const cached = self.ensurePageRankCache(allocator) catch null;
            if (cached) |c| {
                pr_result = .{
                    .ranks = c.ranks,
                    .allocator = c.allocator,
                };
            }
        }

        var scores = array_list_compat.ArrayList(types.RelevanceScore).init(allocator);
        defer scores.deinit();

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            var total_score: f32 = 0.0;

            const name_lower = try toLower(allocator, node.name);
            defer allocator.free(name_lower);
            const path_lower = try toLower(allocator, node.file_path);
            defer allocator.free(path_lower);

            // === Phase 1: Keyword matching (existing logic) ===
            for (query_words.items) |qword| {
                // Name match (highest weight)
                if (std.mem.indexOf(u8, name_lower, qword)) |_| {
                    total_score += 3.0;
                }
                // File path match
                if (std.mem.indexOf(u8, path_lower, qword)) |_| {
                    total_score += 2.0;
                }
                // Doc comment match
                if (node.doc_comment) |doc| {
                    const doc_lower = try toLower(allocator, doc);
                    defer allocator.free(doc_lower);
                    if (std.mem.indexOf(u8, doc_lower, qword)) |_| {
                        total_score += 1.5;
                    }
                }
                // Signature match
                if (node.signature) |sig| {
                    const sig_lower = try toLower(allocator, sig);
                    defer allocator.free(sig_lower);
                    if (std.mem.indexOf(u8, sig_lower, qword)) |_| {
                        total_score += 1.0;
                    }
                }
            }

            if (total_score > 0.0) {
                // === Phase 2: PageRank centrality bonus ===
                // Multiply by (1.0 + pagerank * 0.5) to boost well-connected nodes
                if (pr_result) |pr| {
                    if (pr.ranks.get(node.id)) |rank| {
                        const pr_f32: f32 = @floatCast(rank);
                        total_score *= (1.0 + pr_f32 * 0.5);
                    }
                }

                // === Phase 3: File-type weighting ===
                total_score *= fileTypeWeight(node.file_path);

                // === Phase 4: Community membership bonus ===
                if (self.nodeInCommunity(node.id)) {
                    total_score += 0.5;
                }

                // === Phase 5: Recency bias for module nodes ===
                if (node.node_type == .module) {
                    total_score += 0.3;
                }

                try scores.append(.{
                    .node_id = node.id,
                    .score = total_score,
                });
            }
        }

        // Sort by score descending
        std.sort.insertion(types.RelevanceScore, scores.items, {}, cmpRelevanceDesc);

        const limit = @min(max_results, @as(u32, @intCast(scores.items.len)));
        const result = try allocator.alloc(types.RelevanceScore, limit);
        for (result, 0..limit) |*r, i| {
            r.* = scores.items[i];
        }
        return result;
    }

    /// Comparison for sorting RelevanceScore descending
    fn cmpRelevanceDesc(_: void, a: types.RelevanceScore, b: types.RelevanceScore) bool {
        return a.score > b.score;
    }

    /// Build a relevance-filtered context string within a token budget
    /// Uses scoreRelevance to pick top nodes, then formats them until budget exhausted
    pub fn toRelevantContext(
        self: *KnowledgeGraph,
        allocator: Allocator,
        query: []const u8,
        token_budget: u64,
    ) ![]const u8 {
        const scores = try self.scoreRelevanceAdvanced(allocator, query, 50, null);
        defer allocator.free(scores);

        var buf = array_list_compat.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        var tokens_used: u64 = 0;

        for (scores) |scored| {
            const node = self.getNode(scored.node_id) orelse continue;
            const type_label = @tagName(node.node_type);

            // Build entry text
            var entry_buf = array_list_compat.ArrayList(u8).init(allocator);
            defer entry_buf.deinit();
            const ew = entry_buf.writer();
            ew.print("{s} [{s}] {s}:{d} (score:{d:.1})\n", .{
                node.id,
                type_label,
                node.file_path,
                node.line,
                scored.score,
            }) catch continue;

            const entry_text = entry_buf.items;
            // Simple token estimate: chars/4
            const entry_tokens: u64 = @intCast(entry_text.len / 4 + 1);

            if (tokens_used + entry_tokens > token_budget) break;

            writer.writeAll(entry_text) catch continue;
            tokens_used += entry_tokens;
        }

        return buf.toOwnedSlice();
    }

    /// Extract module name from file path
    fn extractModuleName(_: *KnowledgeGraph, file_path: []const u8) []const u8 {
        // Get filename without extension
        const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
        const filename = if (last_slash > 0) file_path[last_slash + 1 ..] else file_path;
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
        return filename[0..dot];
    }

    pub fn deinit(self: *KnowledgeGraph) void {
        // Invalidate PageRank cache
        self.invalidatePageRankCache();

        // Collect all node pointers first, then clean up
        // (we can't iterate and free keys simultaneously since StringHashMap
        // stores key pointers that are the same as node.id)
        var node_list = array_list_compat.ArrayList(*types.GraphNode).init(self.allocator);
        defer node_list.deinit();
        {
            var node_iter = self.nodes.iterator();
            while (node_iter.next()) |entry| {
                node_list.append(entry.value_ptr.*) catch |err| {
                    std.log.err("KnowledgeGraph.deinit: failed to collect node for cleanup: {}", .{err});
                    break;
                };
            }
        }
        // Free the hash map (doesn't free keys — we do that via node deinit)
        self.nodes.deinit();
        // Now free each node
        for (node_list.items) |node| {
            node.deinit();
            self.allocator.destroy(node);
        }

        for (self.edges.items) |edge| {
            edge.deinit();
            self.allocator.destroy(edge);
        }
        self.edges.deinit();

        for (self.communities.items) |community| {
            community.deinit();
            self.allocator.destroy(community);
        }
        self.communities.deinit();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "KnowledgeGraph init/deinit" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();
    try testing.expectEqual(@as(u32, 0), graph.file_count);
    try testing.expectEqual(@as(u64, 0), graph.total_source_tokens);
}

test "KnowledgeGraph addNode and getNode" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node = try testing.allocator.create(types.GraphNode);
    node.* = try types.GraphNode.init(testing.allocator, "mod.func1", "func1", .function, "src/test.zig", 10);
    try graph.addNode(node);

    const retrieved = graph.getNode("mod.func1");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("func1", retrieved.?.name);
    try testing.expectEqual(types.NodeType.function, retrieved.?.node_type);

    const missing = graph.getNode("mod.nonexistent");
    try testing.expect(missing == null);
}

test "KnowledgeGraph addEdge" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node1 = try testing.allocator.create(types.GraphNode);
    node1.* = try types.GraphNode.init(testing.allocator, "mod.func1", "func1", .function, "src/a.zig", 1);
    try graph.addNode(node1);

    const node2 = try testing.allocator.create(types.GraphNode);
    node2.* = try types.GraphNode.init(testing.allocator, "mod.func2", "func2", .function, "src/b.zig", 5);
    try graph.addNode(node2);

    const edge = try testing.allocator.create(types.GraphEdge);
    edge.* = try types.GraphEdge.init(testing.allocator, "mod.func1", "mod.func2", .calls, .extracted);
    try graph.addEdge(edge);

    try testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try testing.expectEqualStrings("mod.func1", graph.edges.items[0].source_id);
    try testing.expectEqualStrings("mod.func2", graph.edges.items[0].target_id);
}

test "KnowledgeGraph getNodesByType" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const func_node = try testing.allocator.create(types.GraphNode);
    func_node.* = try types.GraphNode.init(testing.allocator, "mod.fn1", "fn1", .function, "src/a.zig", 1);
    try graph.addNode(func_node);

    const struct_node = try testing.allocator.create(types.GraphNode);
    struct_node.* = try types.GraphNode.init(testing.allocator, "mod.S1", "S1", .struct_decl, "src/a.zig", 10);
    try graph.addNode(struct_node);

    const mod_node = try testing.allocator.create(types.GraphNode);
    mod_node.* = try types.GraphNode.init(testing.allocator, "mod.test", "test", .module, "src/a.zig", 1);
    try graph.addNode(mod_node);

    const funcs = try graph.getNodesByType(.function, testing.allocator);
    defer testing.allocator.free(funcs);
    try testing.expectEqual(@as(usize, 1), funcs.len);

    const structs = try graph.getNodesByType(.struct_decl, testing.allocator);
    defer testing.allocator.free(structs);
    try testing.expectEqual(@as(usize, 1), structs.len);

    const modules = try graph.getNodesByType(.module, testing.allocator);
    defer testing.allocator.free(modules);
    try testing.expectEqual(@as(usize, 1), modules.len);
}

test "KnowledgeGraph getEdgesFrom/To" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node_a = try testing.allocator.create(types.GraphNode);
    node_a.* = try types.GraphNode.init(testing.allocator, "a", "a", .function, "a.zig", 1);
    try graph.addNode(node_a);

    const node_b = try testing.allocator.create(types.GraphNode);
    node_b.* = try types.GraphNode.init(testing.allocator, "b", "b", .function, "b.zig", 1);
    try graph.addNode(node_b);

    const node_c = try testing.allocator.create(types.GraphNode);
    node_c.* = try types.GraphNode.init(testing.allocator, "c", "c", .function, "c.zig", 1);
    try graph.addNode(node_c);

    const edge_ab = try testing.allocator.create(types.GraphEdge);
    edge_ab.* = try types.GraphEdge.init(testing.allocator, "a", "b", .calls, .extracted);
    try graph.addEdge(edge_ab);

    const edge_ac = try testing.allocator.create(types.GraphEdge);
    edge_ac.* = try types.GraphEdge.init(testing.allocator, "a", "c", .references, .inferred);
    try graph.addEdge(edge_ac);

    const from_a = try graph.getEdgesFrom("a", testing.allocator);
    defer testing.allocator.free(from_a);
    try testing.expectEqual(@as(usize, 2), from_a.len);

    const to_b = try graph.getEdgesTo("b", testing.allocator);
    defer testing.allocator.free(to_b);
    try testing.expectEqual(@as(usize, 1), to_b.len);

    const to_c = try graph.getEdgesTo("c", testing.allocator);
    defer testing.allocator.free(to_c);
    try testing.expectEqual(@as(usize, 1), to_c.len);
}

test "KnowledgeGraph detectCommunities groups nodes by file" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Add module node
    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "mymod", "mymod", .module, "src/mymod.zig", 1);
    try graph.addNode(mod);

    // Add 3 functions in the same file (enough for community)
    for ([_][]const u8{ "mymod.fn1", "mymod.fn2", "mymod.fn3" }, 0..) |id, i| {
        const node = try testing.allocator.create(types.GraphNode);
        node.* = try types.GraphNode.init(testing.allocator, id, id[7..], .function, "src/mymod.zig", @intCast(i + 1));
        try graph.addNode(node);
    }

    try graph.detectCommunities();
    try testing.expectEqual(@as(usize, 1), graph.communities.items.len);
    try testing.expect(graph.communities.items[0].node_ids.items.len >= 2);
}

test "KnowledgeGraph toCompressedContext generates output" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "mymod", "mymod", .module, "src/mymod.zig", 1);
    try graph.addNode(mod);

    const func = try testing.allocator.create(types.GraphNode);
    func.* = try types.GraphNode.init(testing.allocator, "mymod.hello", "hello", .function, "src/mymod.zig", 10);
    try graph.addNode(func);

    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "Codebase Knowledge Graph") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "mymod") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "hello") != null);
}

test "KnowledgeGraph compressionRatio" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // No tokens yet
    try testing.expectEqual(@as(f64, 0.0), graph.compressionRatio());

    // Add some nodes with token counts
    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "m", "m", .module, "a.zig", 1);
    try graph.addNode(mod);

    const fn1 = try testing.allocator.create(types.GraphNode);
    fn1.* = try types.GraphNode.init(testing.allocator, "m.f1", "f1", .function, "a.zig", 1);
    fn1.token_count = 100;
    try graph.addNode(fn1);

    graph.total_source_tokens = 100;
    const ratio = graph.compressionRatio();
    try testing.expect(ratio > 0.0);
}

test "KnowledgeGraph extractModuleName" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const name = graph.extractModuleName("src/graph/parser.zig");
    try testing.expectEqualStrings("parser", name);

    const name2 = graph.extractModuleName("build.zig");
    try testing.expectEqualStrings("build", name2);

    const name3 = graph.extractModuleName("src/ai/client.zig");
    try testing.expectEqualStrings("client", name3);
}

test "KnowledgeGraph indexFile parses real Zig source" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Index types.zig — should find the module + struct declarations
    try graph.indexFile("src/graph/types.zig");

    // Module node is "mod.types", symbol nodes are "types.GraphNode" etc.
    try testing.expect(graph.getNode("mod.types") != null);
    try testing.expect(graph.getNode("types.GraphNode") != null);
    try testing.expect(graph.getNode("types.GraphEdge") != null);
    try testing.expect(graph.getNode("types.Community") != null);

    // Verify it has edges (contains edges from module to symbols)
    try testing.expect(graph.edges.items.len > 0);

    // Check compressed context
    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "GraphNode") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "types") != null);
}

test "KnowledgeGraph indexFile parses real codebase files" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Index several files to test multi-file graph building
    try graph.indexFile("src/graph/parser.zig");
    try graph.indexFile("src/graph/types.zig");
    try graph.indexFile("src/graph/graph.zig");

    try testing.expectEqual(@as(u32, 3), graph.file_count);
    try testing.expect(graph.nodes.count() > 10); // Should have many symbols

    // Detect communities
    try graph.detectCommunities();
    try testing.expect(graph.communities.items.len > 0);

    // Generate compressed context
    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "Modules") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Symbols") != null);
}

test "KnowledgeGraph scoreRelevance finds relevant nodes" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.indexFile("src/graph/types.zig");
    try graph.indexFile("src/graph/graph.zig");

    const scores = try graph.scoreRelevance(testing.allocator, "GraphNode", 5);
    defer testing.allocator.free(scores);
    try testing.expect(scores.len > 0);

    // Top result should contain "GraphNode" in its node_id
    const top = scores[0];
    try testing.expect(std.mem.indexOf(u8, top.node_id, "GraphNode") != null);
    try testing.expect(top.score > 0.0);
}

test "fileTypeWeight returns correct multipliers" {
    // .zig source files = 1.0x baseline
    try testing.expectEqual(@as(f32, 1.0), KnowledgeGraph.fileTypeWeight("src/graph/graph.zig"));
    try testing.expectEqual(@as(f32, 1.0), KnowledgeGraph.fileTypeWeight("main.zig"));

    // .md/.toml/.yaml config/docs = 0.7x
    try testing.expectEqual(@as(f32, 0.7), KnowledgeGraph.fileTypeWeight("README.md"));
    try testing.expectEqual(@as(f32, 0.7), KnowledgeGraph.fileTypeWeight("build.toml"));
    try testing.expectEqual(@as(f32, 0.7), KnowledgeGraph.fileTypeWeight("config.yaml"));
    try testing.expectEqual(@as(f32, 0.7), KnowledgeGraph.fileTypeWeight("config.yml"));

    // .zon/.json build manifests = 0.8x
    try testing.expectEqual(@as(f32, 0.8), KnowledgeGraph.fileTypeWeight("build.zon"));
    try testing.expectEqual(@as(f32, 0.8), KnowledgeGraph.fileTypeWeight("package.json"));

    // Unknown/other = 0.5x
    try testing.expectEqual(@as(f32, 0.5), KnowledgeGraph.fileTypeWeight("Makefile"));
    try testing.expectEqual(@as(f32, 0.5), KnowledgeGraph.fileTypeWeight("Dockerfile"));
    try testing.expectEqual(@as(f32, 0.5), KnowledgeGraph.fileTypeWeight("script.sh"));
}

test "scoreRelevanceAdvanced boosts high-PageRank nodes" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Create a hub node (well-connected) and a leaf node (isolated)
    const hub = try testing.allocator.create(types.GraphNode);
    hub.* = try types.GraphNode.init(testing.allocator, "mod.hub", "hub", .function, "src/hub.zig", 1);
    try graph.addNode(hub);

    const leaf = try testing.allocator.create(types.GraphNode);
    leaf.* = try types.GraphNode.init(testing.allocator, "mod.leaf", "leaf", .function, "src/leaf.zig", 1);
    try graph.addNode(leaf);

    const spoke1 = try testing.allocator.create(types.GraphNode);
    spoke1.* = try types.GraphNode.init(testing.allocator, "mod.spoke1", "spoke1", .function, "src/spoke1.zig", 1);
    try graph.addNode(spoke1);

    const spoke2 = try testing.allocator.create(types.GraphNode);
    spoke2.* = try types.GraphNode.init(testing.allocator, "mod.spoke2", "spoke2", .function, "src/spoke2.zig", 1);
    try graph.addNode(spoke2);

    // Hub has many edges → higher PageRank
    const e1 = try testing.allocator.create(types.GraphEdge);
    e1.* = try types.GraphEdge.init(testing.allocator, "mod.hub", "mod.spoke1", .calls, .extracted);
    try graph.addEdge(e1);

    const e2 = try testing.allocator.create(types.GraphEdge);
    e2.* = try types.GraphEdge.init(testing.allocator, "mod.hub", "mod.spoke2", .calls, .extracted);
    try graph.addEdge(e2);

    const e3 = try testing.allocator.create(types.GraphEdge);
    e3.* = try types.GraphEdge.init(testing.allocator, "mod.spoke1", "mod.spoke2", .calls, .extracted);
    try graph.addEdge(e3);

    // Query matching both hub and leaf by file path ("src")
    const scores = try graph.scoreRelevanceAdvanced(testing.allocator, "src", 10, null);
    defer testing.allocator.free(scores);

    // Both should appear
    var hub_score: f32 = 0.0;
    var leaf_score: f32 = 0.0;
    for (scores) |s| {
        if (std.mem.indexOf(u8, s.node_id, "hub") != null) hub_score = s.score;
        if (std.mem.indexOf(u8, s.node_id, "leaf") != null) leaf_score = s.score;
    }

    // Hub should score higher than leaf due to PageRank centrality bonus
    try testing.expect(hub_score > leaf_score);
}

test "scoreRelevance backward compatible via wrapper" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.indexFile("src/graph/types.zig");

    // Both methods should return results
    const scores_basic = try graph.scoreRelevance(testing.allocator, "GraphNode", 5);
    defer testing.allocator.free(scores_basic);

    const scores_adv = try graph.scoreRelevanceAdvanced(testing.allocator, "GraphNode", 5, null);
    defer testing.allocator.free(scores_adv);

    // Both should find the same top node
    try testing.expect(scores_basic.len > 0);
    try testing.expect(scores_adv.len > 0);
    try testing.expect(std.mem.indexOf(u8, scores_basic[0].node_id, "GraphNode") != null);
    try testing.expect(std.mem.indexOf(u8, scores_adv[0].node_id, "GraphNode") != null);
}

test "scoreRelevanceAdvanced community bonus applies" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Create two nodes in the same file (will form a community)
    const node_a = try testing.allocator.create(types.GraphNode);
    node_a.* = try types.GraphNode.init(testing.allocator, "mod.fnA", "fnA", .function, "src/module.zig", 1);
    try graph.addNode(node_a);

    const node_b = try testing.allocator.create(types.GraphNode);
    node_b.* = try types.GraphNode.init(testing.allocator, "mod.fnB", "fnB", .function, "src/module.zig", 10);
    try graph.addNode(node_b);

    // Create a module node to ensure community detection sees 3+ nodes
    const node_mod = try testing.allocator.create(types.GraphNode);
    node_mod.* = try types.GraphNode.init(testing.allocator, "mod", "mod", .module, "src/module.zig", 1);
    try graph.addNode(node_mod);

    // Create a standalone node in a different file (no community)
    const node_c = try testing.allocator.create(types.GraphNode);
    node_c.* = try types.GraphNode.init(testing.allocator, "mod2.fnC", "fnC", .function, "src/other.zig", 1);
    try graph.addNode(node_c);

    // Add edge so PageRank doesn't make the comparison ambiguous
    const edge = try testing.allocator.create(types.GraphEdge);
    edge.* = try types.GraphEdge.init(testing.allocator, "mod.fnA", "mod.fnB", .calls, .extracted);
    try graph.addEdge(edge);

    // Detect communities
    try graph.detectCommunities();

    // Score without community vs with community
    // Query "fn" matches both fnA/fnB and fnC
    const scores = try graph.scoreRelevanceAdvanced(testing.allocator, "fn", 10, null);
    defer testing.allocator.free(scores);

    var community_score: f32 = 0.0;
    var isolated_score: f32 = 0.0;
    for (scores) |s| {
        if (std.mem.eql(u8, s.node_id, "mod.fnA")) community_score = s.score;
        if (std.mem.eql(u8, s.node_id, "mod2.fnC")) isolated_score = s.score;
    }

    // Community node should score higher (community bonus + same keyword weight)
    try testing.expect(community_score > isolated_score);
}

test "scoreRelevanceAdvanced module recency bias" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Module node and function node with same name match
    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "mod.testmod", "testmod", .module, "src/testmod.zig", 1);
    try graph.addNode(mod);

    const func = try testing.allocator.create(types.GraphNode);
    func.* = try types.GraphNode.init(testing.allocator, "mod.testmod_fn", "testmod_fn", .function, "src/testmod.zig", 5);
    try graph.addNode(func);

    // Query "testmod" matches both
    const scores = try graph.scoreRelevanceAdvanced(testing.allocator, "testmod", 10, null);
    defer testing.allocator.free(scores);

    var module_score: f32 = 0.0;
    var function_score: f32 = 0.0;
    for (scores) |s| {
        if (std.mem.eql(u8, s.node_id, "mod.testmod")) module_score = s.score;
        if (std.mem.eql(u8, s.node_id, "mod.testmod_fn")) function_score = s.score;
    }

    // Module gets +0.3 recency bias, so it should score higher than function
    // (function only gets name match 3.0, module gets 3.0 + 0.3 = 3.3)
    try testing.expect(module_score > function_score);
}

test "scoreRelevanceAdvanced accepts precomputed PageRank" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.indexFile("src/graph/types.zig");

    // Precompute PageRank
    var pr = try graph.computePageRank(testing.allocator);
    defer pr.deinit();

    // Pass precomputed result — should work without recomputation
    const scores = try graph.scoreRelevanceAdvanced(testing.allocator, "GraphNode", 5, pr);
    defer testing.allocator.free(scores);

    try testing.expect(scores.len > 0);
    try testing.expect(std.mem.indexOf(u8, scores[0].node_id, "GraphNode") != null);
}
