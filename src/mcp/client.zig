const std = @import("std");
const array_list_compat = @import("array_list_compat");
const transport = @import("mcp_transport");
const oauth = @import("mcp_oauth");

const json = std.json;
const Allocator = std.mem.Allocator;

pub const MCPConnection = transport.MCPConnection;
pub const TransportType = transport.TransportType;
pub const OAuthTokens = oauth.OAuthTokens;
pub const OAuthClientInfo = oauth.OAuthClientInfo;
pub const OAuthServerConfig = oauth.OAuthServerConfig;
pub const OAuthState = oauth.OAuthState;
pub const OAuthResult = oauth.OAuthResult;

pub const MCPClient = struct {
    allocator: Allocator,
    servers: std.json.ObjectMap,
    tool_mappings: std.json.ObjectMap,
    connections: std.StringHashMap(MCPConnection),
    next_request_id: std.atomic.Value(u64),
    owned_json_values: array_list_compat.ArrayList(json.Value),

    pub fn init(allocator: Allocator) MCPClient {
        return MCPClient{
            .allocator = allocator,
            .servers = std.json.ObjectMap.init(allocator),
            .tool_mappings = std.json.ObjectMap.init(allocator),
            .connections = std.StringHashMap(MCPConnection).init(allocator),
            .next_request_id = std.atomic.Value(u64).init(1),
            .owned_json_values = array_list_compat.ArrayList(json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *MCPClient) void {
        for (self.owned_json_values.items) |val| {
            transport.deinitJsonValue(self.allocator, val);
        }
        self.owned_json_values.deinit();

        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            var conn = entry.value_ptr;
            conn.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();

        self.servers.deinit();
        self.tool_mappings.deinit();
    }

    /// Connect to MCP server with JSON-RPC 2.0.
    pub fn connectToServer(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        var config_mut = config;
        std.log.info("Connecting to MCP server: {s}", .{name});

        if (config_mut.oauth_config) |oauth_config| {
            std.log.info("OAuth authentication required for server: {s}", .{name});

            var existing_tokens: ?OAuthTokens = null;
            if (getOAuthTokens(self, name, oauth_config, self.allocator)) |tokens| {
                existing_tokens = tokens;
            } else |err| {
                if (err == error.TokensNotFound) {
                    std.log.info("No existing OAuth tokens found. Starting authentication flow...", .{});

                    const auth_result = try authenticateWithOAuth(self, name, oauth_config, self.allocator);

                    if (!auth_result.success) {
                        std.log.err("OAuth authentication failed: {?s}", .{auth_result.error_message});
                        return error.OAuthAuthenticationFailed;
                    }

                    std.log.info("OAuth authentication successful", .{});
                } else {
                    return err;
                }
            }

            if (existing_tokens) |tokens| {
                if (isTokenExpired(&tokens)) {
                    std.log.info("OAuth tokens expired. Refreshing...", .{});

                    const refreshed_tokens = try refreshOAuthTokens(self, name, oauth_config, tokens, self.allocator);

                    if (config_mut.transport == .http) {
                        if (config_mut.headers == null) {
                            config_mut.headers = std.json.ObjectMap.init(self.allocator);
                        }
                        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{refreshed_tokens.access_token});
                        defer self.allocator.free(auth_header);

                        try config_mut.headers.?.put("Authorization", .{ .string = auth_header });
                    }
                } else {
                    if (config_mut.transport == .http) {
                        if (config_mut.headers == null) {
                            config_mut.headers = std.json.ObjectMap.init(self.allocator);
                        }
                        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{tokens.access_token});
                        defer self.allocator.free(auth_header);

                        try config_mut.headers.?.put("Authorization", .{ .string = auth_header });
                    }
                }
            }
        }

        var server_info = std.json.ObjectMap.init(self.allocator);

        try server_info.put("name", .{ .string = name });
        try server_info.put("config", try config_mut.toJson(self.allocator));
        try server_info.put("connected", .{ .bool = false });
        try server_info.put("initialized", .{ .bool = false });

        try self.servers.put(name, .{ .object = server_info });

        const connection = switch (config_mut.transport) {
            .stdio => try transport.createStdioConnection(
                self.allocator,
                name,
                config_mut.command orelse return error.StdioCommandRequired,
                config_mut.args,
                config_mut.env_vars,
            ),
            .sse => try transport.createSSEConnection(
                self.allocator,
                name,
                config_mut.url orelse return error.SSEURLRequired,
                config_mut.headers,
            ),
            .http => try transport.createHTTPConnection(
                self.allocator,
                name,
                config_mut.url orelse return error.HTTPURLRequired,
                config_mut.headers,
                config_mut.method,
            ),
            .websocket => try transport.createWebSocketConnection(
                self.allocator,
                name,
                config_mut.url orelse return error.WebSocketURLRequired,
                config_mut.headers,
            ),
        };

        const name_owned = try self.allocator.dupe(u8, name);
        try self.connections.put(name_owned, connection);

        if (connection.transport == .stdio) {
            self.initializeServer(name) catch |err| {
                std.log.warn("MCP initialize failed for '{s}': {}", .{ name, err });
            };
        }

        if (self.servers.getPtr(name)) |info| {
            if (info.* == .object) {
                try info.*.object.put("connected", .{ .bool = true });
                try info.*.object.put("initialized", .{ .bool = true });
            }
        }

        return connection;
    }

    /// Send MCP initialize handshake (initialize request + initialized notification).
    fn initializeServer(self: *MCPClient, server_name: []const u8) !void {
        var params = json.ObjectMap.init(self.allocator);
        try params.put("protocolVersion", .{ .string = "2024-11-05" });

        var client_info = json.ObjectMap.init(self.allocator);
        try client_info.put("name", .{ .string = "crushcode" });
        try client_info.put("version", .{ .string = "0.27.0" });
        try params.put("clientInfo", .{ .object = client_info });

        var capabilities = json.ObjectMap.init(self.allocator);
        try capabilities.put("tools", .{ .object = json.ObjectMap.init(self.allocator) });
        try params.put("capabilities", .{ .object = capabilities });

        const init_request = MCPRequest{
            .jsonrpc = "2.0",
            .method = "initialize",
            .params = .{ .object = params },
            .id = self.generateRequestId(),
        };

        const init_response = self.sendRequest(server_name, init_request) catch |err| {
            std.log.warn("MCP initialize request failed: {}", .{err});
            return err;
        };

        if (init_response.json_error) |err_obj| {
            if (err_obj == .object) {
                if (err_obj.object.get("message")) |m| {
                    const msg = if (m == .string) m.string else "unknown";
                    std.log.warn("MCP initialize error: {s}", .{msg});
                } else {
                    std.log.warn("MCP initialize error: unknown", .{});
                }
            } else {
                std.log.warn("MCP initialize error: unknown", .{});
            }
            return error.InitializationFailed;
        }

        std.log.info("MCP server '{s}' initialized successfully", .{server_name});

        const notif_json = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","method":"notifications/initialized","params":{{}}}}
        , .{});
        defer self.allocator.free(notif_json);

        if (self.connections.getPtr(server_name)) |conn| {
            if (conn.transport == .stdio and conn.process != null) {
                transport.sendStdioRaw(conn, notif_json) catch |err| {
                    std.log.warn("Failed to send initialized notification: {}", .{err});
                };
            }
        }
    }

    /// Send JSON-RPC 2.0 request.
    pub fn sendRequest(self: *MCPClient, server_name: []const u8, request: MCPRequest) !MCPResponse {
        const connection = self.connections.getPtr(server_name) orelse return error.ServerNotConnected;

        const json_request = try request.toJson(self.allocator);
        defer self.allocator.free(json_request);

        const response_json = switch (connection.transport) {
            .stdio => try transport.sendStdioRequest(self.allocator, &self.owned_json_values, connection.*, json_request),
            .sse => try transport.sendSSERequest(self.allocator, connection.*, json_request),
            .http => try transport.sendHTTPRequest(self.allocator, connection.*, json_request),
            .websocket => try transport.sendWebSocketRequest(self.allocator, connection.*, json_request),
        };

        return MCPResponse.fromJson(self.allocator, response_json) catch return error.InvalidResponse;
    }

    /// Discover tools from server.
    pub fn discoverTools(self: *MCPClient, server_name: []const u8) ![]MCPTool {
        const empty_params = json.ObjectMap.init(self.allocator);
        const request = MCPRequest{
            .jsonrpc = "2.0",
            .method = "tools/list",
            .params = .{ .object = empty_params },
            .id = self.generateRequestId(),
        };

        const response = try self.sendRequest(server_name, request);

        if (response.json_error) |err_obj| {
            const error_msg = if (err_obj.object.get("message")) |msg|
                if (msg == .string) msg.string else "Unknown error"
            else
                "Unknown error";
            std.log.err("Failed to discover tools: {s}", .{error_msg});
            return error.ToolDiscoveryFailed;
        }

        if (response.result) |result| {
            if (result.object.contains("tools")) {
                const tools_array = result.object.get("tools").?.array;
                const tools = try self.allocator.alloc(MCPTool, tools_array.items.len);

                for (tools_array.items, 0..) |tool_obj, i| {
                    tools[i] = MCPTool.fromJson(self.allocator, tool_obj) catch unreachable;
                }

                return tools;
            }
        }

        return error.NoToolsFound;
    }

    /// Execute tool on server.
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
            const error_obj = if (err == .object) err.object else return error.InvalidResponse;
            return MCPToolResult{
                .success = false,
                .result = null,
                .error_message = if (error_obj.get("message")) |message|
                    if (message == .string) message.string else "Unknown error"
                else
                    "Unknown error",
                .error_code = error_obj.get("code"),
            };
        }

        if (response.result) |result| {
            return MCPToolResult{
                .success = true,
                .result = result,
                .error_message = null,
                .error_code = null,
            };
        }

        return MCPToolResult{
            .success = false,
            .result = null,
            .error_message = "No result from tool execution",
            .error_code = null,
        };
    }

    fn generateRequestId(self: *MCPClient) u64 {
        return self.next_request_id.fetchAdd(1, .monotonic);
    }
};

// MCP Types
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

        try obj.put("transport", .{ .string = @tagName(self.transport) });

        if (self.command) |cmd| {
            try obj.put("command", .{ .string = cmd });
        }

        if (self.url) |url| {
            try obj.put("url", .{ .string = url });
        }

        if (self.env_vars) |env| {
            var env_array = json.Array.init(allocator);
            for (env) |env_var| {
                try env_array.append(.{ .string = env_var });
            }

            try obj.put("env_vars", .{ .array = env_array });
        }

        if (self.args) |args| {
            var args_array = json.Array.init(allocator);
            for (args) |arg| {
                try args_array.append(.{ .string = arg });
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
        const params_str: []const u8 = switch (self.params) {
            .null => "null",
            else => try std.fmt.allocPrint(allocator, "{f}", .{json.fmt(self.params, .{})}),
        };

        const result = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"{s}","method":"{s}","params":{s},"id":{d}}}
        , .{ self.jsonrpc, self.method, params_str, self.id });

        if (self.params != .null) allocator.free(params_str);

        return result;
    }
};

pub const MCPResponse = struct {
    jsonrpc: []const u8,
    result: ?json.Value,
    json_error: ?json.Value,
    id: u64,

    pub fn fromJson(allocator: Allocator, value: json.Value) !MCPResponse {
        _ = allocator;
        const obj = if (value == .object) value.object else return error.InvalidResponse;

        return MCPResponse{
            .jsonrpc = if (obj.get("jsonrpc")) |jsonrpc_value|
                if (jsonrpc_value == .string) jsonrpc_value.string else "2.0"
            else
                "2.0",
            .result = obj.get("result"),
            .json_error = obj.get("error"),
            .id = if (obj.get("id")) |id_value|
                if (id_value == .integer) @intCast(id_value.integer) else 0
            else
                0,
        };
    }
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
            .name = if (obj.get("name")) |name_value| if (name_value == .string) name_value.string else "" else "",
            .description = if (obj.get("description")) |description_value| if (description_value == .string) description_value.string else "" else "",
            .input_schema = obj.get("inputSchema") orelse .{ .null = {} },
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

pub fn isTokenExpired(tokens: *const OAuthTokens) bool {
    return oauth.isTokenExpired(tokens);
}

pub fn calculateExpiresAt(expires_in: u64) i64 {
    return oauth.calculateExpiresAt(expires_in);
}

pub fn authenticateWithOAuth(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthResult {
    return oauth.authenticateWithOAuth(self, server_name, config, allocator);
}

pub fn refreshOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    tokens: OAuthTokens,
    allocator: Allocator,
) !OAuthTokens {
    return oauth.refreshOAuthTokens(self, server_name, config, tokens, allocator);
}

pub fn getOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthTokens {
    return oauth.getOAuthTokens(self, server_name, config, allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "MCPClient - init and deinit" {
    var client = MCPClient.init(testing.allocator);
    defer client.deinit();
    try testing.expect(client.connections.count() == 0);
    try testing.expect(client.servers.count() == 0);
}

test "MCPClient - connectToServer stdio with mcp-server-filesystem" {
    const e2e_env = std.process.getEnvVarOwned(testing.allocator, "RUN_MCP_E2E_TESTS") catch null;
    if (e2e_env) |v| testing.allocator.free(v) else return error.SkipZigTest;

    var client = MCPClient.init(testing.allocator);
    defer client.deinit();

    const tmp_dir = "/tmp/crushcode-mcp-test";

    const server_path = std.process.getEnvVarOwned(testing.allocator, "MCP_SERVER_FILESYSTEM_PATH") catch
        try std.fmt.allocPrint(testing.allocator, "mcp-server-filesystem", .{});
    defer testing.allocator.free(server_path);

    var server_args = array_list_compat.ArrayList([]const u8).init(testing.allocator);
    defer server_args.deinit();
    try server_args.append(tmp_dir);

    const config = MCPServerConfig{
        .transport = .stdio,
        .command = server_path,
        .args = server_args.items,
    };

    std.fs.cwd().makePath(tmp_dir) catch {};

    _ = try client.connectToServer("filesystem", config);

    const stored_conn = client.connections.getPtr("filesystem") orelse
        return error.ServerNotConnected;
    try testing.expect(stored_conn.transport == .stdio);
    try testing.expect(stored_conn.process != null);

    const tools = try client.discoverTools("filesystem");
    defer testing.allocator.free(tools);

    try testing.expect(tools.len > 0);
    std.log.info("Discovered {d} tools from MCP filesystem server", .{tools.len});
    for (tools[0..@min(3, tools.len)]) |tool| {
        std.log.info("  - {s}", .{tool.name});
    }

    var found_list_directory = false;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, "list_directory")) found_list_directory = true;
    }
    try testing.expect(found_list_directory);

    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/hello.txt", .{});
        defer f.close();
        try f.writeAll("Hello from Crushcode MCP test!");
    }

    {
        var list_args = json.ObjectMap.init(testing.allocator);
        defer list_args.deinit();
        try list_args.put("path", .{ .string = tmp_dir });
        const result = try client.executeTool("filesystem", "list_directory", list_args);
        try testing.expect(result.success);
    }

    {
        var read_args = json.ObjectMap.init(testing.allocator);
        defer read_args.deinit();
        try read_args.put("path", .{ .string = tmp_dir ++ "/hello.txt" });
        const result = try client.executeTool("filesystem", "read_text_file", read_args);
        try testing.expect(result.success);
    }

    std.fs.cwd().deleteFile(tmp_dir ++ "/hello.txt") catch {};
    std.fs.cwd().deleteDir(tmp_dir) catch {};
}

test "MCPRequest - toJson" {
    const req = MCPRequest{
        .jsonrpc = "2.0",
        .method = "tools/list",
        .params = .{ .null = {} },
        .id = 42,
    };

    const json_str = try req.toJson(testing.allocator);
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"method\":\"tools/list\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"id\":42") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "null") != null);
}

test "MCPRequest - toJson with object params" {
    var params = json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("path", .{ .string = "/tmp/test" });

    const req = MCPRequest{
        .jsonrpc = "2.0",
        .method = "tools/call",
        .params = .{ .object = params },
        .id = 99,
    };

    const json_str = try req.toJson(testing.allocator);
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "/tmp/test") != null);
}

test "MCPResponse - fromJson" {
    const response_str = "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}";
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response_str, .{});
    defer parsed.deinit();

    const response = try MCPResponse.fromJson(testing.allocator, parsed.value);
    try testing.expect(std.mem.eql(u8, response.jsonrpc, "2.0"));
    try testing.expect(response.result != null);
    try testing.expect(response.json_error == null);
    try testing.expect(response.id == 1);
}

test "MCPTool - fromJson" {
    const tool_json = "{\"name\":\"read_file\",\"description\":\"Read a file\",\"inputSchema\":{\"type\":\"object\"}}";
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, tool_json, .{});
    defer parsed.deinit();

    const tool = try MCPTool.fromJson(testing.allocator, parsed.value);
    try testing.expect(std.mem.eql(u8, tool.name, "read_file"));
    try testing.expect(std.mem.eql(u8, tool.description, "Read a file"));
}
