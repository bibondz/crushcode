// Consolidated knowledge operations — ingest and query.
// Originally two separate files, merged for organizational clarity.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");

const Allocator = std.mem.Allocator;

// ============================================================
// Ingest
// ============================================================

/// Result of an ingest operation
pub const IngestResult = struct {
    nodes_created: u32 = 0,
    nodes_updated: u32 = 0,
    nodes_skipped: u32 = 0,
    errors: u32 = 0,
};

/// Processes source files and graph nodes into structured knowledge nodes.
///
/// Reference: Second-brain ingest patterns (F48)
pub const KnowledgeIngester = struct {
    allocator: Allocator,
    vault: *schema.KnowledgeVault,

    pub fn init(allocator: Allocator, vault: *schema.KnowledgeVault) KnowledgeIngester {
        return KnowledgeIngester{
            .allocator = allocator,
            .vault = vault,
        };
    }

    /// Ingest a single file into the vault as a KnowledgeNode
    pub fn ingestFile(self: *KnowledgeIngester, file_path: []const u8) !IngestResult {
        var result = IngestResult{};

        // Read file content
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch {
            result.errors += 1;
            return result;
        };

        // Generate node ID from file path
        const id = try self.pathToId(file_path);

        // Check if node already exists
        if (self.vault.getNode(id)) |existing| {
            existing.deinit();
            // We need to remove and re-add since the struct is owned by vault
            _ = self.vault.removeNode(id);
            result.nodes_updated += 1;
        }

        // Extract title from first `# ` heading or filename
        const title = try self.extractTitle(content, file_path);
        defer if (title.len > 0 and !std.mem.eql(u8, title, self.filenameFromPath(file_path))) {
            // title was allocated only if it came from content
        } else {};

        // Create the node
        const node = try self.allocator.create(schema.KnowledgeNode);
        node.* = schema.KnowledgeNode.init(self.allocator, id, title, content, .file) catch {
            self.allocator.destroy(node);
            self.allocator.free(id);
            result.errors += 1;
            return result;
        };

        // Set source path
        node.setSourcePath(file_path) catch {};

        // Extract tags from YAML frontmatter or `tags:` line
        try self.extractTags(node, content);

        // Set timestamps from file mtime (use current time as fallback)
        node.updated_at = std.time.timestamp();

        // Add to vault
        self.vault.addNode(node) catch {
            node.deinit();
            self.allocator.destroy(node);
            result.errors += 1;
            return result;
        };

        if (result.nodes_updated == 0) {
            result.nodes_created += 1;
        }

        return result;
    }

    /// Ingest all .md, .txt, .zig files in a directory
    pub fn ingestDirectory(self: *KnowledgeIngester, dir_path: []const u8) !IngestResult {
        var total = IngestResult{};

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            total.errors += 1;
            return total;
        };
        defer dir.close();

        var walker = dir.walk(self.allocator) catch {
            total.errors += 1;
            return total;
        };
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const name = entry.basename;
            const is_ingestible = std.mem.endsWith(u8, name, ".md") or
                std.mem.endsWith(u8, name, ".txt") or
                std.mem.endsWith(u8, name, ".zig");
            if (!is_ingestible) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.path });
            const file_result = self.ingestFile(full_path) catch {
                self.allocator.free(full_path);
                total.errors += 1;
                continue;
            };
            self.allocator.free(full_path);

            total.nodes_created += file_result.nodes_created;
            total.nodes_updated += file_result.nodes_updated;
            total.nodes_skipped += file_result.nodes_skipped;
            total.errors += file_result.errors;
        }

        return total;
    }

    /// Convert a graph GraphNode into a KnowledgeNode
    pub fn ingestGraphNode(self: *KnowledgeIngester, graph_node_id: []const u8, graph_node_name: []const u8, graph_node_type: []const u8, file_path: []const u8, doc_comment: ?[]const u8) !void {
        const id = try std.fmt.allocPrint(self.allocator, "graph.{s}", .{graph_node_id});

        const content = if (doc_comment) |doc|
            try std.fmt.allocPrint(self.allocator, "{s} ({s}) from {s}\n{s}", .{ graph_node_name, graph_node_type, file_path, doc })
        else
            try std.fmt.allocPrint(self.allocator, "{s} ({s}) from {s}", .{ graph_node_name, graph_node_type, file_path });

        const node = try self.allocator.create(schema.KnowledgeNode);
        node.* = schema.KnowledgeNode.init(self.allocator, id, graph_node_name, content, .graph) catch {
            self.allocator.destroy(node);
            self.allocator.free(id);
            if (doc_comment != null) self.allocator.free(content);
            return;
        };
        node.setSourcePath(file_path) catch {};

        // Add type as tag
        node.addTag(graph_node_type) catch {};

        self.vault.addNode(node) catch {
            node.deinit();
            self.allocator.destroy(node);
        };
    }

    // --- Private helpers ---

    /// Convert file path to a unique node ID
    fn pathToId(self: *KnowledgeIngester, file_path: []const u8) ![]const u8 {
        // Replace path separators with dots for a flat ID
        const result = try self.allocator.alloc(u8, file_path.len);
        for (file_path, 0..) |c, i| {
            result[i] = if (c == '/' or c == '\\') '.' else c;
        }
        return result;
    }

    /// Extract title from first `# ` heading or fallback to filename
    fn extractTitle(self: *KnowledgeIngester, content: []const u8, file_path: []const u8) ![]const u8 {
        // Skip YAML frontmatter if present
        var search_start: usize = 0;
        if (content.len > 3 and std.mem.startsWith(u8, content, "---")) {
            if (std.mem.indexOfPos(u8, content, 3, "---")) |end_frontmatter| {
                search_start = end_frontmatter + 3;
            }
        }

        // Look for first `# ` heading
        var line_iter = std.mem.splitScalar(u8, content[search_start..], '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') {
                const title = std.mem.trimLeft(u8, trimmed[1..], " \t");
                if (title.len > 0) {
                    return try self.allocator.dupe(u8, title);
                }
            }
            // Only check the first non-empty, non-frontmatter line for heading
            break;
        }

        // Fallback to filename without extension
        return try self.allocator.dupe(u8, self.filenameFromPath(file_path));
    }

    /// Extract tags from YAML frontmatter (between `---` markers) or `tags:` line
    fn extractTags(self: *KnowledgeIngester, node: *schema.KnowledgeNode, content: []const u8) !void {
        // Check for YAML frontmatter
        if (content.len > 3 and std.mem.startsWith(u8, content, "---")) {
            if (std.mem.indexOfPos(u8, content, 3, "---")) |end_frontmatter| {
                const frontmatter = content[3..end_frontmatter];
                try self.parseTagsFromSection(node, frontmatter);
                return;
            }
        }

        // Check for standalone `tags:` line anywhere in first few lines
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var line_count: usize = 0;
        while (line_iter.next()) |line| {
            line_count += 1;
            if (line_count > 20) break; // Only scan first 20 lines
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "tags:")) {
                const tags_part = line[5..]; // skip "tags:"
                try self.parseTagsLine(node, tags_part);
                break;
            }
        }
    }

    /// Parse tags from a section (frontmatter or tags line)
    fn parseTagsFromSection(self: *KnowledgeIngester, node: *schema.KnowledgeNode, section: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, section, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "tags:") or std.mem.startsWith(u8, trimmed, "Tags:")) {
                const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const tags_part = trimmed[colon_pos + 1 ..];
                try self.parseTagsLine(node, tags_part);
                return;
            }
        }
    }

    /// Parse a comma-separated or bracket-enclosed tags line
    fn parseTagsLine(_: *KnowledgeIngester, node: *schema.KnowledgeNode, tags_part: []const u8) !void {
        const cleaned = std.mem.trim(u8, tags_part, " \t\r");
        if (cleaned.len == 0) return;

        // Handle [tag1, tag2] format
        const inner = if (cleaned[0] == '[' and cleaned.len > 1 and cleaned[cleaned.len - 1] == ']')
            cleaned[1 .. cleaned.len - 1]
        else
            cleaned;

        var tag_iter = std.mem.splitAny(u8, inner, ", ");
        while (tag_iter.next()) |tag| {
            const t = std.mem.trim(u8, tag, " \t\r\"'");
            if (t.len > 0) {
                try node.addTag(t);
            }
        }
    }

    /// Get filename without extension from a path
    fn filenameFromPath(_: *KnowledgeIngester, file_path: []const u8) []const u8 {
        const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
        const filename = if (last_slash > 0) file_path[last_slash + 1 ..] else file_path;
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
        return filename[0..dot];
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "KnowledgeIngester ingestFile" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();
    var ingester = KnowledgeIngester.init(testing.allocator, &vault);

    // Ingest this file itself as a test
    const result = try ingester.ingestFile("src/knowledge/schema.zig");
    try testing.expect(result.nodes_created == 1 or result.nodes_updated == 1);
    try testing.expectEqual(@as(u32, 0), result.errors);
    try testing.expect(vault.getNode("src.knowledge.schema.zig") != null);
}

test "KnowledgeIngester extractTitle from heading" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();
    var ingester = KnowledgeIngester.init(testing.allocator, &vault);

    // Create a temp file with a heading
    const content = "# My Test Title\n\nSome content here";
    const tmp_path = "/tmp/test_knowledge_ingest.md";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll(content);
    tmp_file.close();

    const result = try ingester.ingestFile(tmp_path);
    try testing.expect(result.nodes_created >= 1);

    const node = vault.getNode("tmp.test_knowledge_ingest.md").?;
    try testing.expectEqualStrings("My Test Title", node.title);

    // Cleanup
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "KnowledgeIngester ingestGraphNode" {
    var vault = try schema.KnowledgeVault.init(testing.allocator, "/test/vault");
    defer vault.deinit();
    var ingester = KnowledgeIngester.init(testing.allocator, &vault);

    try ingester.ingestGraphNode("mod.func1", "func1", "function", "src/test.zig", "Does something useful");
    const node = vault.getNode("graph.mod.func1");
    try testing.expect(node != null);
    try testing.expectEqualStrings("func1", node.?.title);
    try testing.expectEqual(@as(usize, 1), node.?.tags.items.len);
}

// ============================================================
// Query
// ============================================================

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
