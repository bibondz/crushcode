const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const Allocator = std.mem.Allocator;

/// Classification of user query intent.
pub const QueryType = enum {
    code_search,
    file_edit,
    question,
    refactor,
    debug,
    general,
};

/// Parsed intent extracted from a user query string.
pub const QueryIntent = struct {
    query_type: QueryType,
    mentioned_files: [][]const u8,
    mentioned_symbols: [][]const u8,
    keywords: [][]const u8,
    language_hint: ?[]const u8,

    pub fn deinit(self: *QueryIntent, allocator: Allocator) void {
        for (self.mentioned_files) |f| allocator.free(f);
        allocator.free(self.mentioned_files);
        for (self.mentioned_symbols) |s| allocator.free(s);
        allocator.free(self.mentioned_symbols);
        for (self.keywords) |k| allocator.free(k);
        allocator.free(self.keywords);
        if (self.language_hint) |lh| allocator.free(lh);
    }
};

/// Analyze a user query and extract structured intent.
pub fn extractQueryIntent(allocator: Allocator, query: []const u8) !QueryIntent {
    var mentioned_files = array_list_compat.ArrayList([]const u8).init(allocator);
    var mentioned_symbols = array_list_compat.ArrayList([]const u8).init(allocator);
    var keywords = array_list_compat.ArrayList([]const u8).init(allocator);
    var language_hint: ?[]const u8 = null;

    // Classify query type by keyword matching
    const query_type = classifyQueryType(query);

    // Extract file paths
    try extractFilePaths(allocator, query, &mentioned_files);

    // Extract PascalCase symbols
    try extractSymbols(allocator, query, &mentioned_symbols);

    // Detect language
    language_hint = detectLanguage(allocator, query) catch null;

    // Extract keywords (filtered stop words)
    try extractKeywords(allocator, query, &keywords);

    return QueryIntent{
        .query_type = query_type,
        .mentioned_files = try mentioned_files.toOwnedSlice(),
        .mentioned_symbols = try mentioned_symbols.toOwnedSlice(),
        .keywords = try keywords.toOwnedSlice(),
        .language_hint = language_hint,
    };
}

fn toLowerAlloc(allocator: Allocator, src: []const u8) ![]const u8 {
    const buf = try allocator.dupe(u8, src);
    for (buf) |*c| c.* = std.ascii.toLower(c.*);
    return buf;
}

fn classifyQueryType(query: []const u8) QueryType {
    const q = toLowerAlloc(std.heap.page_allocator, query) catch return .general;
    defer std.heap.page_allocator.free(q);

    const debug_words = [_][]const u8{ "fix", "bug", "error", "crash", "panic" };
    for (debug_words) |w| {
        if (containsWord(q, w)) return .debug;
    }
    const refactor_words = [_][]const u8{ "refactor", "rename", "move", "restructure" };
    for (refactor_words) |w| {
        if (containsWord(q, w)) return .refactor;
    }
    const edit_words = [_][]const u8{ "edit", "change", "update", "modify", "implement", "add" };
    for (edit_words) |w| {
        if (containsWord(q, w)) return .file_edit;
    }
    const question_words = [_][]const u8{ "what", "how", "why", "explain", "where", "describe" };
    for (question_words) |w| {
        if (containsWord(q, w)) return .question;
    }
    const search_words = [_][]const u8{ "find", "search", "where is", "grep", "locate" };
    for (search_words) |w| {
        if (std.mem.indexOf(u8, q, w) != null) return .code_search;
    }
    return .general;
}

/// Check if a word appears as a standalone token in the text.
fn containsWord(text: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, word)) |idx| {
        const after = idx + word.len;
        const before_ok = idx == 0 or !std.ascii.isAlphanumeric(text[idx - 1]);
        const after_ok = after >= text.len or !std.ascii.isAlphanumeric(text[after]);
        if (before_ok and after_ok) return true;
        start = after;
    }
    return false;
}

fn extractFilePaths(allocator: Allocator, query: []const u8, list: *array_list_compat.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < query.len) {
        // Look for potential file path start: / or ./ or alpha+/
        if (query[i] == '/' or query[i] == '.' or std.ascii.isAlphanumeric(query[i])) {
            const candidate = scanFilePath(query, i);
            if (candidate.len > 3 and isValidFilePath(candidate)) {
                const copy = try allocator.dupe(u8, candidate);
                try list.append(copy);
                i += candidate.len;
                continue;
            }
        }
        i += 1;
    }
}

fn scanFilePath(query: []const u8, start: usize) []const u8 {
    var end = start;
    // Allow ./ prefix
    if (end < query.len and query[end] == '.') end += 1;
    if (end < query.len and query[end] == '/') end += 1;
    // Must have consumed at least one char
    while (end < query.len and (std.ascii.isAlphanumeric(query[end]) or query[end] == '/' or query[end] == '_' or query[end] == '-' or query[end] == '.')) {
        end += 1;
    }
    return query[start..end];
}

fn isValidFilePath(candidate: []const u8) bool {
    // Must contain a /
    if (std.mem.indexOfScalar(u8, candidate, '/') == null) return false;
    // Must end with alphanumeric or common ext chars
    if (candidate.len == 0) return false;
    const last = candidate[candidate.len - 1];
    if (!std.ascii.isAlphanumeric(last) and last != 'g' and last != 'z') return false;
    // Must have at least one . for extension (or contain src/)
    _ = std.mem.indexOfScalar(u8, candidate, '.') orelse return false;
    return true;
}

fn extractSymbols(allocator: Allocator, query: []const u8, list: *array_list_compat.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < query.len) {
        if (std.ascii.isUpper(query[i])) {
            // Scan PascalCase symbol
            var end = i + 1;
            while (end < query.len and (std.ascii.isAlphanumeric(query[end]) or query[end] == '_')) {
                end += 1;
            }
            const symbol = query[i..end];
            if (symbol.len > 2) {
                const copy = try allocator.dupe(u8, symbol);
                try list.append(copy);
            }
            i = end;
        } else {
            i += 1;
        }
    }
}

fn detectLanguage(allocator: Allocator, query: []const u8) !?[]const u8 {
    const lower = try toLowerAlloc(allocator, query);
    defer allocator.free(lower);

    if (std.mem.indexOf(u8, lower, "zig") != null)
        return try allocator.dupe(u8, ".zig");
    if (std.mem.indexOf(u8, lower, "python") != null or std.mem.indexOf(u8, lower, " py ") != null)
        return try allocator.dupe(u8, ".py");
    if (std.mem.indexOf(u8, lower, "rust") != null)
        return try allocator.dupe(u8, ".rs");
    if (std.mem.indexOf(u8, lower, "typescript") != null or std.mem.indexOf(u8, lower, " ts ") != null)
        return try allocator.dupe(u8, ".ts");
    if (std.mem.indexOf(u8, lower, "javascript") != null or std.mem.indexOf(u8, lower, " js ") != null)
        return try allocator.dupe(u8, ".js");
    if (std.mem.indexOf(u8, lower, "golang") != null or std.mem.indexOf(u8, lower, " go ") != null)
        return try allocator.dupe(u8, ".go");
    if (std.mem.indexOf(u8, lower, "java") != null)
        return try allocator.dupe(u8, ".java");
    if (std.mem.indexOf(u8, lower, "c++") != null or std.mem.indexOf(u8, lower, "cpp") != null)
        return try allocator.dupe(u8, ".cpp");
    if (std.mem.indexOf(u8, lower, "ruby") != null)
        return try allocator.dupe(u8, ".rb");
    if (std.mem.indexOf(u8, lower, "swift") != null)
        return try allocator.dupe(u8, ".swift");
    return null;
}

fn extractKeywords(allocator: Allocator, query: []const u8, list: *array_list_compat.ArrayList([]const u8)) !void {
    var words = std.mem.splitSequence(u8, query, " ");
    while (words.next()) |word| {
        const trimmed = std.mem.trim(u8, word, " \t\n\r.,;:!?()[]{}\"'`<>/\\|");
        if (trimmed.len < 2) continue;
        if (isStopWord(trimmed)) continue;
        const lower = try toLowerAlloc(allocator, trimmed);
        try list.append(lower);
    }
}

fn isStopWord(word: []const u8) bool {
    const stops = [_][]const u8{
        "the",   "a",     "an",    "is",    "are",   "was",    "were",  "be",    "been",    "being",
        "have",  "has",   "had",   "do",    "does",  "did",    "will",  "would", "could",   "should",
        "may",   "might", "can",   "shall", "to",    "of",     "in",    "for",   "on",      "with",
        "at",    "by",    "from",  "as",    "into",  "through","during","before","after",   "above",
        "below", "between","out",  "off",   "over",  "under",  "again", "further","then",   "once",
        "here",  "there", "when",  "where", "why",   "how",    "all",   "both",  "each",    "few",
        "more",  "most",  "other", "some",  "such",  "no",     "not",   "only",  "own",     "same",
        "so",    "than",  "too",   "very",  "just",  "because","but",   "and",   "or",      "if",
        "while", "this",  "that",  "these", "those", "it",     "its",   "my",    "your",    "his",
        "her",   "our",   "their", "what",  "which", "who",    "whom",  "me",    "i",
    };
    for (stops) |s| {
        if (std.mem.eql(u8, word, s)) return true;
    }
    return false;
}

/// Score how relevant a file is for a given query intent (0.0 – 1.0).
pub fn scoreQueryRelevance(intent: *const QueryIntent, file_path: []const u8, file_content: []const u8) f64 {
    var raw: f64 = 0.0;

    // Mentioned file bonus
    for (intent.mentioned_files) |mf| {
        if (std.mem.endsWith(u8, file_path, mf) or std.mem.eql(u8, file_path, mf)) {
            raw += 10.0;
            break;
        }
    }

    // Language hint extension match
    if (intent.language_hint) |ext| {
        if (std.mem.endsWith(u8, file_path, ext)) {
            raw += 3.0;
        }
    }

    // Symbol matches
    for (intent.mentioned_symbols) |sym| {
        if (std.mem.indexOf(u8, file_content, sym) != null) {
            raw += 5.0;
        }
    }

    // Keyword matches
    for (intent.keywords) |kw| {
        if (std.mem.indexOf(u8, file_content, kw) != null) {
            raw += 1.0;
        }
    }

    // Cap and normalize
    if (raw > 20.0) raw = 20.0;
    return raw / 20.0;
}

/// Metadata for a candidate file in context selection.
pub const FileInfo = struct {
    path: []const u8,
    content: []const u8,
    estimated_tokens: u32,
};

/// A selected file with its relevance score.
pub const SelectedFile = struct {
    path: []const u8,
    score: f64,
    tokens: u32,
    source: []const u8,
};

/// Result of context file selection.
pub const ContextSelection = struct {
    selected_files: []SelectedFile,
    total_tokens: u64,
    budget_tokens: u32,
    pruned_count: u32,

    pub fn deinit(self: *ContextSelection, allocator: Allocator) void {
        allocator.free(self.selected_files);
    }
};

fn compareFiles(context: void, a: SelectedFile, b: SelectedFile) bool {
    _ = context;
    return a.score > b.score;
}

/// Select the most relevant files for a query within a token budget.
pub fn selectContext(allocator: Allocator, intent: *const QueryIntent, files: []const FileInfo, max_tokens: u32) !ContextSelection {
    var scored = array_list_compat.ArrayList(SelectedFile).init(allocator);
    defer scored.deinit();

    for (files) |f| {
        const sc = scoreQueryRelevance(intent, f.path, f.content);
        const source = determineSource(intent, f.path, f.content);
        try scored.append(.{
            .path = f.path,
            .score = sc,
            .tokens = f.estimated_tokens,
            .source = source,
        });
    }

    // Sort by score descending
    std.sort.pdq(SelectedFile, scored.items, {}, compareFiles);

    // Greedily add until budget exhausted
    var selected = array_list_compat.ArrayList(SelectedFile).init(allocator);
    var total_tokens: u64 = 0;
    var pruned: u32 = 0;

    for (scored.items) |sf| {
        if (total_tokens + sf.tokens <= max_tokens) {
            try selected.append(sf);
            total_tokens += sf.tokens;
        } else {
            pruned += 1;
        }
    }

    return ContextSelection{
        .selected_files = try selected.toOwnedSlice(),
        .total_tokens = total_tokens,
        .budget_tokens = max_tokens,
        .pruned_count = pruned,
    };
}

fn determineSource(intent: *const QueryIntent, file_path: []const u8, file_content: []const u8) []const u8 {
    // Check if file was explicitly mentioned
    for (intent.mentioned_files) |mf| {
        if (std.mem.endsWith(u8, file_path, mf) or std.mem.eql(u8, file_path, mf)) {
            return "mentioned";
        }
    }
    // Check for symbol matches
    for (intent.mentioned_symbols) |sym| {
        if (std.mem.indexOf(u8, file_content, sym) != null) {
            return "symbol_match";
        }
    }
    // Check for keyword matches
    for (intent.keywords) |kw| {
        if (std.mem.indexOf(u8, file_content, kw) != null) {
            return "keyword_match";
        }
    }
    return "structural";
}

/// Format a human-readable summary of the context selection.
pub fn formatContextSummary(allocator: Allocator, sel: *const ContextSelection) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const budget_pct: u32 = if (sel.budget_tokens > 0)
        @intCast(@divTrunc(sel.total_tokens * 100, sel.budget_tokens))
    else
        0;

    try buf.writer().print("Context: {d} files selected ({d} tokens, {d}% budget).", .{
        sel.selected_files.len,
        sel.total_tokens,
        budget_pct,
    });

    if (sel.selected_files.len > 0) {
        try buf.appendSlice(" Top:");
        const limit = @min(sel.selected_files.len, 3);
        for (sel.selected_files[0..limit]) |sf| {
            // Extract filename from path
            const fname = std.mem.lastIndexOfScalar(u8, sf.path, '/') orelse 0;
            const basename = if (fname > 0) sf.path[fname + 1 ..] else sf.path;
            try buf.writer().print(" {s} ({d:.2}),", .{ basename, sf.score });
        }
        // Remove trailing comma
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ',') {
            _ = buf.pop();
        }
    }

    if (sel.pruned_count > 0) {
        try buf.writer().print(" Pruned: {d} low-relevance files.", .{sel.pruned_count});
    }

    return try buf.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classifyQueryType - debug keywords" {
    try testing.expectEqual(QueryType.debug, classifyQueryType("fix the bug in main.zig"));
    try testing.expectEqual(QueryType.debug, classifyQueryType("there is an error in parsing"));
    try testing.expectEqual(QueryType.debug, classifyQueryType("the program crashes on startup"));
}

test "classifyQueryType - refactor keywords" {
    try testing.expectEqual(QueryType.refactor, classifyQueryType("refactor the module"));
    try testing.expectEqual(QueryType.refactor, classifyQueryType("rename the function"));
}

test "classifyQueryType - edit keywords" {
    try testing.expectEqual(QueryType.file_edit, classifyQueryType("edit the file"));
    try testing.expectEqual(QueryType.file_edit, classifyQueryType("implement a new feature"));
}

test "classifyQueryType - question keywords" {
    try testing.expectEqual(QueryType.question, classifyQueryType("how does this work"));
    try testing.expectEqual(QueryType.question, classifyQueryType("explain the algorithm"));
}

test "classifyQueryType - code search" {
    try testing.expectEqual(QueryType.code_search, classifyQueryType("find the function definition"));
    try testing.expectEqual(QueryType.code_search, classifyQueryType("search for TODO"));
}

test "classifyQueryType - general fallback" {
    try testing.expectEqual(QueryType.general, classifyQueryType("hello world"));
}

test "extractQueryIntent - extracts file paths" {
    var intent = try extractQueryIntent(std.testing.allocator, "edit src/main.zig to add a new handler");
    defer intent.deinit(std.testing.allocator);
    try testing.expect(intent.mentioned_files.len > 0);
}

test "extractQueryIntent - detects language hint" {
    var intent = try extractQueryIntent(std.testing.allocator, "fix the zig compilation error");
    defer intent.deinit(std.testing.allocator);
    try testing.expect(intent.language_hint != null);
    if (intent.language_hint) |lh| {
        try testing.expectEqualStrings(".zig", lh);
    }
}

test "scoreQueryRelevance - mentioned file gets high score" {
    var intent = try extractQueryIntent(std.testing.allocator, "edit src/main.zig");
    defer intent.deinit(std.testing.allocator);
    const score = scoreQueryRelevance(&intent, "src/main.zig", "");
    try testing.expect(score >= 0.5);
}

test "selectContext - selects files within budget" {
    var intent = try extractQueryIntent(std.testing.allocator, "fix bug in src/main.zig");
    defer intent.deinit(std.testing.allocator);

    const files = [_]FileInfo{
        .{ .path = "src/main.zig", .content = "pub fn main() void {}", .estimated_tokens = 10 },
        .{ .path = "src/util.zig", .content = "pub fn util() void {}", .estimated_tokens = 10 },
    };

    var sel = try selectContext(std.testing.allocator, &intent, &files, 15);
    defer sel.deinit(std.testing.allocator);
    try testing.expect(sel.selected_files.len >= 1);
    try testing.expect(sel.pruned_count >= 1);
}

test "formatContextSummary - produces readable output" {
    var files = [_]SelectedFile{
        .{ .path = "src/main.zig", .score = 0.85, .tokens = 100, .source = "mentioned" },
    };
    var sel = ContextSelection{
        .selected_files = &files,
        .total_tokens = 100,
        .budget_tokens = 200,
        .pruned_count = 2,
    };
    const summary = try formatContextSummary(std.testing.allocator, &sel);
    defer std.testing.allocator.free(summary);
    _ = &sel;
    try testing.expect(summary.len > 0);
}
