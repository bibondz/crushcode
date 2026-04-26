/// Knowledge Pipeline — unified auto-indexing that fuses:
///   file_type detection → graph analysis → knowledge vault ingestion
///
/// The pipeline runs once at chat startup, scanning a project directory,
/// indexing code files into a KnowledgeGraph and KnowledgeVault, then
/// building compressed context for AI prompts.
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// External module types (imported via build.zig)
const file_type_mod = @import("file_type");
const graph_mod = @import("graph");
const knowledge_schema_mod = @import("knowledge_schema");
const knowledge_ingest_mod = @import("knowledge_ingest_mod");
const knowledge_query_mod = @import("knowledge_query_mod");

const layered_memory_mod = @import("layered_memory");
const source_tracker_mod = @import("source_tracker");

const tiered_loader_mod = @import("tiered_loader");
const intensity_mod = @import("intensity");
const context_optimizer_mod = @import("context_optimizer");

const LoadTier = tiered_loader_mod.LoadTier;
const selectTier = tiered_loader_mod.selectTier;
const Intensity = intensity_mod.Intensity;
const ContextOptimizer = context_optimizer_mod.ContextOptimizer;
const OptimizationProfile = context_optimizer_mod.OptimizationProfile;

const FileDetector = file_type_mod.FileDetector;
const DetectionResult = file_type_mod.DetectionResult;
const KnowledgeGraph = graph_mod.KnowledgeGraph;
const KnowledgeVault = knowledge_schema_mod.KnowledgeVault;
const KnowledgeIngester = knowledge_ingest_mod.KnowledgeIngester;
const KnowledgeQuerier = knowledge_query_mod.KnowledgeQuerier;
const LayeredMemory = layered_memory_mod.LayeredMemory;
const MemoryLayer = layered_memory_mod.MemoryLayer;
const SourceTracker = source_tracker_mod.SourceTracker;
const SourceProvenance = source_tracker_mod.SourceProvenance;

// ── Pipeline statistics ────────────────────────────────────────

pub const PipelineStats = struct {
    files_scanned: u32 = 0,
    files_indexed: u32 = 0,
    files_skipped: u32 = 0,
    files_errored: u32 = 0,
    vault_nodes: u32 = 0,
    graph_nodes: u32 = 0,
    graph_edges: u32 = 0,
    communities: u32 = 0,
    total_source_tokens: u64 = 0,
    memory_entries: u32 = 0,
    insights_count: u32 = 0,
    tracked_sources: u32 = 0,
};

// ── Graph Intelligence Types ───────────────────────────────────

/// A node ranked by PageRank score
pub const RankedNode = struct {
    id: []const u8,
    rank: f64,

    pub fn deinit(self: *RankedNode, allocator: Allocator) void {
        allocator.free(self.id);
    }
};

/// Similarity result between two nodes
pub const SimilarityResult = struct {
    node_id: []const u8,
    similarity: f64,

    pub fn deinit(self: *SimilarityResult, allocator: Allocator) void {
        allocator.free(self.node_id);
    }
};

/// Information about a tag-based cluster
pub const ClusterInfo = struct {
    tag: []const u8,
    node_count: u32,

    pub fn deinit(self: *ClusterInfo, allocator: Allocator) void {
        allocator.free(self.tag);
    }
};

/// Aggregated graph intelligence insights
pub const GraphInsights = struct {
    top_ranked: []RankedNode,
    bridges: []const []const u8,
    clusters: []ClusterInfo,

    pub fn deinit(self: *GraphInsights, allocator: Allocator) void {
        for (self.top_ranked) |*rn| {
            var mut = rn;
            mut.deinit(allocator);
        }
        allocator.free(self.top_ranked);

        // bridges are owned — free each string then the slice
        const bridges_mut = @constCast(self.bridges);
        for (bridges_mut) |id| {
            allocator.free(id);
        }
        allocator.free(bridges_mut);

        for (self.clusters) |*ci| {
            var mut = ci;
            mut.deinit(allocator);
        }
        allocator.free(self.clusters);
    }
};

// ── KnowledgePipeline ──────────────────────────────────────────

pub const KnowledgePipeline = struct {
    allocator: Allocator,
    detector: FileDetector,
    kg: KnowledgeGraph,
    vault: KnowledgeVault,
    ingester: KnowledgeIngester,
    querier: KnowledgeQuerier,
    pipeline_stats: PipelineStats,
    initialized: bool,
    memory: ?*LayeredMemory,
    source_tracker: SourceTracker,

    /// Initialize the pipeline and all sub-components.
    /// Returns a heap-allocated KnowledgePipeline to ensure internal
    /// pointers (ingester/querier → vault) remain stable.
    /// If project_dir is provided, LayeredMemory is created for that directory.
    /// If null, memory stays null (graceful degradation).
    /// Caller owns the returned pointer — call deinit() when done.
    pub fn init(allocator: Allocator, project_dir: ?[]const u8) !*KnowledgePipeline {
        var detector = FileDetector.init(allocator) catch
            return error.PipelineInitFailed;
        errdefer detector.deinit();

        // Create LayeredMemory if project_dir provided
        var memory: ?*LayeredMemory = null;
        if (project_dir) |dir| {
            const mem = allocator.create(LayeredMemory) catch
                return error.PipelineInitFailed;
            errdefer allocator.destroy(mem);
            mem.* = LayeredMemory.init(allocator, dir) catch {
                allocator.destroy(mem);
                // Graceful degradation: continue without memory
                memory = null;
                const self = allocator.create(KnowledgePipeline) catch {
                    detector.deinit();
                    return error.PipelineInitFailed;
                };
                errdefer allocator.destroy(self);
                self.* = KnowledgePipeline{
                    .allocator = allocator,
                    .detector = detector,
                    .kg = KnowledgeGraph.init(allocator),
                    .vault = KnowledgeVault.init(allocator, ".knowledge/raw") catch {
                        detector.deinit();
                        allocator.destroy(self);
                        return error.PipelineInitFailed;
                    },
                    .ingester = undefined,
                    .querier = undefined,
                    .pipeline_stats = PipelineStats{},
                    .initialized = true,
                    .memory = null,
                    .source_tracker = SourceTracker.init(allocator),
                };
                self.ingester = KnowledgeIngester.init(allocator, &self.vault);
                self.querier = KnowledgeQuerier.init(allocator, &self.vault);
                return self;
            };
            memory = mem;
        }

        const self = allocator.create(KnowledgePipeline) catch {
            detector.deinit();
            if (memory) |mem| {
                mem.deinit();
                allocator.destroy(mem);
            }
            return error.PipelineInitFailed;
        };
        errdefer allocator.destroy(self);
        self.* = KnowledgePipeline{
            .allocator = allocator,
            .detector = detector,
            .kg = KnowledgeGraph.init(allocator),
            .vault = KnowledgeVault.init(allocator, ".knowledge/raw") catch {
                detector.deinit();
                if (memory) |mem| {
                    mem.deinit();
                    allocator.destroy(mem);
                }
                allocator.destroy(self);
                return error.PipelineInitFailed;
            },
            .ingester = undefined,
            .querier = undefined,
            .pipeline_stats = PipelineStats{},
            .initialized = true,
            .memory = memory,
            .source_tracker = SourceTracker.init(allocator),
        };
        // Fix up ingester/querier — they need a pointer to the vault field
        self.ingester = KnowledgeIngester.init(allocator, &self.vault);
        self.querier = KnowledgeQuerier.init(allocator, &self.vault);
        return self;
    }

    /// Clean up all resources owned by the pipeline and free the heap allocation.
    pub fn deinit(self: *KnowledgePipeline) void {
        if (!self.initialized) return;
        const allocator = self.allocator;
        if (self.memory) |mem| {
            mem.deinit();
            allocator.destroy(mem);
        }
        self.source_tracker.deinit();
        self.detector.deinit();
        self.kg.deinit();
        self.vault.deinit();
        // ingester and querier are stack structs pointing to vault — no extra deinit
        self.initialized = false;
        allocator.destroy(self);
    }

    /// Scan a project directory, detect file types, index code files
    /// into the knowledge graph and vault.
    ///
    /// Walks `dir_path` recursively. For each file:
    ///   1. Detect file type via FileDetector
    ///   2. If code group → index into KnowledgeGraph
    ///   3. Ingest into KnowledgeVault
    /// Stops after `max_files` code files are indexed.
    pub fn scanProject(self: *KnowledgePipeline, dir_path: []const u8, max_files: u32) !void {
        var src_dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer src_dir.close();
        var walker = src_dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;

            // Skip hidden files and common non-code directories
            if (self.shouldSkip(entry.path)) continue;

            // Stop if we've hit the max
            if (self.pipeline_stats.files_indexed >= max_files) break;

            self.pipeline_stats.files_scanned += 1;

            // Step 1: detect file type
            var detection = self.detector.detectFile(entry.path) catch {
                self.pipeline_stats.files_errored += 1;
                continue;
            };
            defer detection.deinit();

            // Step 2: if code group, index into graph
            if (detection.content_type) |ct| {
                if (std.mem.eql(u8, ct.group, "code")) {
                    self.kg.indexFile(entry.path) catch {
                        self.pipeline_stats.files_errored += 1;
                        continue;
                    };

                    // Step 3: ingest into vault
                    _ = self.ingester.ingestFile(entry.path) catch {
                        self.pipeline_stats.files_errored += 1;
                        continue;
                    };

                    self.pipeline_stats.files_indexed += 1;
                    continue;
                }
            }

            // Also index text-type files (.md, .toml, etc.) into vault only
            if (detection.content_type) |ct| {
                if (ct.is_text) {
                    _ = self.ingester.ingestFile(entry.path) catch continue;
                    // Don't count as "indexed" for graph stats, but vault gets them
                    continue;
                }
            }

            self.pipeline_stats.files_skipped += 1;
        }

        // Detect communities after all files are indexed
        self.kg.detectCommunities() catch {};

        // Update cached stats
        self.pipeline_stats.graph_nodes = @intCast(self.kg.nodes.count());
        self.pipeline_stats.graph_edges = @intCast(self.kg.edges.items.len);
        self.pipeline_stats.communities = @intCast(self.kg.communities.items.len);
        self.pipeline_stats.total_source_tokens = self.kg.total_source_tokens;
        self.pipeline_stats.vault_nodes = self.vault.count();
    }

    /// Index specific file paths (for backward compatibility with explicit file lists).
    pub fn indexFiles(self: *KnowledgePipeline, file_paths: []const []const u8) void {
        for (file_paths) |file_path| {
            self.kg.indexFile(file_path) catch continue;
            _ = self.ingester.ingestFile(file_path) catch continue;
            self.pipeline_stats.files_indexed += 1;
        }
        self.kg.detectCommunities() catch {};

        self.pipeline_stats.graph_nodes = @intCast(self.kg.nodes.count());
        self.pipeline_stats.graph_edges = @intCast(self.kg.edges.items.len);
        self.pipeline_stats.communities = @intCast(self.kg.communities.items.len);
        self.pipeline_stats.total_source_tokens = self.kg.total_source_tokens;
        self.pipeline_stats.vault_nodes = self.vault.count();
    }

    /// Bridge graph nodes into the knowledge vault.
    /// Iterates all graph nodes and ingests them as knowledge nodes
    /// so the querier can find them alongside file-based nodes.
    pub fn indexGraphToVault(self: *KnowledgePipeline) !void {
        var node_iter = self.kg.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            // Skip module nodes — they're structural, not content-bearing
            if (node.node_type == .module) continue;

            const type_label = @tagName(node.node_type);
            self.ingester.ingestGraphNode(
                node.id,
                node.name,
                type_label,
                node.file_path,
                node.doc_comment,
            ) catch continue;
        }

        self.pipeline_stats.vault_nodes = self.vault.count();
    }

    /// Build a context string suitable for an AI system prompt.
    ///
    /// If `query` is provided, uses the knowledge querier to find relevant
    /// nodes first, then appends the structural graph overview. The result
    /// is truncated to stay within `max_tokens` (estimated at chars/4).
    pub fn buildContext(self: *KnowledgePipeline, query: ?[]const u8, max_tokens: u32) !?[]const u8 {
        if (self.pipeline_stats.files_indexed == 0) return null;

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        // Header
        try writer.print("=== Codebase Knowledge Graph ===\n", .{});
        try writer.print("Files indexed: {d} | Nodes: {d} | Edges: {d} | Communities: {d}\n\n", .{
            self.pipeline_stats.files_indexed,
            self.pipeline_stats.graph_nodes,
            self.pipeline_stats.graph_edges,
            self.pipeline_stats.communities,
        });

        // Query-relevant context if query provided
        if (query) |q| {
            if (q.len > 0) {
                const query_results = self.querier.query(q, 5) catch &.{};
                defer {
                    for (query_results, 0..) |_, i| {
                        var mut_r = @constCast(&query_results[i]);
                        mut_r.deinit(self.allocator);
                    }
                    if (query_results.len > 0) self.allocator.free(@constCast(query_results));
                }

                if (query_results.len > 0) {
                    try writer.print("## Query-Relevant Nodes\n", .{});
                    for (query_results) |result| {
                        try writer.print("  {s} (relevance: {d:.1}) — {s}\n", .{
                            result.title,
                            result.relevance,
                            result.snippet,
                        });
                    }
                    try writer.print("\n", .{});
                }
            }
        }

        // Graph relevance if query provided
        if (query) |q| {
            if (q.len > 0) {
                const rel_ctx = self.kg.toRelevantContext(self.allocator, q, 200) catch null;
                if (rel_ctx) |ctx| {
                    defer self.allocator.free(ctx);
                    try writer.print("## Graph Relevance\n{s}\n", .{ctx});
                }
            }
        }

        // Compressed structural overview
        const graph_ctx = self.kg.toCompressedContext(self.allocator) catch null;
        defer if (graph_ctx) |ctx| self.allocator.free(ctx);

        if (graph_ctx) |ctx| {
            try writer.print("\n{s}", .{ctx});
        }

        const result = buf.toOwnedSlice() catch return null;

        // Truncate if exceeds token budget (rough: 4 chars per token)
        const max_chars = max_tokens * 4;
        if (result.len > max_chars) {
            const truncated = self.allocator.alloc(u8, max_chars) catch return result;
            @memcpy(truncated, result[0..max_chars]);
            self.allocator.free(result);
            return truncated;
        }

        return result;
    }

    /// Build smart context using tiered loading, context optimization, and intensity control.
    /// Combines graph structure, knowledge vault results, and session memory into a
    /// single optimized context string that fits within a dynamic token budget.
    ///
    /// query: the user's message (used to select tier + find relevant knowledge)
    /// intensity: output intensity level (controls verbosity / budget adjustment)
    /// Returns optimized context string, or null if nothing to contribute.
    pub fn buildSmartContext(self: *KnowledgePipeline, query: []const u8, intensity: Intensity) !?[]const u8 {
        // Step 1: Select tier based on query characteristics
        const tier = selectTier(if (query.len > 0) query else "focused");
        const budget = tier.tokenBudget();
        const max_pages = tier.maxPages();

        // Adjust budget based on intensity (lite/ultra = less context needed)
        const adjusted_budget = switch (intensity) {
            .lite => budget * 3 / 4,
            .normal => budget,
            .full => budget * 4 / 5,
            .ultra => budget / 2,
        };

        // Step 2: Gather context from multiple sources
        var parts = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (parts.items) |p| self.allocator.free(p);
            parts.deinit();
        }

        // 2a: Graph compressed context (structural overview)
        const graph_ctx = self.kg.toCompressedContext(self.allocator) catch null;
        if (graph_ctx) |ctx| {
            const header = try std.fmt.allocPrint(self.allocator, "## Codebase Structure\n{s}", .{ctx});
            self.allocator.free(ctx);
            try parts.append(header);
        }

        // 2b: Knowledge vault query results (relevant to user query)
        if (query.len > 0) {
            const vault_results = self.querier.query(query, max_pages) catch &[_]knowledge_query_mod.QueryResult{};
            defer {
                for (vault_results, 0..) |_, i| {
                    var mut_r = @constCast(&vault_results[i]);
                    mut_r.deinit(self.allocator);
                }
                if (vault_results.len > 0) self.allocator.free(@constCast(vault_results));
            }
            if (vault_results.len > 0) {
                var vault_parts = array_list_compat.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (vault_parts.items) |p| self.allocator.free(p);
                    vault_parts.deinit();
                }
                for (vault_results) |r| {
                    const str = try std.fmt.allocPrint(self.allocator, "- {s}: {s}", .{ r.title, r.snippet });
                    try vault_parts.append(str);
                }
                const vault_str = try std.mem.join(self.allocator, "\n", vault_parts.items);
                const header = try std.fmt.allocPrint(self.allocator, "## Relevant Knowledge\n{s}", .{vault_str});
                self.allocator.free(vault_str);
                try parts.append(header);
            }
        }

        // 2c: Memory search results (if memory is available)
        if (self.memory != null) {
            const mem_result = self.searchMemory(query) catch null;
            if (mem_result) |mem_str| {
                const header = try std.fmt.allocPrint(self.allocator, "## Session Memory\n{s}", .{mem_str});
                self.allocator.free(mem_str);
                try parts.append(header);
            }
        }

        if (parts.items.len == 0) return null;

        // Step 3: Combine all context sections
        var combined = try std.mem.join(self.allocator, "\n\n", parts.items);

        // Step 4: Apply context optimization (compact profile trims filler)
        var optimizer = ContextOptimizer.init(self.allocator, .compact);
        const optimized = optimizer.optimize(combined) catch combined;
        if (optimized.ptr != combined.ptr) {
            self.allocator.free(combined);
            combined = optimized;
        }
        optimizer.deinit();

        // Step 5: Enforce token budget (rough cut at ~4 chars per token)
        const estimated_tokens = combined.len / 4;
        if (estimated_tokens > adjusted_budget) {
            const cut_bytes = adjusted_budget * 4;
            if (cut_bytes < combined.len) {
                const trimmed = try self.allocator.dupe(u8, combined[0..cut_bytes]);
                self.allocator.free(combined);
                combined = trimmed;
            }
        }

        return combined;
    }

    /// Return current pipeline statistics.
    pub fn stats(self: *const KnowledgePipeline) PipelineStats {
        var s = PipelineStats{
            .files_scanned = self.pipeline_stats.files_scanned,
            .files_indexed = self.pipeline_stats.files_indexed,
            .files_skipped = self.pipeline_stats.files_skipped,
            .files_errored = self.pipeline_stats.files_errored,
            .vault_nodes = self.vault.count(),
            .graph_nodes = @intCast(self.kg.nodes.count()),
            .graph_edges = @intCast(self.kg.edges.items.len),
            .communities = @intCast(self.kg.communities.items.len),
            .total_source_tokens = self.kg.total_source_tokens,
            .memory_entries = 0,
            .insights_count = 0,
            .tracked_sources = self.source_tracker.count(),
        };
        if (self.memory) |mem| {
            const mem_stats = mem.getStats();
            s.memory_entries = mem_stats.total;
            s.insights_count = mem_stats.insights_count;
        }
        return s;
    }

    /// Print pipeline stats to stdout.
    pub fn printStats(self: *const KnowledgePipeline) void {
        const s = self.stats();
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Knowledge Pipeline Stats ===\n", .{}) catch {};
        stdout.print("  Files scanned:  {d}\n", .{s.files_scanned}) catch {};
        stdout.print("  Files indexed:  {d}\n", .{s.files_indexed}) catch {};
        stdout.print("  Files skipped:  {d}\n", .{s.files_skipped}) catch {};
        stdout.print("  Files errored:  {d}\n", .{s.files_errored}) catch {};
        stdout.print("  Vault nodes:    {d}\n", .{s.vault_nodes}) catch {};
        stdout.print("  Graph nodes:    {d}\n", .{s.graph_nodes}) catch {};
        stdout.print("  Graph edges:    {d}\n", .{s.graph_edges}) catch {};
        stdout.print("  Communities:    {d}\n", .{s.communities}) catch {};
        stdout.print("  Source tokens:  {d}\n", .{s.total_source_tokens}) catch {};
        stdout.print("  Memory entries: {d}\n", .{s.memory_entries}) catch {};
        stdout.print("  Insights:       {d}\n", .{s.insights_count}) catch {};
        stdout.print("  Tracked sources:{d}\n", .{s.tracked_sources}) catch {};
        const ratio = self.kg.compressionRatio();
        if (ratio > 0) {
            stdout.print("  Compression:    {d:.1}x\n", .{ratio}) catch {};
        }
    }

    // ── Graph Intelligence Methods ────────────────────────────────

    /// Compute comprehensive graph insights: PageRank, bridges, clusters.
    /// Returns a GraphInsights struct owned by the caller.
    pub fn computeInsights(self: *KnowledgePipeline) !GraphInsights {
        const allocator = self.allocator;

        // Handle empty graph gracefully
        if (self.kg.nodes.count() == 0) {
            return GraphInsights{
                .top_ranked = &.{},
                .bridges = &.{},
                .clusters = &.{},
            };
        }

        // 1. PageRank
        var pr = try self.kg.computePageRank(allocator);
        defer pr.deinit();

        // Sort by rank descending — collect into a list first
        var ranked_list = array_list_compat.ArrayList(RankedNode).init(allocator);
        errdefer {
            for (ranked_list.items) |*rn| {
                var mut = rn;
                mut.deinit(allocator);
            }
            ranked_list.deinit();
        }

        var pr_iter = pr.ranks.iterator();
        while (pr_iter.next()) |entry| {
            try ranked_list.append(.{
                .id = try allocator.dupe(u8, entry.key_ptr.*),
                .rank = entry.value_ptr.*,
            });
        }
        std.sort.insertion(RankedNode, ranked_list.items, {}, cmpRankedNodeDesc);

        // Take top 5 (or fewer)
        const top_count = @min(@as(usize, 5), ranked_list.items.len);
        const top_ranked = try allocator.alloc(RankedNode, top_count);
        for (top_ranked, 0..top_count) |*rn, i| {
            rn.* = ranked_list.items[i];
        }
        // Free excess items
        for (ranked_list.items[top_count..]) |*rn| {
            var mut = rn;
            mut.deinit(allocator);
        }
        ranked_list.deinit();

        // 2. Bridges
        const bridge_ids: []const []const u8 = self.kg.findBridges(allocator) catch &.{};

        // 3. Clusters
        var cluster_result: []ClusterInfo = &.{};
        const tag_clusters = self.kg.clusterByTags(allocator) catch null;
        if (tag_clusters) |tc| {
            defer {
                for (tc) |*c| c.deinit();
                allocator.free(tc);
            }
            cluster_result = try allocator.alloc(ClusterInfo, tc.len);
            errdefer {
                for (cluster_result) |*ci| {
                    var mut = ci;
                    mut.deinit(allocator);
                }
                allocator.free(cluster_result);
            }
            for (tc, 0..) |cluster, i| {
                cluster_result[i] = .{
                    .tag = try allocator.dupe(u8, cluster.tag),
                    .node_count = @intCast(cluster.node_ids.items.len),
                };
            }
        }

        return GraphInsights{
            .top_ranked = top_ranked,
            .bridges = bridge_ids,
            .clusters = cluster_result,
        };
    }

    /// Comparison for sorting RankedNode descending by rank
    fn cmpRankedNodeDesc(_: void, a: RankedNode, b: RankedNode) bool {
        return a.rank > b.rank;
    }

    /// Get the top N nodes by PageRank score, sorted descending.
    pub fn getTopRankedNodes(self: *KnowledgePipeline, count: u32) ![]RankedNode {
        const allocator = self.allocator;

        if (self.kg.nodes.count() == 0) return &.{};

        var pr = try self.kg.computePageRank(allocator);
        defer pr.deinit();

        var ranked_list = array_list_compat.ArrayList(RankedNode).init(allocator);
        errdefer {
            for (ranked_list.items) |*rn| {
                var mut = rn;
                mut.deinit(allocator);
            }
            ranked_list.deinit();
        }

        var pr_iter = pr.ranks.iterator();
        while (pr_iter.next()) |entry| {
            try ranked_list.append(.{
                .id = try allocator.dupe(u8, entry.key_ptr.*),
                .rank = entry.value_ptr.*,
            });
        }
        std.sort.insertion(RankedNode, ranked_list.items, {}, cmpRankedNodeDesc);

        const limit = @min(@as(usize, @intCast(count)), ranked_list.items.len);
        const result = try allocator.alloc(RankedNode, limit);
        for (result, 0..limit) |*rn, i| {
            rn.* = ranked_list.items[i];
        }
        // Free excess items
        for (ranked_list.items[limit..]) |*rn| {
            var mut = rn;
            mut.deinit(allocator);
        }
        ranked_list.deinit();

        return result;
    }

    /// Find nodes most similar to the given node_id using Jaccard similarity.
    pub fn findSimilarNodes(self: *KnowledgePipeline, node_id: []const u8, count: u32) ![]SimilarityResult {
        const allocator = self.allocator;

        if (self.kg.nodes.count() == 0) return &.{};

        const raw_results = try self.kg.findSimilar(allocator, node_id, count);
        // findSimilar returns []types.SimilarityResult — convert to owned results
        defer allocator.free(raw_results);

        const limit = @min(@as(usize, @intCast(count)), raw_results.len);
        const result = try allocator.alloc(SimilarityResult, limit);
        errdefer {
            for (result) |*sr| {
                var mut = sr;
                mut.deinit(allocator);
            }
            allocator.free(result);
        }
        for (result, 0..limit) |*sr, i| {
            sr.* = .{
                .node_id = try allocator.dupe(u8, raw_results[i].node_id),
                .similarity = raw_results[i].similarity,
            };
        }
        return result;
    }

    /// Get bridge nodes (articulation points) whose removal would disconnect the graph.
    pub fn getBridgeNodes(self: *KnowledgePipeline) ![][]const u8 {
        return self.kg.findBridges(self.allocator);
    }

    /// Pretty-print graph insights to stdout.
    pub fn printInsights(self: *KnowledgePipeline) void {
        const stdout = file_compat.File.stdout().writer();

        var insights = self.computeInsights() catch {
            stdout.print("\n  Failed to compute graph insights\n", .{}) catch {};
            return;
        };
        defer insights.deinit(self.allocator);

        stdout.print("\n=== Graph Intelligence ===\n", .{}) catch {};

        // Top ranked nodes
        if (insights.top_ranked.len > 0) {
            stdout.print("  Top nodes by PageRank:\n", .{}) catch {};
            for (insights.top_ranked, 0..) |rn, i| {
                stdout.print("    {d}. {s} ({d:.2})\n", .{ i + 1, rn.id, rn.rank }) catch {};
            }
        } else {
            stdout.print("  No ranked nodes (empty graph)\n", .{}) catch {};
        }

        // Bridge nodes
        if (insights.bridges.len > 0) {
            stdout.print("  Bridge nodes: {d} (single points of failure)\n", .{insights.bridges.len}) catch {};
            for (insights.bridges) |id| {
                stdout.print("    - {s}\n", .{id}) catch {};
            }
        } else {
            stdout.print("  Bridge nodes: 0 (no articulation points)\n", .{}) catch {};
        }

        // Clusters
        if (insights.clusters.len > 0) {
            stdout.print("  Clusters: {d}\n", .{insights.clusters.len}) catch {};
            for (insights.clusters) |ci| {
                stdout.print("    - {s} ({d} nodes)\n", .{ ci.tag, ci.node_count }) catch {};
            }
        } else {
            stdout.print("  Clusters: 0\n", .{}) catch {};
        }
    }

    // ── Memory × Knowledge Bridge Methods ────────────────────────

    /// Sync vault nodes into working memory.
    /// For each knowledge vault node, creates a working memory entry
    /// and records provenance via the source tracker.
    pub fn syncVaultToMemory(self: *KnowledgePipeline) !void {
        const mem = self.memory orelse return;
        var iter = self.vault.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;

            // Skip if already tracked by source_tracker
            const track_id = try std.fmt.allocPrint(self.allocator, "vault.{s}", .{node.id});
            defer self.allocator.free(track_id);
            if (self.source_tracker.findById(track_id) != null) continue;

            // Create tags array from node tags
            var tags = array_list_compat.ArrayList([]const u8).init(self.allocator);
            defer tags.deinit();
            for (node.tags.items) |t| try tags.append(t);

            // Store in working memory
            _ = try mem.store(.working, node.title, node.content, node.source_path orelse "vault", tags.items);

            // Track provenance
            var prov = try SourceProvenance.init(self.allocator, .wiki, "knowledge-vault");
            _ = prov.withConfidence(node.confidence);
            try self.source_tracker.record(track_id, node.content, prov);
            prov.deinit();
        }
    }

    /// Distill memory insights into knowledge vault nodes.
    /// For each entry in the insights layer, creates a knowledge vault node
    /// and records provenance.
    pub fn syncMemoryInsightsToVault(self: *KnowledgePipeline) !void {
        const mem = self.memory orelse return;
        for (mem.insights_entries.items) |entry| {
            const vault_id = try std.fmt.allocPrint(self.allocator, "insight.{s}", .{entry.key});
            errdefer self.allocator.free(vault_id);

            // Skip if already in vault
            if (self.vault.getNode(vault_id) != null) {
                self.allocator.free(vault_id);
                continue;
            }

            // Create knowledge node from insight
            const node = try self.allocator.create(knowledge_schema_mod.KnowledgeNode);
            node.* = knowledge_schema_mod.KnowledgeNode.init(self.allocator, vault_id, entry.key, entry.value, .ai_generated) catch {
                self.allocator.destroy(node);
                self.allocator.free(vault_id);
                continue;
            };
            node.confidence = entry.confidence;
            for (entry.tags.items) |t| node.addTag(t) catch {};
            self.vault.addNode(node) catch {
                node.deinit();
                self.allocator.destroy(node);
                continue;
            };

            // Track provenance
            var prov = try SourceProvenance.init(self.allocator, .derived, "memory-distill");
            _ = prov.withConfidence(entry.confidence);
            self.source_tracker.record(vault_id, entry.value, prov) catch {};
            prov.deinit();
        }
    }

    /// Trigger memory distillation and sync insights to vault.
    /// Returns the number of insights created by distillation.
    pub fn distillMemory(self: *KnowledgePipeline) !usize {
        const mem = self.memory orelse return 0;
        const count = try mem.distill();
        if (count > 0) {
            try self.syncMemoryInsightsToVault();
        }
        return count;
    }

    /// Search both memory layers and knowledge vault.
    /// Returns a combined result string, or null if nothing found.
    pub fn searchMemory(self: *KnowledgePipeline, query: []const u8) !?[]const u8 {
        var parts = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (parts.items) |p| self.allocator.free(p);
            parts.deinit();
        }

        // Search memory layers
        if (self.memory) |mem| {
            const mem_results = try mem.search(query);
            defer self.allocator.free(mem_results);
            for (mem_results) |entry| {
                const str = try std.fmt.allocPrint(self.allocator, "[{s}] {s}: {s}", .{ @tagName(entry.layer), entry.key, entry.value });
                try parts.append(str);
            }
        }

        // Search knowledge vault via querier
        const vault_results = try self.querier.query(query, 3);
        defer {
            for (vault_results) |*r| r.deinit(self.allocator);
            self.allocator.free(vault_results);
        }
        for (vault_results) |r| {
            const str = try std.fmt.allocPrint(self.allocator, "[vault] {s}: {s}", .{ r.title, r.snippet });
            try parts.append(str);
        }

        if (parts.items.len == 0) return null;
        return try std.mem.join(self.allocator, "\n", parts.items);
    }

    /// Return memory and source tracker statistics as a formatted string.
    pub fn memoryStats(self: *KnowledgePipeline) !?[]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        writer.print("=== Memory × Knowledge Stats ===\n", .{}) catch return null;
        writer.print("  Tracked sources: {d}\n", .{self.source_tracker.count()}) catch return null;

        if (self.memory) |mem| {
            const ms = mem.getStats();
            writer.print("  Session entries: {d}\n", .{ms.session_count}) catch return null;
            writer.print("  Working entries: {d}\n", .{ms.working_count}) catch return null;
            writer.print("  Insights:        {d}\n", .{ms.insights_count}) catch return null;
            writer.print("  Project entries: {d}\n", .{ms.project_count}) catch return null;
            writer.print("  Total:           {d}\n", .{ms.total}) catch return null;
            writer.print("  Avg confidence:  {d:.2}\n", .{ms.avg_confidence}) catch return null;
            writer.print("  Low confidence:  {d}\n", .{ms.low_confidence_count}) catch return null;
        } else {
            writer.print("  Memory: not initialized\n", .{}) catch return null;
        }

        return buf.toOwnedSlice() catch return null;
    }

    /// Check if a path should be skipped during scanning.
    fn shouldSkip(_: *const KnowledgePipeline, path: []const u8) bool {
        // Skip hidden directories (starting with .)
        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |component| {
            if (component.len > 0 and component[0] == '.') return true;
        }
        // Skip common build/cache/output directories
        const skip_prefixes = [_][]const u8{
            "zig-cache",
            "zig-out",
            "node_modules",
            ".git",
            ".cache",
            "target",
            "dist",
            "build",
        };
        for (skip_prefixes) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return true;
            if (std.mem.indexOf(u8, path, prefix)) |pos| {
                if (pos > 0 and path[pos - 1] == '/') return true;
            }
        }
        return false;
    }
};

// ── Tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "KnowledgePipeline init/deinit" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    try testing.expect(pipeline.initialized);
    try testing.expectEqual(@as(u32, 0), pipeline.pipeline_stats.files_scanned);
    try testing.expectEqual(@as(u32, 0), pipeline.pipeline_stats.files_indexed);
}

test "KnowledgePipeline stats returns zero initially" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    const s = pipeline.stats();
    try testing.expectEqual(@as(u32, 0), s.files_scanned);
    try testing.expectEqual(@as(u32, 0), s.files_indexed);
    try testing.expectEqual(@as(u32, 0), s.files_skipped);
    try testing.expectEqual(@as(u32, 0), s.files_errored);
    try testing.expectEqual(@as(u32, 0), s.vault_nodes);
    try testing.expectEqual(@as(u32, 0), s.graph_nodes);
    try testing.expectEqual(@as(u32, 0), s.graph_edges);
    try testing.expectEqual(@as(u32, 0), s.communities);
    try testing.expectEqual(@as(u32, 0), s.memory_entries);
    try testing.expectEqual(@as(u32, 0), s.insights_count);
    try testing.expectEqual(@as(u32, 0), s.tracked_sources);
}

test "KnowledgePipeline shouldSkip filters hidden and build dirs" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    try testing.expect(pipeline.shouldSkip(".hidden/file.zig"));
    try testing.expect(pipeline.shouldSkip("src/.hidden/file.zig"));
    try testing.expect(pipeline.shouldSkip("zig-cache/file.zig"));
    try testing.expect(pipeline.shouldSkip("zig-out/bin/app"));
    try testing.expect(pipeline.shouldSkip("node_modules/pkg/index.js"));
    try testing.expect(pipeline.shouldSkip(".git/config"));

    try testing.expect(!pipeline.shouldSkip("src/main.zig"));
    try testing.expect(!pipeline.shouldSkip("lib/utils.zig"));
    try testing.expect(!pipeline.shouldSkip("build.zig"));
}

test "KnowledgePipeline indexFiles indexes specific paths" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);

    try testing.expect(pipeline.pipeline_stats.files_indexed >= 2);
    try testing.expect(pipeline.pipeline_stats.graph_nodes > 0);
    try testing.expect(pipeline.pipeline_stats.graph_edges > 0);
}

test "KnowledgePipeline indexGraphToVault bridges graph nodes" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();

    // Should have vault nodes from both file ingestion and graph node ingestion
    try testing.expect(pipeline.pipeline_stats.vault_nodes > 0);
}

test "KnowledgePipeline buildContext returns null when no files indexed" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const result = try pipeline.buildContext(null, 1000);
    try testing.expect(result == null);
}

test "KnowledgePipeline buildContext returns context when files indexed" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();

    const ctx = try pipeline.buildContext(null, 2000);
    try testing.expect(ctx != null);
    if (ctx) |c| {
        defer testing.allocator.free(c);
        try testing.expect(std.mem.indexOf(u8, c, "Codebase Knowledge Graph") != null);
        try testing.expect(c.len > 0);
    }
}

test "KnowledgePipeline buildContext with query" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();

    const ctx = try pipeline.buildContext("GraphNode", 2000);
    try testing.expect(ctx != null);
    if (ctx) |c| {
        defer testing.allocator.free(c);
        try testing.expect(c.len > 0);
    }
}

test "KnowledgePipeline scanProject indexes src directory" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    try pipeline.scanProject("src", 5);

    const s = pipeline.pipeline_stats;
    // Should have scanned and indexed some files
    try testing.expect(s.files_scanned > 0);
    try testing.expect(s.files_indexed > 0);
    try testing.expect(s.files_indexed <= 5);
    try testing.expect(s.graph_nodes > 0);
}

test "KnowledgePipeline init with project_dir creates memory" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, "/tmp/crushcode-test-mem");
    defer pipeline.deinit();
    try testing.expect(pipeline.initialized);
    try testing.expect(pipeline.memory != null);
    try testing.expectEqual(@as(u32, 0), pipeline.source_tracker.count());
}

test "KnowledgePipeline init with null has no memory" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    try testing.expect(pipeline.initialized);
    try testing.expect(pipeline.memory == null);
}

test "KnowledgePipeline syncVaultToMemory with no memory is no-op" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    // Should not crash — graceful degradation
    try pipeline.syncVaultToMemory();
}

test "KnowledgePipeline syncMemoryInsightsToVault with no memory is no-op" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    try pipeline.syncMemoryInsightsToVault();
}

test "KnowledgePipeline distillMemory with no memory returns 0" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    const count = try pipeline.distillMemory();
    try testing.expectEqual(@as(usize, 0), count);
}

test "KnowledgePipeline searchMemory with no memory and no vault returns null" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    const result = try pipeline.searchMemory("test");
    try testing.expect(result == null);
}

test "KnowledgePipeline memoryStats with no memory shows not initialized" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();
    const result = try pipeline.memoryStats();
    if (result) |r| {
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "not initialized") != null);
    }
}

test "KnowledgePipeline syncVaultToMemory bridges vault nodes to working memory" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, "/tmp/crushcode-test-mem");
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();

    try testing.expect(pipeline.vault.count() > 0);
    try pipeline.syncVaultToMemory();

    const mem = pipeline.memory.?;
    try testing.expect(mem.working_entries.items.len > 0);
    try testing.expect(pipeline.source_tracker.count() > 0);
}

test "KnowledgePipeline searchMemory finds entries across memory and vault" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, "/tmp/crushcode-test-mem");
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();
    try pipeline.syncVaultToMemory();

    const result = try pipeline.searchMemory("graph");
    try testing.expect(result != null);
    if (result) |r| {
        defer testing.allocator.free(r);
        try testing.expect(r.len > 0);
    }
}

test "KnowledgePipeline stats includes memory and tracker data" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, "/tmp/crushcode-test-mem");
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
    };
    pipeline.indexFiles(&files);
    try pipeline.indexGraphToVault();
    try pipeline.syncVaultToMemory();

    const s = pipeline.stats();
    try testing.expect(s.memory_entries > 0);
    try testing.expect(s.tracked_sources > 0);
}

// ── Graph Intelligence Tests ──────────────────────────────────

test "KnowledgePipeline computeInsights returns valid insights" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);

    var insights = try pipeline.computeInsights();
    defer insights.deinit(testing.allocator);

    // Should have ranked nodes
    try testing.expect(insights.top_ranked.len > 0);
    // Top ranked should have valid scores
    if (insights.top_ranked.len > 0) {
        try testing.expect(insights.top_ranked[0].rank > 0.0);
        try testing.expect(insights.top_ranked[0].id.len > 0);
    }
    // Should have clusters (file-based grouping)
    try testing.expect(insights.clusters.len > 0);
    // Total cluster nodes should be > 0
    var total_cluster_nodes: u32 = 0;
    for (insights.clusters) |ci| {
        total_cluster_nodes += ci.node_count;
    }
    try testing.expect(total_cluster_nodes > 0);
}

test "KnowledgePipeline getTopRankedNodes returns sorted results" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);

    const ranked = try pipeline.getTopRankedNodes(3);
    defer {
        for (ranked) |*rn| {
            var mut = rn;
            mut.deinit(testing.allocator);
        }
        testing.allocator.free(ranked);
    }

    try testing.expect(ranked.len > 0);
    try testing.expect(ranked.len <= 3);

    // Verify descending order
    for (ranked, 0..) |rn, i| {
        if (i > 0) {
            try testing.expect(rn.rank <= ranked[i - 1].rank);
        }
        try testing.expect(rn.rank > 0.0);
    }
}

test "KnowledgePipeline getBridgeNodes returns articulation points" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
        "src/graph/algorithms.zig",
    };
    pipeline.indexFiles(&files);

    const bridges = try pipeline.getBridgeNodes();
    defer {
        for (bridges) |id| testing.allocator.free(id);
        testing.allocator.free(bridges);
    }

    // Bridges may or may not exist depending on graph structure,
    // but the call should succeed without crashing
    for (bridges) |id| {
        try testing.expect(id.len > 0);
    }
}

test "KnowledgePipeline printInsights doesn't crash" {
    var pipeline = try KnowledgePipeline.init(testing.allocator, null);
    defer pipeline.deinit();

    // Test with empty graph — should not crash
    pipeline.printInsights();

    // Test with indexed files
    const files = [_][]const u8{
        "src/graph/types.zig",
        "src/graph/graph.zig",
    };
    pipeline.indexFiles(&files);

    // Should not crash with data
    pipeline.printInsights();
}
