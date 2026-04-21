/// Web content fetcher — fetches URLs and converts to clean text.
///
/// Uses Zig's std.http.Client for HTTP requests.
/// Strips HTML tags for basic readability, extracts text content.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FetchResult = struct {
    url: []const u8,
    status_code: u16,
    content_type: []const u8,
    body: []const u8,

    pub fn deinit(self: *const FetchResult, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

/// Maximum response body size (1MB)
const MAX_BODY_SIZE: usize = 1024 * 1024;

/// Fetch a URL and return the response body as text.
/// For HTML content, strips tags to produce readable text.
/// For other content types, returns the raw body.
pub fn fetchUrl(allocator: Allocator, url: []const u8) !FetchResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    // Set up headers
    var headers = std.ArrayList(std.http.Header){};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "User-Agent", .value = "crushcode/0.40 (AI coding assistant)" });
    try headers.append(allocator, .{ .name = "Accept", .value = "text/html,text/plain,application/json,*/*" });
    // Prevent gzip — Zig's std.Io.Writer.Allocating doesn't handle it
    try headers.append(allocator, .{ .name = "Accept-Encoding", .value = "identity" });

    // Use std.Io.Writer.Allocating for response body
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .extra_headers = headers.items,
        .response_writer = &response_writer.writer,
    }) catch return error.NetworkError;

    const status_code: u16 = @intFromEnum(result.status);

    // Copy body before response_writer is deinitialized
    const raw_body = try allocator.dupe(u8, response_writer.written());
    errdefer allocator.free(raw_body);

    // Detect if content looks like HTML
    const is_html = std.mem.indexOf(u8, raw_body, "<html") != null or
        std.mem.indexOf(u8, raw_body, "<!DOCTYPE") != null or
        std.mem.indexOf(u8, raw_body, "<head") != null or
        (std.mem.indexOf(u8, raw_body, "<body") != null and std.mem.indexOf(u8, raw_body, "</body>") != null);

    const content_type: []const u8 = if (is_html) "text/html" else "text/plain";

    const processed_body = if (is_html)
        stripHtml(allocator, raw_body) catch try allocator.dupe(u8, raw_body)
    else
        try allocator.dupe(u8, raw_body);

    return FetchResult{
        .url = try allocator.dupe(u8, url),
        .status_code = status_code,
        .content_type = try allocator.dupe(u8, content_type),
        .body = processed_body,
    };
}

/// Basic HTML tag stripping — removes everything between < and >,
/// converts common entities, and normalizes whitespace.
/// Returns a new allocation with the cleaned text.
pub fn stripHtml(allocator: Allocator, html: []const u8) ![]u8 {
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    var i: usize = 0;
    var in_tag: bool = false;
    var in_script: bool = false;
    var last_was_space: bool = false;

    while (i < html.len) {
        if (html[i] == '<') {
            in_tag = true;
            // Check for script/style tags
            if (i + 7 <= html.len and (std.ascii.eqlIgnoreCase(html[i..][0..7], "<script") or std.ascii.eqlIgnoreCase(html[i..][0..6], "<style"))) {
                in_script = true;
            }
            i += 1;
            continue;
        }
        if (html[i] == '>') {
            in_tag = false;
            // Add a newline after block tags
            if (i > 0) {
                // Check for closing block tags
                if (i >= 5 and (std.ascii.eqlIgnoreCase(html[i - 5 ..][0..5], "/div>") or std.ascii.eqlIgnoreCase(html[i - 5 ..][0..5], "/pre>"))) {
                    if (!last_was_space) {
                        try output.append(allocator, '\n');
                        last_was_space = true;
                    }
                }
                if (i >= 4 and std.ascii.eqlIgnoreCase(html[i - 4 ..][0..4], "/p>")) {
                    if (!last_was_space) {
                        try output.append(allocator, '\n');
                        last_was_space = true;
                    }
                }
            }
            // Check for end of script/style — 8 chars ending at i (including '>')
            // e.g. "/script>" or "/style>"
            if (in_script and i >= 7 and std.ascii.eqlIgnoreCase(html[i - 7 ..][0..8], "/script>")) {
                in_script = false;
            }
            if (in_script and i >= 6 and std.ascii.eqlIgnoreCase(html[i - 6 ..][0..7], "/style>")) {
                in_script = false;
            }
            i += 1;
            continue;
        }
        if (in_tag or in_script) {
            i += 1;
            continue;
        }

        // Handle HTML entities
        if (html[i] == '&') {
            if (i + 5 <= html.len and std.mem.eql(u8, html[i..][0..5], "&amp;")) {
                try output.append(allocator, '&');
                i += 5;
                last_was_space = false;
                continue;
            }
            if (i + 4 <= html.len and std.mem.eql(u8, html[i..][0..4], "&lt;")) {
                try output.append(allocator, '<');
                i += 4;
                last_was_space = false;
                continue;
            }
            if (i + 4 <= html.len and std.mem.eql(u8, html[i..][0..4], "&gt;")) {
                try output.append(allocator, '>');
                i += 4;
                last_was_space = false;
                continue;
            }
            if (i + 6 <= html.len and std.mem.eql(u8, html[i..][0..6], "&nbsp;")) {
                try output.append(allocator, ' ');
                i += 6;
                last_was_space = true;
                continue;
            }
            if (i + 6 <= html.len and std.mem.eql(u8, html[i..][0..6], "&quot;")) {
                try output.append(allocator, '"');
                i += 6;
                last_was_space = false;
                continue;
            }
            // Skip unknown entities
            var end = i + 1;
            while (end < html.len and html[end] != ';' and end - i < 10) end += 1;
            if (end < html.len and html[end] == ';') {
                i = end + 1;
                continue;
            }
        }

        // Collapse whitespace
        const is_space = std.ascii.isWhitespace(html[i]);
        if (is_space) {
            if (!last_was_space) {
                try output.append(allocator, ' ');
                last_was_space = true;
            }
        } else {
            try output.append(allocator, html[i]);
            last_was_space = false;
        }
        i += 1;
    }

    return output.toOwnedSlice(allocator);
}

// Simple tests
test "stripHtml basic" {
    const testing = std.testing;
    const result = try stripHtml(testing.allocator, "<p>Hello <b>world</b></p>");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "world") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<") == null);
}

test "stripHtml entities" {
    const testing = std.testing;
    const result = try stripHtml(testing.allocator, "A &amp; B &lt; C");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.eql(u8, result, "A & B < C"));
}

test "stripHtml script removal" {
    const testing = std.testing;
    const result = try stripHtml(testing.allocator, "<script>alert('xss')</script>Hello");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}
