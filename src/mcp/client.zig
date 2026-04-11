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

    fn cloneJsonValue(allocator: Allocator, value: json.Value) !json.Value {
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

    fn jsonString(value: json.Value) ?[]const u8 {
        return if (value == .string) value.string else null;
    }

    fn jsonInteger(value: json.Value) ?i64 {
        return if (value == .integer) value.integer else null;
    }

    // Connect to MCP server with JSON-RPC 2.0
    pub fn connectToServer(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        var config_mut = config;
        std.log.info("Connecting to MCP server: {s}", .{name});

        // Check if OAuth authentication is required
        if (config_mut.oauth_config) |oauth_config| {
            std.log.info("OAuth authentication required for server: {s}", .{name});

            // Try to get existing tokens first
            var existing_tokens: ?OAuthTokens = null;
            if (getOAuthTokens(self, name, oauth_config, self.allocator)) |tokens| {
                existing_tokens = tokens;
            } else |err| {
                if (err == error.TokensNotFound) {
                    std.log.info("No existing OAuth tokens found. Starting authentication flow...", .{});

                    // Start OAuth authentication
                    const auth_result = try authenticateWithOAuth(self, name, oauth_config, self.allocator);

                    if (!auth_result.success) {
                        std.log.err("OAuth authentication failed: {?s}", .{auth_result.error_message});
                        return error.OAuthAuthenticationFailed;
                    }

                    std.log.info("OAuth authentication successful", .{});
                    // Continue with connection after successful OAuth
                } else {
                    return err;
                }
            }

            // If we have tokens, check if they need refresh
            if (existing_tokens) |tokens| {
                if (isTokenExpired(&tokens)) {
                    std.log.info("OAuth tokens expired. Refreshing...", .{});

                    const refreshed_tokens = try refreshOAuthTokens(self, name, oauth_config, tokens, self.allocator);

                    // Update headers with new tokens if HTTP transport
                    if (config_mut.transport == .http) {
                        if (config_mut.headers == null) {
                            config_mut.headers = std.json.ObjectMap.init(self.allocator);
                        }
                        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{refreshed_tokens.access_token});
                        defer self.allocator.free(auth_header);

                        try config_mut.headers.?.put("Authorization", .{ .string = auth_header });
                    }
                } else {
                    // Tokens are valid, add to headers if HTTP transport
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

        // Initialize server info
        var server_info = std.json.ObjectMap.init(self.allocator);

        try server_info.put("name", .{ .string = name });
        try server_info.put("config", try config_mut.toJson(self.allocator));
        try server_info.put("connected", .{ .bool = false });
        try server_info.put("initialized", .{ .bool = false });

        // Store server configuration
        try self.servers.put(name, .{ .object = server_info });

        // Create connection based on transport type
        const connection = switch (config_mut.transport) {
            .stdio => try self.createStdioConnection(name, config_mut),
            .sse => try self.createSSEConnection(name, config_mut),
            .http => try self.createHTTPConnection(name, config_mut),
            .websocket => try self.createWebSocketConnection(name, config_mut),
        };

        // Store connection
        try self.connections.put(name, try connection.toJson(self.allocator));

        return connection;
    }

    // Send JSON-RPC 2.0 request
    pub fn sendRequest(self: *MCPClient, server_name: []const u8, request: MCPRequest) !MCPResponse {
        const connection_data = self.connections.get(server_name) orelse return error.ServerNotConnected;
        const connection = MCPConnection.fromJson(self.allocator, connection_data) catch return error.InvalidConnectionData;

        const json_request = try request.toJson(self.allocator);
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
            .params = .{ .null = {} },
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
                var tools = try self.allocator.alloc(MCPTool, tools_array.items.len);

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
            .error_message = "No result from tool execution",
            .error_code = null,
        };
    }

    // Create stdio connection
    fn createStdioConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        const command = config.command orelse return error.StdioCommandRequired;
        const args: ?[][]const u8 = config.args;
        const env_vars: ?[][]const u8 = config.env_vars;

        // Prepare environment variables
        const env_map = if (env_vars) |ev| try self.prepareEnvironment(ev) else try self.prepareEnvironment(&[_][]const u8{});

        // Start the process
        const spawn_args = args orelse &[_][]const u8{};
        const process = try self.spawnProcess(command, spawn_args, env_map);

        return MCPConnection{
            .transport = .stdio,
            .server_name = try self.allocator.dupe(u8, name),
            .command = command,
            .env_vars = env_vars,
            .args = args,
            .headers = std.json.ObjectMap.init(self.allocator),
            .method = "stdio",
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
            .method = "GET",
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
            .method = config.method,
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
            .method = "GET",
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
        var response_json = json.parseFromSlice(json.Value, self.allocator, response_buf.items, .{}) catch |err| {
            std.log.err("Failed to parse stdio response: {!}", .{err});
            return json.Value{ .string = response_buf.items };
        };
        defer response_json.deinit();

        return try cloneJsonValue(self.allocator, response_json.value);
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
            if (entry.value_ptr.* == .string) {
                try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*.string) });
            }
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
        var response_json = json.parseFromSlice(json.Value, allocator, response_buf.items, .{}) catch |err| {
            std.log.err("Failed to parse response: {!}", .{err});
            return json.Value{ .string = response_buf.items };
        };
        defer response_json.deinit();

        return try cloneJsonValue(allocator, response_json.value);
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
        var process = std.process.Child.init(argv.items, allocator);
        process.env_map = &env_map;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

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

        try obj.put("transport", .{ .string = @tagName(self.transport) });
        try obj.put("server_name", .{ .string = self.server_name });

        if (self.url) |url| {
            try obj.put("url", .{ .string = url });
        }

        if (self.command) |cmd| {
            try obj.put("command", .{ .string = cmd });
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

        try obj.put("headers", .{ .object = self.headers });

        try obj.put("method", .{ .string = self.method });
        try obj.put("initialized", .{ .bool = self.initialized });
        try obj.put("process", .{ .null = {} });

        return .{ .object = obj };
    }

    pub fn fromJson(allocator: Allocator, value: json.Value) !MCPConnection {
        const obj = if (value == .object) value.object else return error.InvalidConnectionData;
        const transport_str = MCPClient.jsonString(obj.get("transport") orelse return error.InvalidConnectionData) orelse return error.InvalidConnectionData;
        const transport = std.meta.stringToEnum(TransportType, transport_str) orelse return error.InvalidConnectionData;

        var headers = json.ObjectMap.init(allocator);
        if (obj.get("headers")) |headers_value| {
            if (headers_value != .object) return error.InvalidConnectionData;
            headers = switch (try MCPClient.cloneJsonValue(allocator, headers_value)) {
                .object => |cloned| cloned,
                else => unreachable,
            };
        }

        var env_vars: ?[][]const u8 = null;
        if (obj.get("env_vars")) |env_value| {
            if (env_value != .array) return error.InvalidConnectionData;
            var env_list = std.ArrayList([]const u8).init(allocator);
            for (env_value.array.items) |item| {
                if (item != .string) return error.InvalidConnectionData;
                try env_list.append(try allocator.dupe(u8, item.string));
            }
            env_vars = try env_list.toOwnedSlice();
        }

        var args: ?[][]const u8 = null;
        if (obj.get("args")) |args_value| {
            if (args_value != .array) return error.InvalidConnectionData;
            var args_list = std.ArrayList([]const u8).init(allocator);
            for (args_value.array.items) |item| {
                if (item != .string) return error.InvalidConnectionData;
                try args_list.append(try allocator.dupe(u8, item.string));
            }
            args = try args_list.toOwnedSlice();
        }

        return MCPConnection{
            .transport = transport,
            .server_name = try allocator.dupe(u8, MCPClient.jsonString(obj.get("server_name") orelse return error.InvalidConnectionData) orelse return error.InvalidConnectionData),
            .url = if (obj.get("url")) |url_value|
                if (url_value == .string) try allocator.dupe(u8, url_value.string) else null
            else
                null,
            .headers = headers,
            .method = if (obj.get("method")) |method_value|
                if (method_value == .string) try allocator.dupe(u8, method_value.string) else try allocator.dupe(u8, "POST")
            else
                try allocator.dupe(u8, "POST"),
            .command = if (obj.get("command")) |command_value|
                if (command_value == .string) try allocator.dupe(u8, command_value.string) else null
            else
                null,
            .env_vars = env_vars,
            .args = args,
            .process = null,
            .initialized = if (obj.get("initialized")) |initialized_value|
                if (initialized_value == .bool) initialized_value.bool else false
            else
                false,
        };
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
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("jsonrpc", .{ .string = self.jsonrpc });
        try obj.put("method", .{ .string = self.method });
        try obj.put("params", self.params);
        try obj.put("id", .{ .integer = @intCast(self.id) });

        const string = try json.stringifyAlloc(allocator, .{ .object = obj }, .{});
        return string;
    }
};

pub const MCPResponse = struct {
    jsonrpc: []const u8,
    result: ?json.Value,
    json_error: ?json.Value, // Renamed from 'error' to avoid keyword conflict
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

// =============================================================================
// OAuth Types and Storage (Phase 7: MCP Authentication)
// =============================================================================

/// OAuth token information
pub const OAuthTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    expires_in: ?u64 = null,
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
    _ = self;
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
    var callback_server = try startCallbackServer(allocator);
    defer callback_server.deinit();

    // Open browser or show URL to user
    std.log.info("Please open this URL in your browser: {s}", .{auth_url});
    std.log.info("Waiting for OAuth callback on port {d}...", .{callback_server.port});

    // Wait for callback
    const callback_result = try waitForCallback(callback_server, state, allocator);
    defer allocator.free(callback_result.code);

    // Exchange authorization code for tokens
    const tokens = try exchangeCodeForTokens(config, callback_result.code, code_verifier, allocator);

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
    const verifier = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(verifier, &random_bytes);

    return verifier;
}

/// Generate PKCE code challenge from verifier
fn generateCodeChallenge(verifier: []const u8, allocator: Allocator) ![]const u8 {
    // SHA256 hash of verifier
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    // Base64 URL-safe encode without padding
    const challenge = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(hash.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(challenge, &hash);

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
        _ = self;
        // No cleanup needed - server is stubbed (OAuth not implemented)
    }
};

/// Start HTTP server for OAuth callback
fn startCallbackServer(allocator: Allocator) !CallbackServer {
    _ = allocator;
    return error.OAuthNotImplemented;
}

/// Wait for OAuth callback - stubbed out
fn waitForCallback(
    callback_server: CallbackServer,
    expected_state: []const u8,
    allocator: Allocator,
) !CallbackResult {
    _ = callback_server;
    _ = expected_state;
    _ = allocator;
    return error.OAuthNotImplemented;
}

/// Callback result from OAuth server
const CallbackResult = struct {
    code: []const u8,
    state: []const u8,
};

/// Exchange authorization code for access token - stubbed out
fn exchangeCodeForTokens(
    config: OAuthServerConfig,
    code: []const u8,
    code_verifier: []const u8,
    allocator: Allocator,
) !OAuthTokens {
    _ = config;
    _ = code;
    _ = code_verifier;
    _ = allocator;
    return error.OAuthNotImplemented;
}

/// Store OAuth tokens for a server
/// Store OAuth tokens for a server
fn storeOAuthTokens(server_name: []const u8, tokens: OAuthTokens, allocator: Allocator) !void {
    _ = allocator;
    // TODO: Implement token storage (file-based or in-memory cache)
    // For now, just log the tokens
    std.log.info("Stored tokens for server '{s}': access_token={s}, expires_in={?d}, refresh_token={?s}", .{
        server_name,
        tokens.access_token,
        tokens.expires_in,
        tokens.refresh_token,
    });
}

/// Refresh expired OAuth tokens - stubbed out
pub fn refreshOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    tokens: OAuthTokens,
    allocator: Allocator,
) !OAuthTokens {
    _ = self;
    _ = server_name;
    _ = config;
    _ = tokens;
    _ = allocator;
    return error.OAuthNotImplemented;
}

/// Get OAuth tokens for a server, refreshing if expired
pub fn getOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    allocator: Allocator,
) !OAuthTokens {
    _ = self;
    _ = server_name;
    _ = config;
    _ = allocator;
    // TODO: Load tokens from storage
    // For now, return error indicating tokens need to be obtained
    return error.TokensNotFound;
}
