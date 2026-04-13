const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

pub const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

fn executeRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: ?[]const std.http.Header,
    body: ?[]const u8,
) !HttpResponse {
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const empty_headers = [_]std.http.Header{};
    const resolved_headers = headers orelse empty_headers[0..];

    const result = switch (method) {
        .GET => try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .extra_headers = resolved_headers,
            .response_writer = &response_writer.writer,
        }),
        else => try client.fetch(.{
            .location = .{ .uri = uri },
            .method = method,
            .payload = body orelse "",
            .extra_headers = resolved_headers,
            .response_writer = &response_writer.writer,
        }),
    };

    return .{
        .status = result.status,
        .body = try allocator.dupe(u8, response_writer.written()),
    };
}

fn buildFormHeaders(allocator: Allocator, headers: ?[]const std.http.Header) ![]std.http.Header {
    var combined = array_list_compat.ArrayList(std.http.Header).init(allocator);
    errdefer combined.deinit();

    var has_content_type = false;
    if (headers) |provided_headers| {
        for (provided_headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) {
                has_content_type = true;
            }
            try combined.append(header);
        }
    }

    if (!has_content_type) {
        try combined.append(.{
            .name = "Content-Type",
            .value = "application/x-www-form-urlencoded",
        });
    }

    return combined.toOwnedSlice();
}

pub fn httpGet(allocator: Allocator, url: []const u8, headers: ?[]const std.http.Header) !HttpResponse {
    return executeRequest(allocator, .GET, url, headers, null);
}

pub fn httpPost(allocator: Allocator, url: []const u8, headers: ?[]const std.http.Header, body: ?[]const u8) !HttpResponse {
    return executeRequest(allocator, .POST, url, headers, body);
}

pub fn httpPostForm(allocator: Allocator, url: []const u8, form_data: []const u8, headers: ?[]const std.http.Header) !HttpResponse {
    const form_headers = try buildFormHeaders(allocator, headers);
    defer allocator.free(form_headers);

    return executeRequest(allocator, .POST, url, form_headers, form_data);
}
