const std = @import("std");
const builtin = @import("builtin");
const json = std.json;

const Allocator = std.mem.Allocator;

pub const MCPClient = struct {
    allocator: Allocator,
    servers: std.json.ObjectMap,
    tool_mappings: std.json.ObjectMap,
    connections: std.json.ObjectMap, // Store active connections

    pub fn init(allocator: Allocator) MCPClient {
        return MCPClient{
            .allocator = allocator,
            .servers = std.json.ObjectMap.init(allocator),
            .tool_mappings = std.json.ObjectMap.init(allocator),
            .connections = std.json.ObjectMap.init(allocator),
        };
    }

    pub fn deinit(self: *MCPClient) void {
        self.servers.deinit();
        self.tool_mappings.deinit();
        self.connections.deinit();
    }

    // Connect to MCP server with JSON-RPC 2.0
    pub fn connectToServer(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        std.log.info("Connecting to MCP server: {s}", .{name});

        // Check if OAuth authentication is required
        if (config.oauth_config) |oauth_config| {
            std.log.info("OAuth authentication required for server: {s}", .{name});

            // Try to get existing tokens first
            const existing_tokens = getOAuthTokens(self, name, oauth_config, self.allocator) catch |err| {
                if (err == error.TokensNotFound) {
                    std.log.info("No existing OAuth tokens found. Starting authentication flow...", .{});

                    // Start OAuth authentication
                    const auth_result = try authenticateWithOAuth(self, name, oauth_config, self.allocator);

                    if (!auth_result.success) {
                        std.log.err("OAuth authentication failed: {?s}", .{auth_result.error_message});
                        return error.OAuthAuthenticationFailed;
                    }

                    std.log.info("OAuth authentication successful", .{});
                } else {
                    return err;
                }
            };

            // If we have tokens, check if they need refresh
            if (existing_tokens) |tokens| {
                if (isTokenExpired(&tokens)) {
                    std.log.info("OAuth tokens expired. Refreshing...", .{});

                    const refreshed_tokens = try refreshOAuthTokens(self, name, oauth_config, tokens, self.allocator);

                    // Update headers with new tokens if HTTP transport
                    if (config.transport == .http and config.headers != null) {
                        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{refreshed_tokens.access_token});
                        defer self.allocator.free(auth_header);

                        try config.headers.?.put("Authorization", .{ .string = auth_header });
                    }
                } else {
                    // Tokens are valid, add to headers if HTTP transport
                    if (config.transport == .http and config.headers != null) {
                        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{tokens.access_token});
                        defer self.allocator.free(auth_header);

                        try config.headers.?.put("Authorization", .{ .string = auth_header });
                    }
                }
            }
        }

        // Initialize server info
        var server_info = std.json.ObjectMap.init(self.allocator);
        defer server_info.deinit();

        try server_info.put("name", .{ .string = name });
        try server_info.put("config", .{ .object = config.toJson(self.allocator) });
        try server_info.put("connected", .{ .boolean = false });
        try server_info.put("initialized", .{ .boolean = false });

        // Store server configuration
        try self.servers.put(name, server_info);

        // Create connection based on transport type
        const connection = switch (config.transport) {
            .stdio => try self.createStdioConnection(name, config),
            .sse => try self.createSSEConnection(name, config),
            .http => try self.createHTTPConnection(name, config),
            .websocket => try self.createWebSocketConnection(name, config),
        };

        // Store connection
        try self.connections.put(name, .{ .object = connection.toJson(self.allocator) });

        return connection;
    }

    // Send JSON-RPC 2.0 request
    pub fn sendRequest(self: *MCPClient, server_name: []const u8, request: MCPRequest) !MCPResponse {
        const connection_data = self.connections.get(server_name) orelse return error.ServerNotConnected;
        const connection = MCPConnection.fromJson(self.allocator, connection_data.object) catch return error.InvalidConnectionData;

        const json_request = request.toJson(self.allocator);
        defer self.allocator.free(json_request);

        const response_json = switch (connection.transport) {
            .stdio => try self.sendStdioRequest(connection, json_request),
            .sse => try self.sendSSERequest(connection, json_request),
            .http => try self.sendHTTPRequest(connection, json_request),
            .websocket => try self.sendWebSocketRequest(connection, json_request),
        };

        return MCPResponse.fromJson(self.allocator, response_json) catch return error.InvalidResponse;
    }

    // Discover tools from server
    pub fn discoverTools(self: *MCPClient, server_name: []const u8) ![]MCPTool {
        const request = MCPRequest{
            .jsonrpc = "2.0",
            .method = "tools/list",
            .params = .{},
            .id = self.generateRequestId(),
        };

        const response = try self.sendRequest(server_name, request);

        if (response.json_error) |err_obj| {
            const error_msg = if (err_obj.object.get("message")) |msg|
                msg.string orelse "Unknown error"
            else
                "Unknown error";
            std.log.err("Failed to discover tools: {s}", .{error_msg});
            return error.ToolDiscoveryFailed;
        }

        if (response.result) |result| {
            if (result.object.contains("tools")) {
                const tools_array = result.object.get("tools").?.array;
                var tools = try self.allocator.alloc(MCPTool, tools_array.items.len);
                defer self.allocator.free(tools);

                for (tools_array.items, 0..) |tool_obj, i| {
                    tools[i] = MCPTool.fromJson(self.allocator, tool_obj) catch unreachable;
                }

                return tools;
            }
        }

        return error.NoToolsFound;
    }

    // Execute tool on server
    pub fn executeTool(self: *MCPClient, server_name: []const u8, tool_name: []const u8, arguments: json.ObjectMap) !MCPToolResult {
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();

        try params_obj.put("name", .{ .string = tool_name });
        try params_obj.put("arguments", .{ .object = arguments });

        const request = MCPRequest{
            .jsonrpc = "2.0",
            .method = "tools/call",
            .params = .{ .object = params_obj },
            .id = self.generateRequestId(),
        };

        const response = try self.sendRequest(server_name, request);

        if (response.json_error) |err| {
            return MCPToolResult{
                .success = false,
                .error_message = err.message.?,
                .error_code = err.code orelse null,
            };
        }

        if (response.result) |result| {
            return MCPToolResult{
                .success = true,
                .result = result.object,
                .error_message = null,
                .error_code = null,
            };
        }

        return MCPToolResult{
            .success = false,
            .error_message = "No result from tool execution",
            .error_code = null,
        };
    }

    // Create stdio connection
    fn createStdioConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        const command = config.command orelse return error.StdioCommandRequired;
        const args = config.args orelse &[_][]const u8{};
        const env_vars = config.env_vars orelse &[_][]const u8{};

        // Prepare environment variables
        const env_map = try self.prepareEnvironment(env_vars);

        // Start the process
        const process = try self.spawnProcess(command, args, env_map);

        return MCPConnection{
            .transport = .stdio,
            .server_name = try self.allocator.dupe(u8, name),
            .command = command,
            .env_vars = env_vars,
            .args = args,
            .process = process,
            .initialized = false,
        };
    }

    // Create SSE connection
    fn createSSEConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        return MCPConnection{
            .transport = .sse,
            .server_name = try self.allocator.dupe(u8, name),
            .url = config.url orelse return error.SSEURLRequired,
            .headers = config.headers orelse std.json.ObjectMap.init(self.allocator),
            .initialized = false,
            .process = null,
        };
    }

    // Create HTTP connection
    fn createHTTPConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        return MCPConnection{
            .transport = .http,
            .server_name = try self.allocator.dupe(u8, name),
            .url = config.url orelse return error.HTTPURLRequired,
            .headers = config.headers orelse std.json.ObjectMap.init(self.allocator),
            .method = config.method orelse "POST",
            .initialized = false,
            .process = null,
        };
    }

    // Create WebSocket connection
    fn createWebSocketConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        return MCPConnection{
            .transport = .websocket,
            .server_name = try self.allocator.dupe(u8, name),
            .url = config.url orelse return error.WebSocketURLRequired,
            .headers = config.headers orelse std.json.ObjectMap.init(self.allocator),
            .initialized = false,
            .process = null,
        };
    }

    // Send stdio request
    fn sendStdioRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        const process_ptr = connection.process orelse return error.ProcessNotStarted;
        const process = @as(*std.process.Child, @ptrCast(@alignCast(process_ptr)));

        // Write request to stdin
        try process.stdin.?.writer().writeAll(request);
        try process.stdin.?.writer().writeByte('\n');

        // Read response from stdout
        var response_buf = std.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        var reader = process.stdout.?.reader();
        while (true) {
            const byte = reader.readByte() catch break;
            try response_buf.append(byte);
            // Simple delimiter - newline indicates end of JSON-RPC response
            if (byte == '\n') break;
        }

        // Parse JSON response
        const response_json = json.parseSlice(json.Value, response_buf.items, .{ .allocator = self.allocator }) catch |err| {
            std.log.err("Failed to parse stdio response: {!}", .{err});
            return json.Value{ .string = response_buf.items };
        };

        return response_json;
    }

    // Send SSE request
    fn sendSSERequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        _ = self;

        // For SSE, send HTTP request and parse response
        const url = connection.url orelse "unknown";
        std.log.info("Sending SSE request to {s}: {s}", .{ url, request });
        return json.Value{ .string = "sse request not implemented" };
    }

    // Send HTTP request
    fn sendHTTPRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        const allocator = self.allocator;

        // Parse the JSON-RPC request to get method and id
        const request_json = try json.parseSlice(json.Value, request, .{ .allocator = allocator });
        defer request_json.deinit();

        const method = blk: {
            if (request_json.object.get("method")) |m| {
                break :blk if (m == .string) m.string else "unknown";
            }
            break :blk "unknown";
        };

        const id = blk: {
            if (request_json.object.get("id")) |i| {
                break :blk if (i == .integer) i.integer else 0;
            }
            break :blk 0;
        };

        std.log.info("Sending HTTP {} request to {s}", .{ method, connection.url.? });

        // Build HTTP request
        const uri = try std.Uri.parse(connection.url.?);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var headers_buf = std.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        // Add custom headers from connection
        var header_iter = connection.headers.iterator();
        while (header_iter.next()) |entry| {
            try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*) });
        }

        var response_buf = std.ArrayList(u8).init(allocator);
        defer response_buf.deinit();

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = request,
            .extra_headers = headers_buf.items,
            .response_storage = .{ .dynamic = &response_buf },
        }) catch |err| {
            std.log.err("HTTP request failed: {!}", .{err});
            var error_obj = std.json.ObjectMap.init(allocator);
            try error_obj.put("code", .{ .integer = -32603 });
            try error_obj.put("message", .{ .string = try allocator.dupe(u8, @errorName(err)) });

            var response_obj = std.json.ObjectMap.init(allocator);
            try response_obj.put("jsonrpc", .{ .string = "2.0" });
            try response_obj.put("error", .{ .object = error_obj });
            try response_obj.put("id", .{ .integer = id });

            return .{ .object = response_obj };
        };

        if (fetch_result.status != .ok) {
            std.log.err("HTTP response status: {}", .{fetch_result.status});
            var error_obj2 = std.json.ObjectMap.init(allocator);
            try error_obj2.put("code", .{ .integer = -32001 });
            try error_obj2.put("message", .{ .string = try std.fmt.allocPrint(allocator, "Server returned {}", .{fetch_result.status}) });

            var response_obj2 = std.json.ObjectMap.init(allocator);
            try response_obj2.put("jsonrpc", .{ .string = "2.0" });
            try response_obj2.put("error", .{ .object = error_obj2 });
            try response_obj2.put("id", .{ .integer = id });

            return .{ .object = response_obj2 };
        }

        // Parse response
        const response_json = json.parseSlice(json.Value, response_buf.items, .{ .allocator = allocator }) catch |err| {
            std.log.err("Failed to parse response: {!}", .{err});
            return json.Value{ .string = response_buf.items };
        };

        return response_json;
    }

    // Send WebSocket request
    fn sendWebSocketRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        _ = self;

        // For WebSocket, send message over WebSocket
        const url = connection.url orelse "unknown";
        std.log.info("Sending WebSocket request to {s}: {s}", .{ url, request });
        return json.Value{ .string = "websocket request not implemented" };
    }

    // Prepare environment variables for process
    fn prepareEnvironment(self: *MCPClient, env_vars: []const []const u8) !std.process.EnvMap {
        const allocator = self.allocator;
        var env_map = std.process.getEnvMap(allocator) catch return error.EnvMapFailed;

        // Add custom environment variables
        for (env_vars) |env_var| {
            if (std.mem.indexOf(u8, env_var, "=")) |eq_pos| {
                const key = env_var[0..eq_pos];
                const value = env_var[eq_pos + 1 ..];
                try env_map.put(key, value);
            }
        }

        return env_map;
    }

    // Spawn a subprocess for stdio transport
    fn spawnProcess(self: *MCPClient, command: []const u8, args: []const []const u8, env_map: std.process.EnvMap) !*std.process.Child {
        const allocator = self.allocator;

        // Build argv array
        var argv = std.ArrayList([]const u8).init(allocator);
        defer argv.deinit();

        try argv.append(command);
        for (args) |arg| {
            try argv.append(arg);
        }

        // Spawn process with pipes for stdin/stdout
        const process = try std.process.Child.init(.{
            .allocator = allocator,
            .argv = argv.items,
            .env_map = &env_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        try process.spawn();

        // Allocate memory for the process pointer
        const process_ptr = try allocator.create(std.process.Child);
        process_ptr.* = process;

        return process_ptr;
    }

    // Generate unique request ID
    fn generateRequestId(self: *MCPClient) u64 {
        _ = self;
        return @intCast(std.time.timestamp() * 1000);
    }
};

// MCP Types
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

    pub fn toJson(self: MCPConnection, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("transport", .{ .string = @tagName(self.transport) });
        try obj.put("server_name", .{ .string = self.server_name });

        if (self.url) |url| {
            try obj.put("url", .{ .string = url });
        }

        if (self.command) |cmd| {
            try obj.put("command", .{ .string = cmd });
        }

        if (self.env_vars) |env| {
            var env_array = try allocator.alloc(json.Value, env.len);
            defer allocator.free(env_array);

            for (env, 0..) |env_var, i| {
                env_array[i] = .{ .string = env_var };
            }

            try obj.put("env_vars", .{ .array = env_array });
        }

        if (self.args) |args| {
            var args_array = try allocator.alloc(json.Value, args.len);
            defer allocator.free(args_array);

            for (args, 0..) |arg, i| {
                args_array[i] = .{ .string = arg };
            }

            try obj.put("args", .{ .array = args_array });
        }

        if (self.headers) |headers| {
            try obj.put("headers", .{ .object = headers });
        }

        try obj.put("method", .{ .string = self.method });
        try obj.put("initialized", .{ .boolean = self.initialized });
        try obj.put("process", .{ .null = @as(?*anyopaque, self.process) });

        return .{ .object = obj };
    }
};

pub const TransportType = enum {
    stdio,
    sse,
    http,
    websocket,
};

pub const MCPServerConfig = struct {
    transport: TransportType,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    env_vars: ?[][]const u8 = null,
    args: ?[][]const u8 = null,
    headers: ?std.json.ObjectMap = null,
    method: []const u8 = "POST",
    oauth_config: ?OAuthServerConfig = null,

    pub fn toJson(self: MCPServerConfig, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("transport", .{ .string = @tagName(self.transport) });

        if (self.command) |cmd| {
            try obj.put("command", .{ .string = cmd });
        }

        if (self.url) |url| {
            try obj.put("url", .{ .string = url });
        }

        if (self.env_vars) |env| {
            var env_array = try allocator.alloc(json.Value, env.len);
            defer allocator.free(env_array);

            for (env, 0..) |env_var, i| {
                env_array[i] = .{ .string = env_var };
            }

            try obj.put("env_vars", .{ .array = env_array });
        }

        if (self.args) |args| {
            var args_array = try allocator.alloc(json.Value, args.len);
            defer allocator.free(args_array);

            for (args, 0..) |arg, i| {
                args_array[i] = .{ .string = arg };
            }

            try obj.put("args", .{ .array = args_array });
        }

        if (self.headers) |headers| {
            try obj.put("headers", .{ .object = headers });
        }

        try obj.put("method", .{ .string = self.method });

        return .{ .object = obj };
    }
};

pub const MCPRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: json.Value,
    id: u64,

    pub fn toJson(self: MCPRequest, allocator: Allocator) ![]const u8 {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("jsonrpc", .{ .string = self.jsonrpc });
        try obj.put("method", .{ .string = self.method });
        try obj.put("params", self.params);
        try obj.put("id", .{ .integer = @intCast(self.id) });

        const string = try json.stringifyAlloc(allocator, .{ .object = obj });
        return string;
    }
};

pub const MCPResponse = struct {
    jsonrpc: []const u8,
    result: ?json.Value,
    json_error: ?json.Value, // Renamed from 'error' to avoid keyword conflict
    id: u64,
};

pub const MCPTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.Value,
    output_schema: ?json.Value,

    pub fn fromJson(allocator: Allocator, value: json.Value) !MCPTool {
        _ = allocator;
        const obj = value.object;

        return MCPTool{
            .name = obj.get("name").?.string orelse "",
            .description = obj.get("description").?.string orelse "",
            .input_schema = obj.get("inputSchema") orelse .null,
            .output_schema = obj.get("outputSchema"),
        };
    }
};

pub const MCPToolResult = struct {
    success: bool,
    result: ?json.Value,
    error_message: ?[]const u8,
    error_code: ?json.Value,
};

// =============================================================================
// OAuth Types and Storage (Phase 7: MCP Authentication)
// =============================================================================

/// OAuth token information
pub const OAuthTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    expires_at: ?i64 = null, // Unix timestamp
    scope: ?[]const u8 = null,
};

/// OAuth client information for dynamic registration
pub const OAuthClientInfo = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    registration_access_token: ?[]const u8 = null,
};

/// OAuth server configuration
pub const OAuthServerConfig = struct {
    auth_url: []const u8,
    token_url: []const u8,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    scopes: ?[]const u8 = null,
    redirect_uri: ?[]const u8 = null,
};

/// OAuth state for CSRF protection
pub const OAuthState = struct {
    server_name: []const u8,
    state: []const u8,
    redirect_uri: []const u8,
    created_at: i64,
};

/// OAuth authentication result
pub const OAuthResult = struct {
    success: bool,
    tokens: ?OAuthTokens = null,
    error_message: ?[]const u8 = null,
};

/// Check if token is expired
pub fn isTokenExpired(tokens: *const OAuthTokens) bool {
    if (tokens.expires_at) |expires| {
        const now = std.time.timestamp();
        return now >= expires;
    }
    // No expiration set, assume valid
    return false;
}

/// Calculate expiration timestamp from expires_in seconds
pub fn calculateExpiresAt(expires_in: u64) i64 {
    const now = std.time.timestamp();
    const future_time = @as(i64, @intCast(now)) + @as(i64, @intCast(expires_in));
    return future_time;
}

// ========== OAuth Authentication Functions ==========

/// Start OAuth authentication flow for a server
pub fn authenticateWithOAuth(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthResult {
    std.log.info("Starting OAuth authentication for server: {s}", .{server_name});

    // Generate random state for CSRF protection
    const state = try generateRandomState(allocator);
    defer allocator.free(state);

    // Generate PKCE code verifier and challenge
    const code_verifier = try generateCodeVerifier(allocator);
    defer allocator.free(code_verifier);
    const code_challenge = try generateCodeChallenge(code_verifier, allocator);
    defer allocator.free(code_challenge);

    // Build authorization URL
    const auth_url = try buildAuthorizationUrl(config, state, code_challenge, allocator);
    defer allocator.free(auth_url);

    // Start callback server
    const callback_server = try startCallbackServer(allocator);
    defer callback_server.deinit();

    // Open browser or show URL to user
    std.log.info("Please open this URL in your browser: {s}", .{auth_url});
    std.log.info("Waiting for OAuth callback on port {d}...", .{callback_server.port});

    // Wait for callback
    const callback_result = try waitForCallback(callback_server, state, allocator);
    defer allocator.free(callback_result.code);

    // Exchange authorization code for tokens
    const tokens = try exchangeCodeForTokens(config, callback_result.code, code_verifier, allocator);
    defer {
        if (tokens.access_token) |token| allocator.free(token);
        if (tokens.refresh_token) |token| allocator.free(token);
        if (tokens.scope) |scope| allocator.free(scope);
    }

    // Store tokens
    try storeOAuthTokens(server_name, tokens, allocator);

    return OAuthResult{
        .success = true,
        .tokens = tokens,
    };
}

/// Generate random state for CSRF protection
fn generateRandomState(allocator: Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var hex_state = try allocator.alloc(u8, random_bytes.len * 2);
    for (random_bytes, 0..) |byte, i| {
        const hex_pair = std.fmt.bytesToHex(&[_]u8{byte}, .lower);
        hex_state[i * 2] = hex_pair[0];
        hex_state[i * 2 + 1] = hex_pair[1];
    }

    return hex_state;
}

/// Generate PKCE code verifier
fn generateCodeVerifier(allocator: Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Base64 URL-safe encode without padding
    const base64_encoded = std.base64.url_safe_no_pad.Encoder.encode(&random_bytes);
    const verifier = try allocator.alloc(u8, base64_encoded.len);
    @memcpy(verifier, base64_encoded);

    return verifier;
}

/// Generate PKCE code challenge from verifier
fn generateCodeChallenge(verifier: []const u8, allocator: Allocator) ![]const u8 {
    // SHA256 hash of verifier
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    // Base64 URL-safe encode without padding
    const base64_encoded = std.base64.url_safe_no_pad.Encoder.encode(&hash);
    const challenge = try allocator.alloc(u8, base64_encoded.len);
    @memcpy(challenge, base64_encoded);

    return challenge;
}

/// Build authorization URL with OAuth parameters
fn buildAuthorizationUrl(
    config: OAuthServerConfig,
    state: []const u8,
    code_challenge: []const u8,
    allocator: Allocator,
) ![]const u8 {
    var url_builder = std.ArrayList(u8).init(allocator);
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

/// OAuth callback server configuration
const CallbackServer = struct {
    server: std.http.Server,
    port: u16,
    allocator: Allocator,

    fn deinit(self: *CallbackServer) void {
        self.server.deinit();
    }
};

/// Start HTTP server for OAuth callback
fn startCallbackServer(allocator: Allocator) !CallbackServer {
    const address = std.net.Address.parseIp("127.0.0.1", 0) catch unreachable;
    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    try server.listen(address);

    const actual_port = server.listen_address.getPort();

    std.log.info("OAuth callback server started on port {d}", .{actual_port});

    return CallbackServer{
        .server = server,
        .port = actual_port,
        .allocator = allocator,
    };
}

/// Callback result from OAuth server
const CallbackResult = struct {
    code: []const u8,
    state: []const u8,
};

/// Wait for OAuth callback with timeout
fn waitForCallback(
    callback_server: CallbackServer,
    expected_state: []const u8,
    allocator: Allocator,
) !CallbackResult {
    const timeout_ms = 5 * 60 * 1000; // 5 minutes
    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        // Accept connection with timeout
        var connection = callback_server.server.accept(.{ .allocator = allocator }) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(100 * std.time.ns_per_ms); // 100ms
                continue;
            }
            return err;
        };
        defer connection.deinit();

        // Read request
        var request = connection.receiveHead(.{ .allocator = allocator }) catch continue;
        defer request.deinit();

        // Check if this is our callback
        if (std.mem.eql(u8, request.head.target, "/mcp/oauth/callback")) {
            // Parse query parameters
            const query_start = std.mem.indexOf(u8, request.head.target, "?") orelse {
                try sendErrorResponse(connection, 400, "Missing query parameters");
                continue;
            };
            const query_string = request.head.target[query_start + 1 ..];

            var code: ?[]const u8 = null;
            var state: ?[]const u8 = null;
            var error_param: ?[]const u8 = null;

            // Parse query string
            var iter = std.mem.splitScalar(u8, query_string, '&');
            while (iter.next()) |param| {
                var kv_iter = std.mem.splitScalar(u8, param, '=');
                const key = kv_iter.first();
                const value = kv_iter.next() orelse continue;

                if (std.mem.eql(u8, key, "code")) {
                    code = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "state")) {
                    state = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "error")) {
                    error_param = try allocator.dupe(u8, value);
                }
            }

            // Check for OAuth error
            if (error_param != null) {
                try sendErrorResponse(connection, 400, "OAuth error");
                return error.OAuthError;
            }

            // Validate state
            if (state == null or !std.mem.eql(u8, state.?, expected_state)) {
                try sendErrorResponse(connection, 400, "Invalid state parameter");
                return error.InvalidState;
            }

            // Check for code
            if (code == null) {
                try sendErrorResponse(connection, 400, "Missing authorization code");
                return error.MissingCode;
            }

            // Send success response
            try sendSuccessResponse(connection);

            return CallbackResult{
                .code = code.?,
                .state = state.?,
            };
        }

        // Not our callback, send 404
        try sendNotFoundResponse(connection);
    }

    return error.Timeout;
}

/// Send error response
fn sendErrorResponse(connection: std.http.Server.Connection, status: u16, message: []const u8) !void {
    const response = try std.fmt.allocPrint(connection.allocator,
        \\<html>
        \\<head><title>Error {d}</title></head>
        \\<body>
        \\<h1>Error {d}</h1>
        \\<p>{s}</p>
        \\</body>
        \\</html>
    , .{ status, status, message });
    defer connection.allocator.free(response);

    try connection.writeAll(response);
    try connection.finish();
}

/// Send success response
fn sendSuccessResponse(connection: std.http.Server.Connection) !void {
    const response =
        \\<html>
        \\<head><title>Authentication Successful</title></head>
        \\<body>
        \\<h1>Authentication Successful</h1>
        \\<p>You can close this window and return to the application.</p>
        \\</body>
        \\</html>
    ;

    try connection.writeAll(response);
    try connection.finish();
}

/// Send 404 response
fn sendNotFoundResponse(connection: std.http.Server.Connection) !void {
    const response =
        \\<html>
        \\<head><title>404 Not Found</title></head>
        \\<body>
        \\<h1>404 Not Found</h1>
        \\</body>
        \\</html>
    ;

    try connection.writeAll(response);
    try connection.finish();
}

/// Exchange authorization code for access token
fn exchangeCodeForTokens(
    config: OAuthServerConfig,
    code: []const u8,
    code_verifier: []const u8,
    allocator: Allocator,
) !OAuthTokens {
    var headers = std.http.Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "application/x-www-form-urlencoded");
    try headers.append("Accept", "application/json");

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

    const writer = body.writer();
    try writer.print("grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&code_verifier={s}", .{
        code,
        config.redirect_uri orelse "http://127.0.0.1:19876/mcp/oauth/callback",
        config.client_id orelse return error.MissingClientId,
        code_verifier,
    });

    if (config.client_secret) |secret| {
        try writer.print("&client_secret={s}", .{secret});
    }

    // Make token request
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var request = try client.request(.POST, config.token_url, headers, .{});
    defer request.deinit();

    try request.writeAll(body.items);
    try request.finish();

    const response = try request.readAllBodyAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(response);

    // Parse JSON response
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response);
    defer tree.deinit();

    const root = tree.root;

    const access_token = root.object.get("access_token") orelse return error.MissingAccessToken;
    const token_type = root.object.get("token_type") orelse .{ .string = "Bearer" };
    const expires_in = root.object.get("expires_in");
    const refresh_token = root.object.get("refresh_token");
    const scope = root.object.get("scope");

    var tokens = OAuthTokens{
        .access_token = try allocator.dupe(u8, access_token.string orelse return error.InvalidAccessToken),
        .token_type = try allocator.dupe(u8, token_type.string orelse "Bearer"),
    };

    if (expires_in) |expires| {
        if (expires.integer) |expires_int| {
            tokens.expires_in = @as(u64, @intCast(expires_int));
            tokens.expires_at = calculateExpiresAt(tokens.expires_in.?);
        }
    }

    if (refresh_token) |refresh| {
        if (refresh.string) |refresh_str| {
            tokens.refresh_token = try allocator.dupe(u8, refresh_str);
        }
    }

    if (scope) |scope_val| {
        if (scope_val.string) |scope_str| {
            tokens.scope = try allocator.dupe(u8, scope_str);
        }
    }

    return tokens;
}

/// Store OAuth tokens for a server
fn storeOAuthTokens(server_name: []const u8, tokens: OAuthTokens, allocator: Allocator) !void {
    // TODO: Implement token storage (file-based or in-memory cache)
    // For now, just log the tokens
    std.log.info("Stored tokens for server '{s}': access_token={s}, expires_in={?d}, refresh_token={?s}", .{
        server_name,
        tokens.access_token,
        tokens.expires_in,
        tokens.refresh_token,
    });
}

/// Refresh expired OAuth tokens
pub fn refreshOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    tokens: OAuthTokens,
    allocator: Allocator,
) !OAuthTokens {
    if (tokens.refresh_token == null) {
        return error.NoRefreshToken;
    }

    std.log.info("Refreshing tokens for server: {s}", .{server_name});

    var headers = std.http.Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "application/x-www-form-urlencoded");
    try headers.append("Accept", "application/json");

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

    const writer = body.writer();
    try writer.print("grant_type=refresh_token&refresh_token={s}&client_id={s}", .{
        tokens.refresh_token.?,
        config.client_id orelse return error.MissingClientId,
    });

    if (config.client_secret) |secret| {
        try writer.print("&client_secret={s}", .{secret});
    }

    // Make refresh request
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var request = try client.request(.POST, config.token_url, headers, .{});
    defer request.deinit();

    try request.writeAll(body.items);
    try request.finish();

    const response = try request.readAllBodyAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(response);

    // Parse JSON response
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response);
    defer tree.deinit();

    const root = tree.root;

    const access_token = root.object.get("access_token") orelse return error.MissingAccessToken;
    const token_type = root.object.get("token_type") orelse .{ .string = "Bearer" };
    const expires_in = root.object.get("expires_in");
    const refresh_token = root.object.get("refresh_token") orelse tokens.refresh_token; // Use new refresh token if provided
    const scope = root.object.get("scope") orelse tokens.scope;

    var new_tokens = OAuthTokens{
        .access_token = try allocator.dupe(u8, access_token.string orelse return error.InvalidAccessToken),
        .token_type = try allocator.dupe(u8, token_type.string orelse "Bearer"),
    };

    if (expires_in) |expires| {
        if (expires.integer) |expires_int| {
            new_tokens.expires_in = @as(u64, @intCast(expires_int));
            new_tokens.expires_at = calculateExpiresAt(new_tokens.expires_in.?);
        }
    }

    if (refresh_token) |refresh| {
        if (refresh.string) |refresh_str| {
            new_tokens.refresh_token = try allocator.dupe(u8, refresh_str);
        }
    }

    if (scope) |scope_val| {
        if (scope_val.string) |scope_str| {
            new_tokens.scope = try allocator.dupe(u8, scope_str);
        }
    }

    // Store new tokens
    try storeOAuthTokens(server_name, new_tokens, allocator);

    return new_tokens;
}

/// Get OAuth tokens for a server, refreshing if expired
pub fn getOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthTokens {
    // TODO: Load tokens from storage
    // For now, return error indicating tokens need to be obtained
    return error.TokensNotFound;
}
