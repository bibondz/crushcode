const std = @import("std");
const array_list_compat = @import("array_list_compat");
const env_config = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");

const Allocator = std.mem.Allocator;

/// OAuth token information.
pub const OAuthTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    expires_in: ?u64 = null,
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,
};

/// OAuth client information for dynamic registration.
pub const OAuthClientInfo = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    registration_access_token: ?[]const u8 = null,
};

/// OAuth server configuration.
pub const OAuthServerConfig = struct {
    auth_url: []const u8,
    token_url: []const u8,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    scopes: ?[]const u8 = null,
    redirect_uri: ?[]const u8 = null,
};

/// OAuth state for CSRF protection.
pub const OAuthState = struct {
    server_name: []const u8,
    state: []const u8,
    redirect_uri: []const u8,
    created_at: i64,
};

/// OAuth authentication result.
pub const OAuthResult = struct {
    success: bool,
    tokens: ?OAuthTokens = null,
    error_message: ?[]const u8 = null,
};

/// Check if token is expired.
pub fn isTokenExpired(tokens: *const OAuthTokens) bool {
    if (tokens.expires_at) |expires| {
        const now = std.time.timestamp();
        return now >= expires;
    }
    return false;
}

/// Calculate expiration timestamp from expires_in seconds.
pub fn calculateExpiresAt(expires_in: u64) i64 {
    const now = std.time.timestamp();
    const future_time = @as(i64, @intCast(now)) + @as(i64, @intCast(expires_in));
    return future_time;
}

/// Start OAuth authentication flow for a server.
pub fn authenticateWithOAuth(
    self: anytype,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthResult {
    _ = self;
    std.log.info("Starting OAuth authentication for server: {s}", .{server_name});

    const state = try generateRandomState(allocator);
    defer allocator.free(state);

    const code_verifier = try generateCodeVerifier(allocator);
    defer allocator.free(code_verifier);
    const code_challenge = try generateCodeChallenge(code_verifier, allocator);
    defer allocator.free(code_challenge);

    const auth_url = try buildAuthorizationUrl(config, state, code_challenge, allocator);
    defer allocator.free(auth_url);

    var callback_server = try startCallbackServer(allocator);
    defer callback_server.deinit();

    std.log.info("Please open this URL in your browser: {s}", .{auth_url});
    std.log.info("Waiting for OAuth callback on port {d}...", .{callback_server.port});

    const callback_result = try waitForCallback(&callback_server, state, allocator);
    defer allocator.free(callback_result.code);

    const tokens = try exchangeCodeForTokens(config, callback_result.code, code_verifier, allocator);
    try storeOAuthTokens(server_name, tokens, allocator);

    return OAuthResult{
        .success = true,
        .tokens = tokens,
    };
}

fn generateRandomState(allocator: Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const hex_state = try allocator.alloc(u8, random_bytes.len * 2);
    for (random_bytes, 0..) |byte, i| {
        const hex_pair = std.fmt.bytesToHex(&[_]u8{byte}, .lower);
        hex_state[i * 2] = hex_pair[0];
        hex_state[i * 2 + 1] = hex_pair[1];
    }

    return hex_state;
}

fn generateCodeVerifier(allocator: Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const verifier = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(verifier, &random_bytes);

    return verifier;
}

fn generateCodeChallenge(verifier: []const u8, allocator: Allocator) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    const challenge = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(hash.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(challenge, &hash);

    return challenge;
}

fn buildAuthorizationUrl(
    config: OAuthServerConfig,
    state: []const u8,
    code_challenge: []const u8,
    allocator: Allocator,
) ![]const u8 {
    var url_builder = array_list_compat.ArrayList(u8).init(allocator);
    defer url_builder.deinit();

    try url_builder.writer().print("{s}?response_type=code&client_id={s}&redirect_uri={s}&state={s}&code_challenge={s}&code_challenge_method=S256", .{
        config.auth_url,
        config.client_id orelse return error.MissingClientId,
        config.redirect_uri orelse "http://127.0.0.1:19876/mcp/oauth/callback",
        state,
        code_challenge,
    });

    if (config.scopes) |scopes| {
        try url_builder.writer().print("&scope={s}", .{scopes});
    }

    return try url_builder.toOwnedSlice();
}

const CallbackServer = struct {
    stream: std.net.Server,
    port: u16,
    allocator: Allocator,

    fn deinit(self: *CallbackServer) void {
        _ = self.allocator;
        self.stream.deinit();
    }
};

fn startCallbackServer(allocator: Allocator) !CallbackServer {
    const address = std.net.Address.parseIp("127.0.0.1", 0) catch return error.OAuthCallbackFailed;
    const server = address.listen(.{ .reuse_address = true }) catch return error.OAuthCallbackFailed;
    const port = server.listen_address.in.getPort();

    return CallbackServer{
        .stream = server,
        .port = port,
        .allocator = allocator,
    };
}

fn waitForCallback(
    callback_server: *CallbackServer,
    expected_state: []const u8,
    allocator: Allocator,
) !CallbackResult {
    var conn = callback_server.stream.accept() catch return error.OAuthCallbackFailed;
    defer conn.stream.close();

    var read_buf: [4096]u8 = undefined;
    const bytes_read = conn.stream.read(&read_buf) catch return error.OAuthCallbackFailed;
    const request = read_buf[0..bytes_read];

    const query_start = std.mem.indexOf(u8, request, "?") orelse return error.OAuthCallbackFailed;
    const line_end = std.mem.indexOfScalar(u8, request[query_start..], ' ') orelse return error.OAuthCallbackFailed;
    const query_string = request[query_start .. query_start + line_end];

    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;

    var it = std.mem.splitSequence(u8, query_string, "&");
    while (it.next()) |param| {
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_idx];
        const value = param[eq_idx + 1 ..];

        if (std.mem.eql(u8, key, "code")) {
            code = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "state")) {
            state = try allocator.dupe(u8, value);
        }
    }

    const response_html =
        \\HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n
        \\<html><body><h2>Authentication successful!</h2><p>You can close this tab.</p></body></html>
    ;
    _ = conn.stream.write(response_html) catch {};

    const result_code = code orelse return error.OAuthCallbackFailed;
    const result_state = state orelse return error.OAuthCallbackFailed;
    errdefer allocator.free(result_code);
    defer allocator.free(result_state);

    if (!std.mem.eql(u8, result_state, expected_state)) {
        allocator.free(result_code);
        return error.OAuthStateMismatch;
    }

    return CallbackResult{
        .code = result_code,
        .state = result_state,
    };
}

const CallbackResult = struct {
    code: []const u8,
    state: []const u8,
};

fn exchangeCodeForTokens(
    config: OAuthServerConfig,
    code: []const u8,
    code_verifier: []const u8,
    allocator: Allocator,
) !OAuthTokens {
    var body_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    const bw = body_buf.writer();

    const redirect_uri = config.redirect_uri orelse "http://127.0.0.1:19876/mcp/oauth/callback";
    try bw.print("grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}", .{ code, redirect_uri, code_verifier });
    if (config.client_id) |cid| {
        try bw.print("&client_id={s}", .{cid});
    }
    if (config.client_secret) |cs| {
        try bw.print("&client_secret={s}", .{cs});
    }

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    const fetch_result = http_client.httpPostForm(allocator, config.token_url, body_buf.items, &headers) catch return error.OAuthTokenExchangeFailed;
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) return error.OAuthTokenExchangeFailed;

    const response_data = fetch_result.body;
    if (response_data.len == 0) return error.OAuthTokenExchangeFailed;

    return parseTokenResponse(response_data, allocator);
}

fn parseTokenResponse(data: []const u8, allocator: Allocator) !OAuthTokens {
    const access_token = json_extract.extractString(data, "access_token") orelse return error.OAuthTokenExchangeFailed;
    const refresh_token = json_extract.extractString(data, "refresh_token");
    const token_type = json_extract.extractString(data, "token_type") orelse "Bearer";
    const expires_in = json_extract.extractInteger(data, "expires_in");
    const scope = json_extract.extractString(data, "scope");

    const at = try allocator.dupe(u8, access_token);
    const rt = if (refresh_token) |value| try allocator.dupe(u8, value) else null;
    const tt = try allocator.dupe(u8, token_type);
    const sc = if (scope) |value| try allocator.dupe(u8, value) else null;

    const expires_at: ?i64 = if (expires_in) |ei|
        calculateExpiresAt(@as(u64, @intCast(ei)))
    else
        null;

    return OAuthTokens{
        .access_token = at,
        .refresh_token = rt,
        .token_type = tt,
        .expires_in = if (expires_in) |ei| @as(u64, @intCast(ei)) else null,
        .expires_at = expires_at,
        .scope = sc,
    };
}

fn getTokenStorePath(allocator: Allocator) ![]const u8 {
    const config_dir = try env_config.getConfigDir(allocator);
    defer allocator.free(config_dir);

    return std.fs.path.join(allocator, &.{ config_dir, "mcp_tokens.json" });
}

fn storeOAuthTokens(server_name: []const u8, tokens: OAuthTokens, allocator: Allocator) !void {
    const token_path = getTokenStorePath(allocator) catch |err| {
        std.log.warn("Cannot resolve token store path: {} — tokens kept in memory only", .{err});
        return;
    };
    defer allocator.free(token_path);

    const dir = std.fs.path.dirname(token_path) orelse return error.InvalidPath;
    std.fs.cwd().makePath(dir) catch {};

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    var existing_data: ?[]const u8 = null;
    if (std.fs.cwd().openFile(token_path, .{})) |file| {
        defer file.close();
        const file_size = file.getEndPos() catch 0;
        if (file_size > 0 and file_size < 1024 * 1024) {
            const contents = try allocator.alloc(u8, file_size);
            const bytes_read = file.readAll(contents) catch 0;
            if (bytes_read > 0) {
                existing_data = contents[0..bytes_read];
            } else {
                allocator.free(contents);
            }
        }
    } else |_| {}

    try w.writeAll("{");

    var first = true;
    if (existing_data) |data| {
        var i: usize = 0;
        while (i < data.len and data[i] != '{') : (i += 1) {}
        if (i < data.len) i += 1;

        while (i < data.len) {
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] == '}') break;
            if (data[i] != '"') break;

            i += 1;
            const key_start = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const key_end = i;
            i += 1;

            while (i < data.len and data[i] != ':') : (i += 1) {}
            i += 1;
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}

            const obj_start = i;
            var depth: usize = 0;
            while (i < data.len) : (i += 1) {
                if (data[i] == '{') depth += 1;
                if (data[i] == '}') {
                    if (depth == 1) {
                        i += 1;
                        break;
                    }
                    depth -= 1;
                }
            }

            if (std.mem.eql(u8, data[key_start..key_end], server_name)) {
                while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
                continue;
            }

            if (!first) try w.writeAll(",");
            first = false;
            try w.writeByte('"');
            try w.writeAll(data[key_start..key_end]);
            try w.writeAll("\":");
            try w.writeAll(data[obj_start..i]);

            while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        }

        defer allocator.free(data);
    }

    if (!first) try w.writeAll(",");
    try w.print("\"{s}\":{{\"access_token\":\"{s}\",\"token_type\":\"{s}\"", .{ server_name, tokens.access_token, tokens.token_type });
    if (tokens.expires_at) |ea| {
        try w.print(",\"expires_at\":{d}", .{ea});
    }
    if (tokens.expires_in) |ei| {
        try w.print(",\"expires_in\":{d}", .{ei});
    }
    if (tokens.refresh_token) |rt| {
        try w.print(",\"refresh_token\":\"{s}\"", .{rt});
    }
    if (tokens.scope) |sc| {
        try w.print(",\"scope\":\"{s}\"", .{sc});
    }
    try w.writeAll("}}");

    const out_file = std.fs.cwd().createFile(token_path, .{}) catch |err| {
        std.log.warn("Failed to create token store file: {}", .{err});
        return;
    };
    defer out_file.close();
    try out_file.writeAll(buf.items);

    std.log.info("Stored tokens for server '{s}'", .{server_name});
}

pub fn refreshOAuthTokens(
    self: anytype,
    server_name: []const u8,
    config: OAuthServerConfig,
    tokens: OAuthTokens,
    allocator: Allocator,
) !OAuthTokens {
    _ = self;
    _ = server_name;

    const refresh_token = tokens.refresh_token orelse return error.NoRefreshToken;

    var body_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    const bw = body_buf.writer();

    try bw.print("grant_type=refresh_token&refresh_token={s}", .{refresh_token});
    if (config.client_id) |cid| {
        try bw.print("&client_id={s}", .{cid});
    }
    if (config.client_secret) |cs| {
        try bw.print("&client_secret={s}", .{cs});
    }

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    const fetch_result = http_client.httpPostForm(allocator, config.token_url, body_buf.items, &headers) catch return error.OAuthTokenRefreshFailed;
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) return error.OAuthTokenRefreshFailed;

    const response_data = fetch_result.body;
    if (response_data.len == 0) return error.OAuthTokenRefreshFailed;

    var new_tokens = try parseTokenResponse(response_data, allocator);
    if (new_tokens.refresh_token == null) {
        new_tokens.refresh_token = try allocator.dupe(u8, refresh_token);
    }

    return new_tokens;
}

pub fn getOAuthTokens(
    self: anytype,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthTokens {
    _ = self;
    _ = config;

    const token_path = getTokenStorePath(allocator) catch return error.TokensNotFound;
    defer allocator.free(token_path);

    const file = std.fs.cwd().openFile(token_path, .{}) catch return error.TokensNotFound;
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0 or file_size > 1024 * 1024) return error.TokensNotFound;
    const buf = try allocator.alloc(u8, file_size);
    defer allocator.free(buf);

    const bytes_read = try file.readAll(buf);
    const data = buf[0..bytes_read];

    var key_buf: [256]u8 = undefined;
    const key_prefix = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{server_name}) catch return error.TokensNotFound;

    const idx = std.mem.indexOf(u8, data, key_prefix) orelse return error.TokensNotFound;
    var i = idx + key_prefix.len;

    while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return error.TokensNotFound;

    const obj_start = i;
    var depth: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '{') depth += 1;
        if (data[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                break;
            }
        }
    }
    const obj_str = data[obj_start..i];

    var access_token: ?[]const u8 = null;
    var refresh_token: ?[]const u8 = null;
    var token_type: []const u8 = "Bearer";
    var expires_in: ?u64 = null;
    var expires_at: ?i64 = null;
    var scope: ?[]const u8 = null;

    var j: usize = 1;
    while (j < obj_str.len) {
        while (j < obj_str.len and std.mem.indexOfScalar(u8, " \t\n\r", obj_str[j]) != null) : (j += 1) {}
        if (j >= obj_str.len or obj_str[j] == '}') break;
        if (obj_str[j] != '"') break;

        j += 1;
        const fname_start = j;
        while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
        const fname_end = j;
        const fname = obj_str[fname_start..fname_end];
        j += 1;

        while (j < obj_str.len and obj_str[j] != ':') : (j += 1) {}
        j += 1;
        while (j < obj_str.len and std.mem.indexOfScalar(u8, " \t\n\r", obj_str[j]) != null) : (j += 1) {}

        if (obj_str[j] == '"') {
            j += 1;
            const vs = j;
            while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
            const val = obj_str[vs..j];
            j += 1;

            if (std.mem.eql(u8, fname, "access_token")) {
                access_token = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, fname, "refresh_token")) {
                refresh_token = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, fname, "token_type")) {
                token_type = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, fname, "scope")) {
                scope = try allocator.dupe(u8, val);
            }
        } else {
            const ns = j;
            while (j < obj_str.len and obj_str[j] != ',' and obj_str[j] != '}') : (j += 1) {}
            const num_str = std.mem.trim(u8, obj_str[ns..j], " \t\n\r");

            if (std.mem.eql(u8, fname, "expires_at")) {
                expires_at = std.fmt.parseInt(i64, num_str, 10) catch null;
            } else if (std.mem.eql(u8, fname, "expires_in")) {
                expires_in = std.fmt.parseInt(u64, num_str, 10) catch null;
            }
        }

        while (j < obj_str.len and (obj_str[j] == ',' or obj_str[j] == ' ')) : (j += 1) {}
    }

    const at = access_token orelse return error.TokensNotFound;

    if (expires_at) |ea| {
        const now = std.time.timestamp();
        if (now >= ea) return error.TokenExpired;
    }

    return OAuthTokens{
        .access_token = at,
        .refresh_token = refresh_token,
        .token_type = token_type,
        .expires_in = expires_in,
        .expires_at = expires_at,
        .scope = scope,
    };
}

const testing = std.testing;

test "oauth - calculateExpiresAt returns future timestamp" {
    const now = std.time.timestamp();
    const expires_at = calculateExpiresAt(60);
    try testing.expect(expires_at >= now + 60);
}

test "oauth - isTokenExpired handles missing expiration" {
    const tokens = OAuthTokens{ .access_token = "token" };
    try testing.expect(!isTokenExpired(&tokens));
}
