/// Shared OAuth 2.0 PKCE helpers used by both mcp/oauth.zig and auth/provider_oauth.zig.
/// Extracted from duplicated implementations to eliminate ~240 lines of copy-paste.
const std = @import("std");
const json_extract = @import("json_extract");

const Allocator = std.mem.Allocator;

/// OAuth token information (shared between MCP and provider OAuth).
pub const OAuthTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    expires_in: ?u64 = null,
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,

    pub fn deinit(self: *OAuthTokens, allocator: Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |rt| allocator.free(rt);
        if (std.mem.eql(u8, self.token_type, "Bearer")) {} else allocator.free(self.token_type);
        if (self.scope) |sc| allocator.free(sc);
    }
};

/// Callback HTTP server for OAuth redirect.
pub const CallbackServer = struct {
    stream: std.net.Server,
    port: u16,
    allocator: Allocator,

    pub fn deinit(self: *CallbackServer) void {
        _ = self.allocator;
        self.stream.deinit();
    }
};

/// Result from OAuth callback.
pub const CallbackResult = struct {
    code: []const u8,
    state: []const u8,
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
    return @as(i64, @intCast(now)) + @as(i64, @intCast(expires_in));
}

/// Generate cryptographically random state string for CSRF protection.
pub fn generateRandomState(allocator: Allocator) ![]const u8 {
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

/// Generate PKCE code verifier (base64url-encoded random bytes).
pub fn generateCodeVerifier(allocator: Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const verifier = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(verifier, &random_bytes);

    return verifier;
}

/// Generate PKCE code challenge (SHA256 hash of verifier, base64url-encoded).
pub fn generateCodeChallenge(verifier: []const u8, allocator: Allocator) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    const challenge = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(hash.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(challenge, &hash);

    return challenge;
}

/// Start local HTTP server to receive OAuth callback.
pub fn startCallbackServer(allocator: Allocator, port: u16) !CallbackServer {
    const address = std.net.Address.parseIp("127.0.0.1", port) catch return error.OAuthCallbackFailed;
    const server = address.listen(.{ .reuse_address = true }) catch return error.OAuthCallbackFailed;
    const actual_port = server.listen_address.in.getPort();

    return CallbackServer{
        .stream = server,
        .port = actual_port,
        .allocator = allocator,
    };
}

/// Wait for OAuth callback on local server, extract code and state from query params.
pub fn waitForCallback(
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

/// Parse JSON token response from OAuth provider.
pub fn parseTokenResponse(data: []const u8, allocator: Allocator) !OAuthTokens {
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

// --- Tests ---

const testing = std.testing;

test "oauth_helpers - calculateExpiresAt returns future timestamp" {
    const now = std.time.timestamp();
    const expires_at = calculateExpiresAt(60);
    try testing.expect(expires_at >= now + 60);
}

test "oauth_helpers - isTokenExpired handles missing expiration" {
    const tokens = OAuthTokens{ .access_token = "token" };
    try testing.expect(!isTokenExpired(&tokens));
}

test "oauth_helpers - parseTokenResponse extracts fields" {
    const response =
        \\{"access_token":"at123","token_type":"Bearer","expires_in":3600,"scope":"read"}
    ;
    const tokens = try parseTokenResponse(response, testing.allocator);
    defer {
        var mut = tokens;
        mut.deinit(testing.allocator);
    }
    try testing.expect(std.mem.eql(u8, tokens.access_token, "at123"));
    try testing.expect(tokens.expires_in.? == 3600);
    try testing.expect(tokens.expires_at != null);
}
