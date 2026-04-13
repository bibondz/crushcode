const std = @import("std");
const Allocator = std.mem.Allocator;

/// Tiered context loading strategy
///
/// Inspired by LLM Wiki's tiered loading approach:
/// - index_only: Load just the index/catalog (~500 tokens) — for simple queries
/// - focused: Load index + 3-5 relevant pages (~3K tokens) — for medium queries
/// - deep: Load index + related cluster (~8K tokens) — for complex analysis
///
/// Reference: LLM Wiki Guide (Karpathy pattern), Section 13
pub const LoadTier = enum {
    index_only,
    focused,
    deep,

    pub fn parse(s: []const u8) ?LoadTier {
        if (std.mem.eql(u8, s, "index") or std.mem.eql(u8, s, "lite")) return .index_only;
        if (std.mem.eql(u8, s, "focused") or std.mem.eql(u8, s, "normal")) return .focused;
        if (std.mem.eql(u8, s, "deep") or std.mem.eql(u8, s, "full")) return .deep;
        return null;
    }

    /// Estimated max tokens this tier should load
    pub fn tokenBudget(self: LoadTier) u32 {
        return switch (self) {
            .index_only => 500,
            .focused => 3000,
            .deep => 8000,
        };
    }

    /// Max number of context pages/files to load
    pub fn maxPages(self: LoadTier) u32 {
        return switch (self) {
            .index_only => 1,
            .focused => 5,
            .deep => 20,
        };
    }

    pub fn label(self: LoadTier) []const u8 {
        return switch (self) {
            .index_only => "index-only (~500 tokens)",
            .focused => "focused (~3K tokens)",
            .deep => "deep (~8K tokens)",
        };
    }
};

/// Select appropriate tier based on query characteristics
pub fn selectTier(query: []const u8) LoadTier {
    // Simple heuristic: longer, more specific queries → deeper loading
    const word_count = std.mem.count(u8, query, " ") + 1;

    // Keywords suggesting deep analysis
    const deep_keywords = [_][]const u8{ "analyze", "compare", "architecture", "refactor", "design", "explain", "why", "how does" };
    for (deep_keywords) |kw| {
        if (std.mem.indexOf(u8, query, kw) != null) return .deep;
    }

    // Keywords suggesting focused
    const focused_keywords = [_][]const u8{ "find", "show", "what is", "where", "list" };
    for (focused_keywords) |kw| {
        if (std.mem.indexOf(u8, query, kw) != null) return .focused;
    }

    // Short queries → index only
    if (word_count <= 3) return .index_only;

    // Default to focused
    return .focused;
}
