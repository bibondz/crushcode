const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const env_config = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");
const oauth_helpers = @import("oauth_helpers");

const Allocator = std.mem.Allocator;

/// Re-export OAuthTokens from shared helpers.
pub const OAuthTokens = oauth_helpers.OAuthTokens;

/// OAuth provider configuration — defines endpoints per provider.
pub const ProviderOAuthConfig = struct {
    provider_name: []const u8,
    auth_url: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    scopes: []const u8,
    redirect_port: u16 = 19877,
};

/// OAuth result from authentication attempt.
pub const OAuthResult = struct {
    success: bool,
    tokens: ?OAuthTokens = null,
    error_message: ?[]const u8 = null,
};

/// Get hardcoded OAuth config for a known provider.
/// Returns null if the provider does not support OAuth.
pub fn getConfigForProvider(provider_name: []const u8) ?ProviderOAuthConfig {
    if (std.mem.eql(u8, provider_name, "openrouter")) {
        return ProviderOAuthConfig{
            .provider_name = "openrouter",
            .auth_url = "https://openrouter.ai/auth/authorize",
            .token_url = "https://openrouter.ai/api/v1/auth/token",
            .client_id = "crushcode",
            .scopes = "openid profile email",
            .redirect_port = 19877,
        };
    }
    return null;
}

/// Check if token is expired.
pub fn isTokenExpired(tokens: *const OAuthTokens) bool {
    return oauth_helpers.isTokenExpired(tokens);
}

/// Calculate expiration timestamp from expires_in seconds.
pub fn calculateExpiresAt(expires_in: u64) i64 {
    return oauth_helpers.calculateExpiresAt(expires_in);
}

/// ProviderOAuth — struct-based OAuth 2.0 PKCE client for AI providers.
/// Generalized from src/mcp/oauth.zig with provider-agnostic design.
pub const ProviderOAuth = struct {
    allocator: Allocator,
    config: ProviderOAuthConfig,

    pub fn init(allocator: Allocator, config: ProviderOAuthConfig) ProviderOAuth {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Start full OAuth browser flow: PKCE generation → callback server → token exchange → store.
    pub fn authenticate(self: *ProviderOAuth) !OAuthTokens {
        const state = try oauth_helpers.generateRandomState(self.allocator);
        defer self.allocator.free(state);

        const code_verifier = try oauth_helpers.generateCodeVerifier(self.allocator);
        defer self.allocator.free(code_verifier);
        const code_challenge = try oauth_helpers.generateCodeChallenge(code_verifier, self.allocator);
        defer self.allocator.free(code_challenge);

        const redirect_uri = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}/callback", .{self.config.redirect_port});
        defer self.allocator.free(redirect_uri);

        const auth_url = try self.buildAuthorizationUrl(state, code_challenge, redirect_uri);
        defer self.allocator.free(auth_url);

        var callback_server = try oauth_helpers.startCallbackServer(self.allocator, self.config.redirect_port);
        defer callback_server.deinit();

        const stdout = file_compat.File.stdout().writer();
        stdout.print("Please open this URL in your browser:\n{s}\n", .{auth_url}) catch |err| std.log.warn("stdout write failed: {}", .{err});
        stdout.print("Waiting for OAuth callback on port {d}...\n", .{callback_server.port}) catch |err| std.log.warn("stdout write failed: {}", .{err});

        const callback_result = try oauth_helpers.waitForCallback(&callback_server, state, self.allocator);
        defer self.allocator.free(callback_result.code);

        const tokens = try self.exchangeCodeForTokens(callback_result.code, code_verifier, redirect_uri);
        try self.storeTokens(tokens);

        return tokens;
    }

    /// Refresh tokens using a refresh_token grant.
    pub fn refreshTokens(self: *ProviderOAuth, tokens: OAuthTokens) !OAuthTokens {
        const refresh_token = tokens.refresh_token orelse return error.NoRefreshToken;

        var body_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer body_buf.deinit();
        const bw = body_buf.writer();

        try bw.print("grant_type=refresh_token&refresh_token={s}", .{refresh_token});
        try bw.print("&client_id={s}", .{self.config.client_id});
        if (self.config.client_secret) |cs| {
            try bw.print("&client_secret={s}", .{cs});
        }

        const headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
        };

        const fetch_result = http_client.httpPostForm(self.allocator, self.config.token_url, body_buf.items, &headers) catch return error.OAuthTokenRefreshFailed;
        defer self.allocator.free(fetch_result.body);

        if (fetch_result.status != .ok) return error.OAuthTokenRefreshFailed;
        if (fetch_result.body.len == 0) return error.OAuthTokenRefreshFailed;

        var new_tokens = try oauth_helpers.parseTokenResponse(fetch_result.body, self.allocator);
        if (new_tokens.refresh_token == null) {
            new_tokens.refresh_token = try self.allocator.dupe(u8, refresh_token);
        }

        return new_tokens;
    }

    /// Get stored tokens for this provider from disk.
    pub fn getStoredTokens(self: *ProviderOAuth) !OAuthTokens {
        const token_path = self.getTokenStorePath() catch return error.TokensNotFound;
        defer self.allocator.free(token_path);

        const file = std.fs.cwd().openFile(token_path, .{}) catch return error.TokensNotFound;
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0 or file_size > 1024 * 1024) return error.TokensNotFound;
        const buf = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buf);

        const bytes_read = try file.readAll(buf);
        const data = buf[0..bytes_read];

        var key_buf: [256]u8 = undefined;
        const key_prefix = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{self.config.provider_name}) catch return error.TokensNotFound;

        const idx = std.mem.indexOf(u8, data, key_prefix) orelse return error.TokensNotFound;
        var i: usize = idx + key_prefix.len;

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
                    access_token = try self.allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, fname, "refresh_token")) {
                    refresh_token = try self.allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, fname, "token_type")) {
                    token_type = try self.allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, fname, "scope")) {
                    scope = try self.allocator.dupe(u8, val);
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

    /// Remove stored tokens for this provider (logout).
    pub fn revokeTokens(self: *ProviderOAuth) !void {
        const token_path = self.getTokenStorePath() catch return;
        defer self.allocator.free(token_path);

        // Read existing file
        var existing_data: ?[]const u8 = null;
        if (std.fs.cwd().openFile(token_path, .{})) |file| {
            defer file.close();
            const file_size = file.getEndPos() catch 0;
            if (file_size > 0 and file_size < 1024 * 1024) {
                const contents = try self.allocator.alloc(u8, file_size);
                const bytes_read = file.readAll(contents) catch 0;
                if (bytes_read > 0) {
                    existing_data = contents[0..bytes_read];
                } else {
                    self.allocator.free(contents);
                }
            }
        } else |_| {}

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

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

                // Skip the provider being revoked
                if (std.mem.eql(u8, data[key_start..key_end], self.config.provider_name)) {
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

            defer self.allocator.free(data);
        }

        try w.writeAll("}");

        const out_file = std.fs.cwd().createFile(token_path, .{}) catch |err| {
            std.log.warn("Failed to update token store: {}", .{err});
            return;
        };
        defer out_file.close();
        try out_file.writeAll(buf.items);
    }

    pub fn deinit(self: *ProviderOAuth) void {
        _ = self;
    }

    // --- Private methods ---

    fn buildAuthorizationUrl(
        self: *ProviderOAuth,
        state: []const u8,
        code_challenge: []const u8,
        redirect_uri: []const u8,
    ) ![]const u8 {
        var url_builder = array_list_compat.ArrayList(u8).init(self.allocator);
        defer url_builder.deinit();

        try url_builder.writer().print("{s}?response_type=code&client_id={s}&redirect_uri={s}&state={s}&code_challenge={s}&code_challenge_method=S256", .{
            self.config.auth_url,
            self.config.client_id,
            redirect_uri,
            state,
            code_challenge,
        });

        if (self.config.scopes.len > 0) {
            try url_builder.writer().print("&scope={s}", .{self.config.scopes});
        }

        return try url_builder.toOwnedSlice();
    }

    fn exchangeCodeForTokens(self: *ProviderOAuth, code: []const u8, code_verifier: []const u8, redirect_uri: []const u8) !OAuthTokens {
        var body_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer body_buf.deinit();
        const bw = body_buf.writer();

        try bw.print("grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}", .{ code, redirect_uri, code_verifier });
        try bw.print("&client_id={s}", .{self.config.client_id});
        if (self.config.client_secret) |cs| {
            try bw.print("&client_secret={s}", .{cs});
        }

        const headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
        };

        const fetch_result = http_client.httpPostForm(self.allocator, self.config.token_url, body_buf.items, &headers) catch return error.OAuthTokenExchangeFailed;
        defer self.allocator.free(fetch_result.body);

        if (fetch_result.status != .ok) return error.OAuthTokenExchangeFailed;
        if (fetch_result.body.len == 0) return error.OAuthTokenExchangeFailed;

        return oauth_helpers.parseTokenResponse(fetch_result.body, self.allocator);
    }

    fn storeTokens(self: *ProviderOAuth, tokens: OAuthTokens) !void {
        const token_path = self.getTokenStorePath() catch |err| {
            std.log.warn("Cannot resolve token store path: {} — tokens kept in memory only", .{err});
            return;
        };
        defer self.allocator.free(token_path);

        const dir = std.fs.path.dirname(token_path) orelse return error.InvalidPath;
        std.fs.cwd().makePath(dir) catch |err| std.log.warn("failed to create token directory: {}", .{err});

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        // Read existing data to merge
        var existing_data: ?[]const u8 = null;
        if (std.fs.cwd().openFile(token_path, .{})) |file| {
            defer file.close();
            const file_size = file.getEndPos() catch 0;
            if (file_size > 0 and file_size < 1024 * 1024) {
                const contents = try self.allocator.alloc(u8, file_size);
                const bytes_read = file.readAll(contents) catch 0;
                if (bytes_read > 0) {
                    existing_data = contents[0..bytes_read];
                } else {
                    self.allocator.free(contents);
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

                // Skip old entry for same provider
                if (std.mem.eql(u8, data[key_start..key_end], self.config.provider_name)) {
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

            defer self.allocator.free(data);
        }

        if (!first) try w.writeAll(",");
        try w.print("\"{s}\":{{\"access_token\":\"{s}\",\"token_type\":\"{s}\"", .{ self.config.provider_name, tokens.access_token, tokens.token_type });
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
    }

    fn getTokenStorePath(self: *ProviderOAuth) ![]const u8 {
        const config_dir = try env_config.getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);
        return std.fs.path.join(self.allocator, &.{ config_dir, "provider_tokens.json" });
    }
};

// --- Tests ---

const testing = std.testing;

test "provider_oauth - getConfigForProvider returns openrouter config" {
    const config = getConfigForProvider("openrouter");
    try testing.expect(config != null);
    try testing.expect(std.mem.eql(u8, config.?.provider_name, "openrouter"));
    try testing.expect(config.?.redirect_port == 19877);
}

test "provider_oauth - getConfigForProvider returns null for unknown" {
    const config = getConfigForProvider("unknown");
    try testing.expect(config == null);
}

test "provider_oauth - calculateExpiresAt returns future timestamp" {
    const now = std.time.timestamp();
    const expires_at = calculateExpiresAt(60);
    try testing.expect(expires_at >= now + 60);
}

test "provider_oauth - isTokenExpired handles missing expiration" {
    const tokens = OAuthTokens{ .access_token = "token" };
    try testing.expect(!isTokenExpired(&tokens));
}
