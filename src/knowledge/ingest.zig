const std = @import("std");
const array_list_compat = @import("array_list_compat");
const schema = @import("knowledge_schema");

const Allocator = std.mem.Allocator;

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
