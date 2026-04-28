//! Semantic search via embedding-based similarity.
//!
//! Indexes source files by generating embeddings using the configured AI
//! provider's /embeddings endpoint (OpenAI-compatible). Returns top-K
//! most relevant files for a natural language query.
//!
//! Flow:
//!   1. Walk project tree → chunk files (max 512 tokens / ~2048 chars)
//!   2. Batch embed chunks via /embeddings API
//!   3. Cache embeddings in memory for session duration
//!   4. On query: embed query → cosine similarity → return top-K files

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const http_client = @import("http_client");

const Allocator = std.mem.Allocator;

/// Dimension of embedding vectors. Most models use 1536 (OpenAI text-embedding-3-small)
/// or 768 (nomic-embed-text). We normalize to a fixed size.
const embed_dim: usize = 1536;

/// Maximum chunk size in bytes (roughly 512 tokens).
const max_chunk_bytes: usize = 2048;

/// A file chunk for indexing.
const Chunk = struct {
    path: []const u8,
    text: []const u8,
};

/// Maximum number of files to index in one pass.
const max_index_files: usize = 200;

/// Directories to skip when indexing.
const skip_dirs = &[_][]const u8{ ".git", "node_modules", "zig-out", "zig-cache", "target", "vendor", "__pycache__", ".venv", "dist", "build", ".next", ".cache" };

/// File extensions to index (source code).
const indexable_exts = &[_][]const u8{
    ".zig",   ".rs",  ".go",  ".py",  ".ts",  ".tsx",  ".js",   ".jsx",
    ".java",  ".c",   ".cpp", ".h",   ".hpp", ".cs",   ".rb",   ".php",
    ".swift", ".kt",  ".scala", ".hs", ".ex",  ".exs",  ".erl",  ".clj",
    ".toml",  ".yaml", ".yml", ".json", ".md",  ".txt",  ".sh",  ".bash",
    ".sql",   ".html", ".css", ".scss", ".sass", ".less", ".vue",  ".svelte",
};

/// A chunk of a file with its embedding vector.
pub const EmbeddingEntry = struct {
    file_path: []const u8,
    chunk_text: []const u8,
    vector: [embed_dim]f32,
};

/// Query result with similarity score.
pub const SearchResult = struct {
    file_path: []const u8,
    score: f64,
    snippet: []const u8,
};

/// In-memory semantic index.
pub const SemanticIndex = struct {
    allocator: Allocator,
    entries: array_list_compat.ArrayList(EmbeddingEntry),
    indexed_files: std.StringHashMap(bool),

    pub fn init(allocator: Allocator) SemanticIndex {
        return .{
            .allocator = allocator,
            .entries = array_list_compat.ArrayList(EmbeddingEntry).init(allocator),
            .indexed_files = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *SemanticIndex) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.file_path);
            self.allocator.free(entry.chunk_text);
        }
        self.entries.deinit();
        var iter = self.indexed_files.iterator();
        while (iter.next()) |item| self.allocator.free(item.key_ptr.*);
        self.indexed_files.deinit();
    }

    /// Index all source files under `root_path`.
    pub fn indexProject(self: *SemanticIndex, root_path: []const u8, api_base: []const u8, api_key: []const u8, embed_model: []const u8) !usize {
        var chunks = array_list_compat.ArrayList(Chunk).init(self.allocator);
        defer {
            for (chunks.items) |c| {
                self.allocator.free(c.path);
                self.allocator.free(c.text);
            }
            chunks.deinit();
        }

        // Walk the project tree and collect chunks
        var file_count: usize = 0;
        self.walkAndChunk(root_path, &chunks, &file_count) catch {};

        if (chunks.items.len == 0) return 0;

        // Batch embed: send up to 64 chunks per API call
        var i: usize = 0;
        var embedded: usize = 0;
        while (i < chunks.items.len) {
            const batch_end = @min(i + 64, chunks.items.len);
            const batch = chunks.items[i..batch_end];

            const vectors = self.embedBatch(
                batch,
                api_base,
                api_key,
                embed_model,
            ) catch {
                // Skip failed batches — don't abort the whole index
                i = batch_end;
                continue;
            };

            // Store entries (ownership transferred to self)
            for (batch, 0..) |chunk, j| {
                if (j < vectors.len) {
                    const path_copy = try self.allocator.dupe(u8, chunk.path);
                    const text_copy = try self.allocator.dupe(u8, chunk.text);
                    var entry = EmbeddingEntry{
                        .file_path = path_copy,
                        .chunk_text = text_copy,
                        .vector = undefined,
                    };
                    const copy_len = @min(vectors[j].len, embed_dim);
                    @memset(&entry.vector, 0);
                    for (vectors[j][0..copy_len], 0..) |v, k| {
                        entry.vector[k] = v;
                    }
                    try self.entries.append(entry);
                    embedded += 1;
                }
            }
            self.allocator.free(vectors);

            i = batch_end;
        }

        return embedded;
    }

    /// Search for the most relevant files to a query.
    pub fn search(self: *SemanticIndex, query: []const u8, api_base: []const u8, api_key: []const u8, embed_model: []const u8, top_k: usize) ![]SearchResult {
        // Embed the query
        const query_vector = self.embedSingle(query, api_base, api_key, embed_model) catch {
            return &[_]SearchResult{};
        };
        defer self.allocator.free(query_vector);

        // Compute cosine similarity with all entries
        var scored = array_list_compat.ArrayList(SearchResult).init(self.allocator);
        defer scored.deinit();

        // Track best score per file (avoid duplicates)
        var best_scores = std.StringHashMap(f64).init(self.allocator);
        defer best_scores.deinit();
        var best_snippets = std.StringHashMap([]const u8).init(self.allocator);
        defer best_snippets.deinit();

        for (self.entries.items) |entry| {
            const sim = cosineSimilarity(query_vector, &entry.vector);
            const existing = best_scores.get(entry.file_path);
            if (existing == null or sim > existing.?) {
                best_scores.put(entry.file_path, sim) catch {};
                best_snippets.put(entry.file_path, entry.chunk_text) catch {};
            }
        }

        // Collect all scored files
        var iter = best_scores.iterator();
        while (iter.next()) |item| {
            try scored.append(.{
                .file_path = item.key_ptr.*,
                .score = item.value_ptr.*,
                .snippet = best_snippets.get(item.key_ptr.*) orelse "",
            });
        }

        // Sort by score descending
        std.sort.insertion(SearchResult, scored.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Return top-K
        const k = @min(top_k, scored.items.len);
        return scored.items[0..k];
    }

    /// Walk a directory tree and chunk files.
    fn walkAndChunk(self: *SemanticIndex, root: []const u8, chunks: anytype, file_count: *usize) !void {
        var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
        defer dir.close();

        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (file_count.* >= max_index_files) break;

            if (entry.kind == .directory) {
                // Skip hidden and known non-source dirs
                if (entry.name[0] == '.') continue;
                var should_skip = false;
                for (skip_dirs) |sd| {
                    if (std.mem.eql(u8, entry.name, sd)) {
                        should_skip = true;
                        break;
                    }
                }
                if (should_skip) continue;

                const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, entry.name });
                defer self.allocator.free(sub_path);
                try self.walkAndChunk(sub_path, chunks, file_count);
            } else if (entry.kind == .file) {
                if (!isIndexable(entry.name)) continue;

                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, entry.name });
                errdefer self.allocator.free(full_path);

                // Skip already indexed
                if (self.indexed_files.contains(full_path)) {
                    self.allocator.free(full_path);
                    continue;
                }

                // Read file and chunk
                const file = dir.openFile(entry.name, .{}) catch {
                    self.allocator.free(full_path);
                    continue;
                };
                defer file.close();

                const contents = file.readToEndAlloc(self.allocator, 512 * 1024) catch {
                    self.allocator.free(full_path);
                    continue;
                };
                defer self.allocator.free(contents);

                // Chunk the file
                var offset: usize = 0;
                while (offset < contents.len) {
                    const end = @min(offset + max_chunk_bytes, contents.len);
                    const chunk_data = contents[offset..end];

                    const path_copy = try self.allocator.dupe(u8, full_path);
                    const text_copy = try self.allocator.dupe(u8, chunk_data);
                    try chunks.append(.{ .path = path_copy, .text = text_copy });

                    offset = end;
                }

                const owned_path = try self.allocator.dupe(u8, full_path);
                try self.indexed_files.put(owned_path, true);
                self.allocator.free(full_path);
                file_count.* += 1;
            }
        }
    }

    /// Embed a single text string. Returns owned slice of f32.
    fn embedSingle(self: *SemanticIndex, text: []const u8, api_base: []const u8, api_key: []const u8, model: []const u8) ![]f32 {
        // Build request body: {"model":"...","input":"..."}
        var body = array_list_compat.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.writeAll("{\"model\":\"");
        try w.writeAll(model);
        try w.writeAll("\",\"input\":\"");
        writeJsonEscaped(w, text) catch {};
        try w.writeAll("\"}");

        const url = try std.fmt.allocPrint(self.allocator, "{s}/embeddings", .{api_base});
        defer self.allocator.free(url);

        const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth },
        };

        const response = try http_client.httpPost(self.allocator, url, headers, body.items);
        defer self.allocator.free(response.body);

        // Parse first embedding from response
        return self.parseEmbedding(response.body);
    }

    /// Embed a batch of texts. Returns owned slice of f32 slices.
    /// Not yet implemented — falls back to single embed.
    fn embedBatch(_: *SemanticIndex, _: []const Chunk, _: []const u8, _: []const u8, _: []const u8) ![][]f32 {
        return error.NotImplemented;
    }

    /// Parse embedding vector from /embeddings response JSON.
    fn parseEmbedding(self: *SemanticIndex, json: []const u8) ![]f32 {
        // Find the "embedding" array in the response
        const emb_key = "\"embedding\"";
        const emb_pos = std.mem.indexOf(u8, json, emb_key) orelse return error.ParseError;
        const after = json[emb_pos + emb_key.len ..];

        // Find the opening bracket
        var i: usize = 0;
        while (i < after.len and after[i] != '[') i += 1;
        if (i >= after.len) return error.ParseError;
        i += 1; // skip '['

        // Parse comma-separated floats
        var values = array_list_compat.ArrayList(f32).init(self.allocator);
        while (i < after.len and after[i] != ']') {
            // Skip whitespace and commas
            while (i < after.len and (after[i] == ' ' or after[i] == ',' or after[i] == '\n' or after[i] == '\r' or after[i] == '\t')) i += 1;
            if (i >= after.len or after[i] == ']') break;

            // Parse float
            const start = i;
            while (i < after.len and after[i] != ',' and after[i] != ']' and after[i] != ' ') i += 1;
            const num_str = after[start..i];
            const val = std.fmt.parseFloat(f32, num_str) catch 0.0;
            try values.append(val);
        }

        return values.toOwnedSlice();
    }
};

/// Compute cosine similarity between two vectors.
pub fn cosineSimilarity(a: []const f32, b: *const [embed_dim]f32) f64 {
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;

    const len = @min(a.len, embed_dim);
    for (0..len) |i| {
        const fa: f64 = @floatCast(a[i]);
        const fb: f64 = @floatCast(b[i]);
        dot += fa * fb;
        norm_a += fa * fa;
        norm_b += fb * fb;
    }

    const denom = std.math.sqrt(norm_a) * std.math.sqrt(norm_b);
    if (denom == 0) return 0;
    return dot / denom;
}

/// Check if a filename has an indexable extension.
fn isIndexable(name: []const u8) bool {
    for (indexable_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Write JSON-escaped string.
fn writeJsonEscaped(w: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
}
