const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const http_client = @import("http_client");

const json = std.json;
const Allocator = std.mem.Allocator;

pub const TransportType = enum {
    stdio,
    sse,
    http,
    websocket,
};

pub const MCPConnection = struct {
    transport: TransportType,
    server_name: []const u8,
    url: ?[]const u8 = null,
    headers: std.json.ObjectMap,
    method: []const u8,
    command: ?[]const u8 = null,
    env_vars: ?[][]const u8 = null,
    args: ?[][]const u8 = null,
    process: ?*anyopaque = null,
    initialized: bool,

    /// Clean up connection resources (kill process, free owned strings)
    pub fn deinit(self: *MCPConnection, allocator: Allocator) void {
        if (self.process) |proc_ptr| {
            const child = @as(*std.process.Child, @ptrCast(@alignCast(proc_ptr)));
            _ = child.kill() catch {};
            allocator.destroy(child);
            self.process = null;
        }
        allocator.free(self.server_name);
        self.headers.deinit();
    }
};

/// Recursively free a json.Value tree that was created by cloneJsonValue.
pub fn deinitJsonValue(allocator: Allocator, value: json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string, .string => {},
        .array => |inner| {
            for (inner.items) |item| {
                deinitJsonValue(allocator, item);
            }
            @constCast(&inner).deinit();
        },
        .object => |inner| {
            var iter = inner.iterator();
            while (iter.next()) |entry| {
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            @constCast(&inner).deinit();
        },
    }
}

/// Deep-clone a json.Value tree for ownership transfer.
pub fn cloneJsonValue(allocator: Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .null => .{ .null = {} },
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |inner| blk: {
            var cloned = json.Array.init(allocator);
            for (inner.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |inner| blk: {
            var cloned = json.ObjectMap.init(allocator);
            var iter = inner.iterator();
            while (iter.next()) |entry| {
                try cloned.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

pub fn createStdioConnection(
    allocator: Allocator,
    name: []const u8,
    command: []const u8,
    args: ?[][]const u8,
    env_vars: ?[][]const u8,
) !MCPConnection {
    var env_map = if (env_vars) |ev|
        try prepareEnvironment(allocator, ev)
    else
        try prepareEnvironment(allocator, &[_][]const u8{});
    defer env_map.deinit();

    const spawn_args = args orelse &[_][]const u8{};
    const process = try spawnProcess(allocator, command, spawn_args, &env_map);

    return MCPConnection{
        .transport = .stdio,
        .server_name = try allocator.dupe(u8, name),
        .command = command,
        .env_vars = env_vars,
        .args = args,
        .headers = std.json.ObjectMap.init(allocator),
        .method = "stdio",
        .process = process,
        .initialized = false,
    };
}

pub fn createSSEConnection(
    allocator: Allocator,
    name: []const u8,
    url: []const u8,
    headers: ?std.json.ObjectMap,
) !MCPConnection {
    return MCPConnection{
        .transport = .sse,
        .server_name = try allocator.dupe(u8, name),
        .url = url,
        .headers = headers orelse std.json.ObjectMap.init(allocator),
        .method = "GET",
        .initialized = false,
        .process = null,
    };
}

pub fn createHTTPConnection(
    allocator: Allocator,
    name: []const u8,
    url: []const u8,
    headers: ?std.json.ObjectMap,
    method: []const u8,
) !MCPConnection {
    return MCPConnection{
        .transport = .http,
        .server_name = try allocator.dupe(u8, name),
        .url = url,
        .headers = headers orelse std.json.ObjectMap.init(allocator),
        .method = method,
        .initialized = false,
        .process = null,
    };
}

pub fn createWebSocketConnection(
    allocator: Allocator,
    name: []const u8,
    url: []const u8,
    headers: ?std.json.ObjectMap,
) !MCPConnection {
    return MCPConnection{
        .transport = .websocket,
        .server_name = try allocator.dupe(u8, name),
        .url = url,
        .headers = headers orelse std.json.ObjectMap.init(allocator),
        .method = "GET",
        .initialized = false,
        .process = null,
    };
}

/// Send raw data over stdio as newline-delimited JSON (no response expected).
pub fn sendStdioRaw(connection: *MCPConnection, data: []const u8) !void {
    const process_ptr = connection.process orelse return error.ProcessNotStarted;
    const child = @as(*std.process.Child, @ptrCast(@alignCast(process_ptr)));
    try child.stdin.?.writeAll(data);
    try child.stdin.?.writeAll("\n");
}

/// Send stdio request (newline-delimited JSON).
pub fn sendStdioRequest(
    allocator: Allocator,
    owned_json_values: *array_list_compat.ArrayList(json.Value),
    connection: MCPConnection,
    request: []const u8,
) !json.Value {
    const process_ptr = connection.process orelse return error.ProcessNotStarted;
    const child = @as(*std.process.Child, @ptrCast(@alignCast(process_ptr)));

    try child.stdin.?.writeAll(request);
    try child.stdin.?.writeAll("\n");

    var response_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer response_buf.deinit();

    const reader = file_compat.wrap(child.stdout.?).reader();
    while (true) {
        const byte = reader.readByte() catch break;
        try response_buf.append(byte);
        if (byte == '\n') break;
    }

    const trimmed = std.mem.trimRight(u8, response_buf.items, "\r\n ");

    const response_json = json.parseFromSlice(json.Value, allocator, trimmed, .{}) catch |err| {
        std.log.err("Failed to parse stdio response: {s}", .{@errorName(err)});
        return json.Value{ .string = try allocator.dupe(u8, trimmed) };
    };
    defer response_json.deinit();

    const cloned = try cloneJsonValue(allocator, response_json.value);
    try owned_json_values.append(cloned);
    return cloned;
}

/// Send SSE request.
pub fn sendSSERequest(allocator: Allocator, connection: MCPConnection, request: []const u8) !json.Value {
    var request_json = try json.parseFromSlice(json.Value, allocator, request, .{});
    defer request_json.deinit();

    const request_obj = if (request_json.value == .object) request_json.value.object else return error.InvalidRequest;

    const id = blk: {
        if (request_obj.get("id")) |i| {
            break :blk if (i == .integer) i.integer else 0;
        }
        break :blk 0;
    };

    const url = connection.url orelse return error.InvalidUrl;
    std.log.info("Sending SSE request to {s}", .{url});

    const headers = try buildConnectionHeaders(allocator, connection, "text/event-stream");
    defer freeOwnedHeaders(allocator, headers);

    const fetch_result = http_client.httpPost(allocator, url, headers, request) catch |err| {
        std.log.err("SSE HTTP request failed: {s}", .{@errorName(err)});
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = -32603 });
        try error_obj.put("message", .{ .string = try allocator.dupe(u8, @errorName(err)) });

        var response_obj = std.json.ObjectMap.init(allocator);
        try response_obj.put("jsonrpc", .{ .string = "2.0" });
        try response_obj.put("error", .{ .object = error_obj });
        try response_obj.put("id", .{ .integer = id });

        return .{ .object = response_obj };
    };
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        std.log.err("SSE response status: {any}", .{fetch_result.status});
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = -32001 });
        try error_obj.put("message", .{ .string = try std.fmt.allocPrint(allocator, "Server returned {any}", .{fetch_result.status}) });

        var response_obj = std.json.ObjectMap.init(allocator);
        try response_obj.put("jsonrpc", .{ .string = "2.0" });
        try response_obj.put("error", .{ .object = error_obj });
        try response_obj.put("id", .{ .integer = id });

        return .{ .object = response_obj };
    }

    const response_body = fetch_result.body;
    var sse_iter = std.mem.splitSequence(u8, response_body, "data: ");
    while (sse_iter.next()) |data_line| {
        const trimmed = std.mem.trim(u8, data_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "event:")) continue;

        if (std.mem.startsWith(u8, trimmed, "{") or std.mem.startsWith(u8, trimmed, "[")) {
            var parsed = json.parseFromSlice(json.Value, allocator, trimmed, .{}) catch {
                continue;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("jsonrpc") != null) {
                    return try cloneJsonValue(allocator, parsed.value);
                }
            }
            return try cloneJsonValue(allocator, parsed.value);
        }
    }

    var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch {
        std.log.err("Failed to parse SSE response", .{});
        return json.Value{ .string = try allocator.dupe(u8, response_body) };
    };
    defer response_json.deinit();

    return try cloneJsonValue(allocator, response_json.value);
}

/// Send HTTP request.
pub fn sendHTTPRequest(allocator: Allocator, connection: MCPConnection, request: []const u8) !json.Value {
    var request_json = try json.parseFromSlice(json.Value, allocator, request, .{});
    defer request_json.deinit();

    const request_obj = if (request_json.value == .object) request_json.value.object else return error.InvalidRequest;

    const method = blk: {
        if (request_obj.get("method")) |m| {
            break :blk if (m == .string) m.string else "unknown";
        }
        break :blk "unknown";
    };

    const id = blk: {
        if (request_obj.get("id")) |i| {
            break :blk if (i == .integer) i.integer else 0;
        }
        break :blk 0;
    };

    std.log.info("Sending HTTP {s} request to {s}", .{ method, connection.url.? });

    const headers = try buildConnectionHeaders(allocator, connection, null);
    defer freeOwnedHeaders(allocator, headers);

    const fetch_result = http_client.httpPost(allocator, connection.url.?, headers, request) catch |err| {
        std.log.err("HTTP request failed: {s}", .{@errorName(err)});
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = -32603 });
        try error_obj.put("message", .{ .string = try allocator.dupe(u8, @errorName(err)) });

        var response_obj = std.json.ObjectMap.init(allocator);
        try response_obj.put("jsonrpc", .{ .string = "2.0" });
        try response_obj.put("error", .{ .object = error_obj });
        try response_obj.put("id", .{ .integer = id });

        return .{ .object = response_obj };
    };
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        std.log.err("HTTP response status: {any}", .{fetch_result.status});
        var error_obj2 = std.json.ObjectMap.init(allocator);
        try error_obj2.put("code", .{ .integer = -32001 });
        try error_obj2.put("message", .{ .string = try std.fmt.allocPrint(allocator, "Server returned {any}", .{fetch_result.status}) });

        var response_obj2 = std.json.ObjectMap.init(allocator);
        try response_obj2.put("jsonrpc", .{ .string = "2.0" });
        try response_obj2.put("error", .{ .object = error_obj2 });
        try response_obj2.put("id", .{ .integer = id });

        return .{ .object = response_obj2 };
    }

    const response_body = fetch_result.body;
    var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        std.log.err("Failed to parse response: {s}", .{@errorName(err)});
        return json.Value{ .string = try allocator.dupe(u8, response_body) };
    };
    defer response_json.deinit();

    return try cloneJsonValue(allocator, response_json.value);
}

/// Send WebSocket request.
/// Note: Full WebSocket requires framing protocol. For MCP servers,
/// many also accept HTTP POST as a simpler alternative.
/// This implementation sends HTTP POST and parses the JSON response.
pub fn sendWebSocketRequest(allocator: Allocator, connection: MCPConnection, request: []const u8) !json.Value {
    var request_json = try json.parseFromSlice(json.Value, allocator, request, .{});
    defer request_json.deinit();

    const request_obj = if (request_json.value == .object) request_json.value.object else return error.InvalidRequest;

    const id = blk: {
        if (request_obj.get("id")) |i| {
            break :blk if (i == .integer) i.integer else 0;
        }
        break :blk 0;
    };

    const url = connection.url orelse return error.InvalidUrl;
    std.log.info("Sending WebSocket-HTTP request to {s}", .{url});

    const headers = try buildConnectionHeaders(allocator, connection, null);
    defer freeOwnedHeaders(allocator, headers);

    const fetch_result = http_client.httpPost(allocator, url, headers, request) catch |err| {
        std.log.err("WebSocket-HTTP request failed: {s}", .{@errorName(err)});
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = -32603 });
        try error_obj.put("message", .{ .string = try allocator.dupe(u8, @errorName(err)) });

        var response_obj = std.json.ObjectMap.init(allocator);
        try response_obj.put("jsonrpc", .{ .string = "2.0" });
        try response_obj.put("error", .{ .object = error_obj });
        try response_obj.put("id", .{ .integer = id });

        return .{ .object = response_obj };
    };
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        std.log.err("WebSocket-HTTP response status: {any}", .{fetch_result.status});
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = -32001 });
        try error_obj.put("message", .{ .string = try std.fmt.allocPrint(allocator, "Server returned {any}", .{fetch_result.status}) });

        var response_obj = std.json.ObjectMap.init(allocator);
        try response_obj.put("jsonrpc", .{ .string = "2.0" });
        try response_obj.put("error", .{ .object = error_obj });
        try response_obj.put("id", .{ .integer = id });

        return .{ .object = response_obj };
    }

    const response_body = fetch_result.body;
    var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch {
        std.log.err("Failed to parse WebSocket-HTTP response", .{});
        return json.Value{ .string = try allocator.dupe(u8, response_body) };
    };
    defer response_json.deinit();

    return try cloneJsonValue(allocator, response_json.value);
}

fn prepareEnvironment(allocator: Allocator, env_vars: []const []const u8) !std.process.EnvMap {
    var env_map = std.process.getEnvMap(allocator) catch return error.EnvMapFailed;

    for (env_vars) |env_var| {
        if (std.mem.indexOf(u8, env_var, "=")) |eq_pos| {
            const key = env_var[0..eq_pos];
            const value = env_var[eq_pos + 1 ..];
            try env_map.put(key, value);
        }
    }

    return env_map;
}

fn spawnProcess(
    allocator: Allocator,
    command: []const u8,
    args: []const []const u8,
    env_map: *std.process.EnvMap,
) !*std.process.Child {
    var argv = array_list_compat.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append(command);
    for (args) |arg| {
        try argv.append(arg);
    }

    var process = std.process.Child.init(argv.items, allocator);
    process.env_map = env_map;
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Close;

    try process.spawn();

    const process_ptr = try allocator.create(std.process.Child);
    process_ptr.* = process;

    return process_ptr;
}

pub fn freeOwnedHeaders(allocator: Allocator, headers: []std.http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

pub fn buildConnectionHeaders(
    allocator: Allocator,
    connection: MCPConnection,
    accept_value: ?[]const u8,
) ![]std.http.Header {
    var headers_buf = array_list_compat.ArrayList(std.http.Header).init(allocator);
    errdefer headers_buf.deinit();

    try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });
    if (accept_value) |accept| {
        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Accept"), .value = try allocator.dupe(u8, accept) });
    }

    var header_iter = connection.headers.iterator();
    while (header_iter.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*.string) });
        }
    }

    return headers_buf.toOwnedSlice();
}

const testing = std.testing;

test "transport - buildConnectionHeaders includes defaults and custom values" {
    var headers = std.json.ObjectMap.init(testing.allocator);
    defer headers.deinit();
    try headers.put("Authorization", .{ .string = "Bearer token" });

    const connection = MCPConnection{
        .transport = .http,
        .server_name = try testing.allocator.dupe(u8, "server"),
        .url = "https://example.com",
        .headers = headers,
        .method = "POST",
        .initialized = false,
    };

    var connection_mut = connection;
    defer connection_mut.deinit(testing.allocator);

    const built = try buildConnectionHeaders(testing.allocator, connection_mut, "application/json");
    defer freeOwnedHeaders(testing.allocator, built);

    try testing.expect(built.len == 3);
}
