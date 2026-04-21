/// Web search tool — searches the web using DuckDuckGo.
///
/// Uses DDG HTML search endpoint (no API key required).
/// Returns search results as structured text.
const std = @import("std");
const Allocator = std.mem.Allocator;
const web_fetch = @import("web_fetch");

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub const SearchResponse = struct {
    query: []const u8,
    results: []SearchResult,

    pub fn deinit(self: *const SearchResponse, allocator: Allocator) void {
        allocator.free(self.query);
        for (self.results) |r| {
            allocator.free(r.title);
            allocator.free(r.url);
            allocator.free(r.snippet);
        }
        allocator.free(self.results);
    }
};

/// Search the web using DuckDuckGo.
/// Returns up to `max_results` results (default 5, max 10).
pub fn searchWeb(allocator: Allocator, query: []const u8, max_results: usize) !SearchResponse {
    const limit = if (max_results > 10) @as(usize, 10) else max_results;

    // URL-encode the query
    var encoded = std.ArrayList(u8){};
    defer encoded.deinit(allocator);
    for (query) |c| {
        if (std.ascii.isAlphanumeric(c) or c == ' ') {
            try encoded.append(allocator, if (c == ' ') '+' else c);
        } else {
            try encoded.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    const search_url = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{encoded.items});
    defer allocator.free(search_url);

    // Fetch the search page
    const result = web_fetch.fetchUrl(allocator, search_url) catch |err| {
        return err;
    };
    defer result.deinit(allocator);

    if (result.status_code != 200) return error.SearchFailed;

    // Parse results from HTML — look for result blocks
    var results = std.ArrayList(SearchResult){};
    errdefer {
        for (results.items) |r| {
            allocator.free(r.title);
            allocator.free(r.url);
            allocator.free(r.snippet);
        }
        results.deinit(allocator);
    }

    // Simple HTML parsing: find result__a (title+url) and result__snippet
    var pos: usize = 0;
    const body = result.body;

    while (pos < body.len and results.items.len < limit) {
        // Find next result link
        const result_marker = "result__a";
        const title_start = std.mem.indexOfPos(u8, body, pos, result_marker) orelse break;

        // Find the href
        const href_start = std.mem.indexOfPos(u8, body, title_start, "href=\"") orelse {
            pos = title_start + result_marker.len;
            continue;
        };
        const href_begin = href_start + 6;
        const href_end = std.mem.indexOfPos(u8, body, href_begin, "\"") orelse {
            pos = title_start + result_marker.len;
            continue;
        };
        const raw_url = body[href_begin..href_end];

        // Skip //duckduckgo.com/l/?uddg= redirect prefix
        const clean_url = extractRealUrl(raw_url);

        // Find title text (between > and </a>)
        const tag_close = std.mem.indexOfPos(u8, body, href_end, ">") orelse {
            pos = title_start + result_marker.len;
            continue;
        };
        const title_begin = tag_close + 1;
        const title_end = std.mem.indexOfPos(u8, body, title_begin, "<") orelse {
            pos = title_start + result_marker.len;
            continue;
        };
        const title = body[title_begin..title_end];

        // Skip empty titles
        if (std.mem.trim(u8, title, " \t\n\r").len == 0) {
            pos = title_end + 1;
            continue;
        }

        // Find snippet
        var snippet: []const u8 = "";
        const snippet_marker = "result__snippet";
        if (std.mem.indexOfPos(u8, body, title_end, snippet_marker)) |snip_start| {
            // Only use snippet if it's reasonably close to the title (within 500 chars)
            if (snip_start - title_end < 500) {
                const snip_tag_close = std.mem.indexOfPos(u8, body, snip_start, ">") orelse {
                    pos = title_end + 1;
                    continue;
                };
                const snip_begin = snip_tag_close + 1;
                const snip_end = std.mem.indexOfPos(u8, body, snip_begin, "<") orelse {
                    pos = title_end + 1;
                    continue;
                };
                snippet = body[snip_begin..snip_end];
            }
        }

        try results.append(allocator, .{
            .title = try allocator.dupe(u8, std.mem.trim(u8, title, " \t\n\r")),
            .url = try allocator.dupe(u8, clean_url),
            .snippet = try allocator.dupe(u8, std.mem.trim(u8, snippet, " \t\n\r")),
        });

        pos = title_end + 1;
    }

    return SearchResponse{
        .query = try allocator.dupe(u8, query),
        .results = try results.toOwnedSlice(allocator),
    };
}

/// Format search results as readable text for the AI.
pub fn formatResults(allocator: Allocator, response: *const SearchResponse) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("Web search results for: {s}\n\n", .{response.query});

    for (response.results, 0..) |result, i| {
        try buf.writer(allocator).print("{d}. {s}\n   URL: {s}\n", .{ i + 1, result.title, result.url });
        if (result.snippet.len > 0) {
            try buf.writer(allocator).print("   {s}\n", .{result.snippet});
        }
        try buf.append(allocator, '\n');
    }

    if (response.results.len == 0) {
        try buf.appendSlice(allocator, "No results found.\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Extract real URL from DDG redirect URL.
/// DDG uses URLs like //duckduckgo.com/l/?uddg=ENCODED_URL&r=...
fn extractRealUrl(redirect_url: []const u8) []const u8 {
    const prefix = "uddg=";
    if (std.mem.indexOf(u8, redirect_url, prefix)) |start| {
        const encoded = redirect_url[start + prefix.len ..];
        const end = std.mem.indexOf(u8, encoded, "&") orelse encoded.len;
        return encoded[0..end]; // Still URL-encoded but usable
    }
    // Not a redirect URL — return as-is
    if (std.mem.startsWith(u8, redirect_url, "//")) {
        return redirect_url[2..]; // Remove protocol-relative prefix
    }
    return redirect_url;
}

test "extractRealUrl normal URL" {
    const testing = std.testing;
    const url = extractRealUrl("https://example.com/page");
    try testing.expect(std.mem.eql(u8, url, "https://example.com/page"));
}

test "extractRealUrl DDG redirect" {
    const testing = std.testing;
    const url = extractRealUrl("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&r=abc");
    try testing.expect(std.mem.startsWith(u8, url, "https%3A%2F%2Fexample.com"));
}

test "extractRealUrl protocol-relative" {
    const testing = std.testing;
    const url = extractRealUrl("//example.com/page");
    try testing.expect(std.mem.eql(u8, url, "example.com/page"));
}
