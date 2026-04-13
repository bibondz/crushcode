const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const builtin = @import("builtin");
const json = std.json;

const Allocator = std.mem.Allocator;

pub const MCPClient = struct {
    allocator: Allocator,
    servers: std.json.ObjectMap,
    tool_mappings: std.json.ObjectMap,
    connections: std.StringHashMap(MCPConnection), // Direct struct storage — process pointers survive
    next_request_id: std.atomic.Value(u64),
    owned_json_values: array_list_compat.ArrayList(json.Value), // Tracked for bulk cleanup

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
        // Clean up owned JSON response values (cloned from sendStdioRequest)
        for (self.owned_json_values.items) |val| {
            deinitJsonValue(self.allocator, val);
        }
        self.owned_json_values.deinit();

        // Clean up connections — kill processes, free owned memory, free keys
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            var conn = entry.value_ptr;
            conn.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();

        // servers and tool_mappings contain mix of string literals and heap data.
        // ObjectMap.deinit() frees internal storage; any json.Value sub-structures
        // (like config.toJson() objects) are cleaned up by the allocator at program exit.
        // For long-running clients, a more precise tracking approach would be needed.
        self.servers.deinit();
        self.tool_mappings.deinit();
    }

    /// Recursively free a json.Value tree that was created by cloneJsonValue
    fn deinitJsonValue(allocator: Allocator, value: json.Value) void {
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

        // Store connection directly (preserves process pointer)
        const name_owned = try self.allocator.dupe(u8, name);
        try self.connections.put(name_owned, connection);

        // Send MCP initialize handshake for stdio transport
        if (connection.transport == .stdio) {
            self.initializeServer(name) catch |err| {
                std.log.warn("MCP initialize failed for '{s}': {}", .{ name, err });
                // Non-fatal — some servers don't require init
            };
        }

        // Update server info
        if (self.servers.getPtr(name)) |info| {
            if (info.* == .object) {
                try info.*.object.put("connected", .{ .bool = true });
                try info.*.object.put("initialized", .{ .bool = true });
            }
        }

        return connection;
    }

    /// Send MCP initialize handshake (initialize request + initialized notification)
    fn initializeServer(self: *MCPClient, server_name: []const u8) !void {
        // Send initialize request
        var params = json.ObjectMap.init(self.allocator);
        try params.put("protocolVersion", .{ .string = "2024-11-05" });

        var client_info = json.ObjectMap.init(self.allocator);
        try client_info.put("name", .{ .string = "crushcode" });
        try client_info.put("version", .{ .string = "0.1.0" });
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

        // Send initialized notification (notifications have no id field)
        const notif_json = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","method":"notifications/initialized","params":{{}}}}
        , .{});
        defer self.allocator.free(notif_json);

        if (self.connections.getPtr(server_name)) |conn| {
            if (conn.transport == .stdio and conn.process != null) {
                self.sendStdioRaw(conn, notif_json) catch |err| {
                    std.log.warn("Failed to send initialized notification: {}", .{err});
                };
            }
        }
    }

    /// Send raw data over stdio as newline-delimited JSON (no response expected)
    fn sendStdioRaw(self: *MCPClient, connection: *MCPConnection, data: []const u8) !void {
        _ = self;
        const process_ptr = connection.process orelse return error.ProcessNotStarted;
        const child = @as(*std.process.Child, @ptrCast(@alignCast(process_ptr)));
        try child.stdin.?.writeAll(data);
        try child.stdin.?.writeAll("\n");
    }

    // Send JSON-RPC 2.0 request
    pub fn sendRequest(self: *MCPClient, server_name: []const u8, request: MCPRequest) !MCPResponse {
        const connection = self.connections.getPtr(server_name) orelse return error.ServerNotConnected;

        const json_request = try request.toJson(self.allocator);
        defer self.allocator.free(json_request);

        const response_json = switch (connection.transport) {
            .stdio => try self.sendStdioRequest(connection.*, json_request),
            .sse => try self.sendSSERequest(connection.*, json_request),
            .http => try self.sendHTTPRequest(connection.*, json_request),
            .websocket => try self.sendWebSocketRequest(connection.*, json_request),
        };

        return MCPResponse.fromJson(self.allocator, response_json) catch return error.InvalidResponse;
    }

    // Discover tools from server
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
            .result = null,
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
        var env_map = if (env_vars) |ev| try self.prepareEnvironment(ev) else try self.prepareEnvironment(&[_][]const u8{});
        defer env_map.deinit();

        // Start the process
        const spawn_args = args orelse &[_][]const u8{};
        const process = try self.spawnProcess(command, spawn_args, &env_map);

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

    // Send stdio request (newline-delimited JSON)
    fn sendStdioRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        const process_ptr = connection.process orelse return error.ProcessNotStarted;
        const child = @as(*std.process.Child, @ptrCast(@alignCast(process_ptr)));

        // Write request to stdin as newline-delimited JSON
        try child.stdin.?.writeAll(request);
        try child.stdin.?.writeAll("\n");

        // Read response from stdout (newline-delimited JSON)
        var response_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        const reader = file_compat.wrap(child.stdout.?).reader();
        while (true) {
            const byte = reader.readByte() catch break;
            try response_buf.append(byte);
            if (byte == '\n') break;
        }

        // Trim trailing whitespace
        const trimmed = std.mem.trimRight(u8, response_buf.items, "\r\n ");

        // Parse JSON response
        const response_json = json.parseFromSlice(json.Value, self.allocator, trimmed, .{}) catch |err| {
            std.log.err("Failed to parse stdio response: {s}", .{@errorName(err)});
            return json.Value{ .string = try self.allocator.dupe(u8, trimmed) };
        };
        defer response_json.deinit();

        // Clone and track for cleanup
        const cloned = try cloneJsonValue(self.allocator, response_json.value);
        try self.owned_json_values.append(cloned);
        return cloned;
    }

    // Send SSE request
    fn sendSSERequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        const allocator = self.allocator;

        // Parse the JSON-RPC request to get id for error handling
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

        // Build HTTP request
        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var headers_buf = array_list_compat.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });
        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Accept"), .value = try allocator.dupe(u8, "text/event-stream") });

        // Add custom headers from connection
        var header_iter = connection.headers.iterator();
        while (header_iter.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*.string) });
            }
        }

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = request,
            .extra_headers = headers_buf.items,
            .response_writer = &response_writer.writer,
        }) catch |err| {
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

        // Parse SSE response: extract JSON from "data: ..." lines
        // SSE format: "data: {json}\n\n" or "data: {json}\n"
        const response_body = response_writer.written();
        var sse_iter = std.mem.splitSequence(u8, response_body, "data: ");
        while (sse_iter.next()) |data_line| {
            // Trim trailing newlines and whitespace
            const trimmed = std.mem.trim(u8, data_line, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Skip SSE event types (lines like "event: ...")
            if (std.mem.startsWith(u8, trimmed, "event:")) continue;

            // Try to parse as JSON
            if (std.mem.startsWith(u8, trimmed, "{") or std.mem.startsWith(u8, trimmed, "[")) {
                var parsed = json.parseFromSlice(json.Value, allocator, trimmed, .{}) catch {
                    // Not valid JSON, skip this data line
                    continue;
                };
                defer parsed.deinit();

                // Check if this is our response (has matching id or is a valid JSON-RPC response)
                if (parsed.value == .object) {
                    const obj = parsed.value.object;
                    // Accept the first valid JSON-RPC response
                    if (obj.get("jsonrpc") != null) {
                        return try cloneJsonValue(allocator, parsed.value);
                    }
                }
                // Return any valid JSON object as a fallback
                return try cloneJsonValue(allocator, parsed.value);
            }
        }

        // If no SSE data lines found, try parsing the entire body as JSON
        var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch {
            std.log.err("Failed to parse SSE response", .{});
            return json.Value{ .string = try allocator.dupe(u8, response_body) };
        };
        defer response_json.deinit();

        return try cloneJsonValue(allocator, response_json.value);
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

        std.log.info("Sending HTTP {s} request to {s}", .{ method, connection.url.? });

        // Build HTTP request
        const uri = try std.Uri.parse(connection.url.?);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var headers_buf = array_list_compat.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        // Add custom headers from connection
        var header_iter = connection.headers.iterator();
        while (header_iter.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*.string) });
            }
        }

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = request,
            .extra_headers = headers_buf.items,
            .response_writer = &response_writer.writer,
        }) catch |err| {
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

        // Parse response
        const response_body = response_writer.written();
        var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
            std.log.err("Failed to parse response: {s}", .{@errorName(err)});
            return json.Value{ .string = response_body };
        };
        defer response_json.deinit();

        return try cloneJsonValue(allocator, response_json.value);
    }

    // Send WebSocket request
    // Note: Full WebSocket requires framing protocol. For MCP servers,
    // many also accept HTTP POST as a simpler alternative.
    // This implementation sends HTTP POST and parses the JSON response.
    fn sendWebSocketRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        const allocator = self.allocator;

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

        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var headers_buf = array_list_compat.ArrayList(std.http.Header).init(allocator);
        defer headers_buf.deinit();

        try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

        var header_iter = connection.headers.iterator();
        while (header_iter.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try headers_buf.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.*.string) });
            }
        }

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const fetch_result = client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .payload = request,
            .extra_headers = headers_buf.items,
            .response_writer = &response_writer.writer,
        }) catch |err| {
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

        const response_body = response_writer.written();
        var response_json = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch {
            std.log.err("Failed to parse WebSocket-HTTP response", .{});
            return json.Value{ .string = try allocator.dupe(u8, response_body) };
        };
        defer response_json.deinit();

        return try cloneJsonValue(allocator, response_json.value);
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
    fn spawnProcess(self: *MCPClient, command: []const u8, args: []const []const u8, env_map: *std.process.EnvMap) !*std.process.Child {
        const allocator = self.allocator;

        // Build argv array
        var argv = array_list_compat.ArrayList([]const u8).init(allocator);
        defer argv.deinit();

        try argv.append(command);
        for (args) |arg| {
            try argv.append(arg);
        }

        // Spawn process with pipes for stdin/stdout
        var process = std.process.Child.init(argv.items, allocator);
        process.env_map = env_map;
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Close;

        try process.spawn();

        // Allocate memory for the process pointer
        const process_ptr = try allocator.create(std.process.Child);
        process_ptr.* = process;

        return process_ptr;
    }

    // Generate unique request ID
    fn generateRequestId(self: *MCPClient) u64 {
        return self.next_request_id.fetchAdd(1, .monotonic);
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

    /// Clean up connection resources (kill process, free owned strings)
    pub fn deinit(self: *MCPConnection, allocator: Allocator) void {
        // Kill child process if running
        if (self.process) |proc_ptr| {
            const child = @as(*std.process.Child, @ptrCast(@alignCast(proc_ptr)));
            _ = child.kill() catch {};
            allocator.destroy(child);
            self.process = null;
        }
        // Free heap-allocated server_name (always created via allocator.dupe)
        allocator.free(self.server_name);
        self.headers.deinit();
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
        // Build JSON-RPC request string manually to avoid stringifyAlloc
        // comptime resolution issues with anyopaque types in scope
        const params_str: []const u8 = switch (self.params) {
            .null => "null",
            else => try std.fmt.allocPrint(allocator, "{f}", .{json.fmt(self.params, .{})}),
        };

        const result = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"{s}","method":"{s}","params":{s},"id":{d}}}
        , .{ self.jsonrpc, self.method, params_str, self.id });

        // Free intermediate params string if it was allocated
        if (self.params != .null) allocator.free(params_str);

        return result;
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
    const callback_result = try waitForCallback(&callback_server, state, allocator);
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

/// OAuth callback server configuration
const CallbackServer = struct {
    stream: std.net.Server,
    port: u16,
    allocator: Allocator,

    fn deinit(self: *CallbackServer) void {
        self.stream.deinit();
    }
};

/// Start HTTP server for OAuth callback on a random port
fn startCallbackServer(allocator: Allocator) !CallbackServer {
    const address = std.net.Address.parseIp("127.0.0.1", 0) catch return error.OAuthCallbackFailed;
    var server = address.listen(.{ .reuse_address = true }) catch return error.OAuthCallbackFailed;
    const port = server.listen_address.in.getPort();

    return CallbackServer{
        .stream = server,
        .port = port,
        .allocator = allocator,
    };
}

/// Wait for OAuth callback — accepts one connection, extracts code and state
fn waitForCallback(
    callback_server: *CallbackServer,
    expected_state: []const u8,
    allocator: Allocator,
) !CallbackResult {
    var conn = callback_server.stream.accept() catch return error.OAuthCallbackFailed;
    defer conn.stream.close();

    // Read the HTTP request
    var read_buf: [4096]u8 = undefined;
    const bytes_read = conn.stream.read(&read_buf) catch return error.OAuthCallbackFailed;
    const request = read_buf[0..bytes_read];

    // Extract query string from request line: GET /mcp/oauth/callback?code=X&state=Y HTTP/1.1
    const query_start = std.mem.indexOf(u8, request, "?") orelse return error.OAuthCallbackFailed;
    const line_end = std.mem.indexOfScalar(u8, request[query_start..], ' ') orelse return error.OAuthCallbackFailed;
    const query_string = request[query_start .. query_start + line_end];

    // Parse code and state from query string
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

    // Send HTTP response to browser
    const response_html =
        \\HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n
        \\<html><body><h2>Authentication successful!</h2><p>You can close this tab.</p></body></html>
    ;
    _ = conn.stream.write(response_html) catch {};

    const result_code = code orelse return error.OAuthCallbackFailed;
    const result_state = state orelse return error.OAuthCallbackFailed;
    errdefer allocator.free(result_code);
    defer allocator.free(result_state);

    // Verify state matches (CSRF protection)
    if (!std.mem.eql(u8, result_state, expected_state)) {
        allocator.free(result_code);
        return error.OAuthStateMismatch;
    }

    return CallbackResult{
        .code = result_code,
        .state = result_state,
    };
}

/// Callback result from OAuth server
const CallbackResult = struct {
    code: []const u8,
    state: []const u8,
};

/// Exchange authorization code for access token via POST to token endpoint
fn exchangeCodeForTokens(
    config: OAuthServerConfig,
    code: []const u8,
    code_verifier: []const u8,
    allocator: Allocator,
) !OAuthTokens {
    // Build request body: grant_type=authorization_code&code=...&redirect_uri=...&code_verifier=...
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

    // POST to token endpoint
    const uri = std.Uri.parse(config.token_url) catch return error.OAuthTokenExchangeFailed;

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    var headers = array_list_compat.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    try headers.append(.{ .name = "Accept", .value = "application/json" });

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .payload = body_buf.items,
        .extra_headers = headers.items,
        .response_writer = &response_writer.writer,
    }) catch return error.OAuthTokenExchangeFailed;

    if (fetch_result.status != .ok) return error.OAuthTokenExchangeFailed;

    // Parse JSON response: {"access_token":"...","token_type":"Bearer","expires_in":3600,"refresh_token":"..."}
    const response_data = response_writer.written();
    if (response_data.len == 0) return error.OAuthTokenExchangeFailed;

    return parseTokenResponse(response_data, allocator);
}

/// Parse token endpoint JSON response into OAuthTokens
fn parseTokenResponse(data: []const u8, allocator: Allocator) !OAuthTokens {
    var access_token: ?[]const u8 = null;
    var refresh_token: ?[]const u8 = null;
    var token_type: []const u8 = "Bearer";
    var expires_in: ?u64 = null;
    var scope: ?[]const u8 = null;

    // Simple JSON field extraction (avoid full parse for robustness with varied server responses)
    var i: usize = 0;
    // Skip to first {
    while (i < data.len and data[i] != '{') : (i += 1) {}
    if (i >= data.len) return error.OAuthTokenExchangeFailed;
    i += 1; // skip {

    while (i < data.len) {
        // Skip whitespace
        while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
        if (i >= data.len or data[i] == '}') break;
        if (data[i] != '"') break;

        // Parse field name
        i += 1;
        const fname_start = i;
        while (i < data.len and data[i] != '"') : (i += 1) {}
        const fname = data[fname_start..i];
        i += 1;

        // Skip to value
        while (i < data.len and data[i] != ':') : (i += 1) {}
        i += 1;
        while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}

        if (data[i] == '"') {
            // String value
            i += 1;
            const vs = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const val = data[vs..i];
            i += 1;

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
            // Number value
            const ns = i;
            while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
            const num_str = std.mem.trim(u8, data[ns..i], " \t\n\r");

            if (std.mem.eql(u8, fname, "expires_in")) {
                expires_in = std.fmt.parseInt(u64, num_str, 10) catch null;
            }
        }

        // Skip comma
        while (i < data.len and (data[i] == ',' or data[i] == ' ')) : (i += 1) {}
    }

    const at = access_token orelse return error.OAuthTokenExchangeFailed;

    // Calculate expires_at from expires_in
    const expires_at: ?i64 = if (expires_in) |ei|
        std.time.timestamp() + @as(i64, @intCast(ei))
    else
        null;

    return OAuthTokens{
        .access_token = at,
        .refresh_token = refresh_token,
        .token_type = token_type,
        .expires_in = expires_in,
        .expires_at = expires_at,
        .scope = scope,
    };
}

/// Get path to MCP token storage file (~/.crushcode/mcp_tokens.json)
fn getTokenStorePath(allocator: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |userprofile| {
                return std.fmt.allocPrint(allocator, "{s}\\.crushcode\\mcp_tokens.json", .{userprofile});
            } else |_| {
                return error.HomeNotFound;
            }
        }
        return err;
    };
    return std.fmt.allocPrint(allocator, "{s}/.crushcode/mcp_tokens.json", .{home});
}

/// Store OAuth tokens for a server — persists to ~/.crushcode/mcp_tokens.json
fn storeOAuthTokens(server_name: []const u8, tokens: OAuthTokens, allocator: Allocator) !void {
    const token_path = getTokenStorePath(allocator) catch |err| {
        std.log.warn("Cannot resolve token store path: {} — tokens kept in memory only", .{err});
        return;
    };
    defer allocator.free(token_path);

    // Ensure directory exists
    const dir = std.fs.path.dirname(token_path) orelse return error.InvalidPath;
    std.fs.cwd().makePath(dir) catch {};

    // Build JSON: {"server_name":{"access_token":"...","token_type":"...","expires_at":123,...}}
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    // Read existing file to preserve other servers' tokens
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

    // Start building JSON
    try w.writeAll("{");

    // Write existing entries (skip the current server_name to overwrite it)
    var first = true;
    if (existing_data) |data| {
        // Simple parsing: find server entries in the existing JSON
        var i: usize = 0;
        // Skip to first {
        while (i < data.len and data[i] != '{') : (i += 1) {}
        if (i < data.len) i += 1; // skip {

        while (i < data.len) {
            // Skip whitespace
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] == '}') break;
            if (data[i] != '"') break;

            // Parse key (server name)
            i += 1;
            const key_start = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const key_end = i;
            i += 1;

            // Skip to value
            while (i < data.len and data[i] != ':') : (i += 1) {}
            i += 1;
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}

            // Find the matching closing brace for this server's object
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

            // Skip the server we're updating
            if (std.mem.eql(u8, data[key_start..key_end], server_name)) {
                // Skip trailing comma
                while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
                continue;
            }

            // Write this entry: "server_name":{...}
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeByte('"');
            try w.writeAll(data[key_start..key_end]);
            try w.writeAll("\":");
            try w.writeAll(data[obj_start..i]);

            // Skip trailing comma
            while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        }

        defer allocator.free(data);
    }

    // Write the new/updated server entry
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

    // Write to file
    const out_file = std.fs.cwd().createFile(token_path, .{}) catch |err| {
        std.log.warn("Failed to create token store file: {}", .{err});
        return;
    };
    defer out_file.close();
    try out_file.writeAll(buf.items);

    std.log.info("Stored tokens for server '{s}'", .{server_name});
}

/// Refresh expired OAuth tokens using refresh_token grant
pub fn refreshOAuthTokens(
    self: *MCPClient,
    server_name: []const u8,
    config: OAuthServerConfig,
    tokens: OAuthTokens,
    allocator: Allocator,
) !OAuthTokens {
    _ = self;
    _ = server_name;

    const refresh_token = tokens.refresh_token orelse return error.NoRefreshToken;

    // Build request body: grant_type=refresh_token&refresh_token=...
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

    // POST to token endpoint
    const uri = std.Uri.parse(config.token_url) catch return error.OAuthTokenRefreshFailed;

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    var headers = array_list_compat.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    try headers.append(.{ .name = "Accept", .value = "application/json" });

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .payload = body_buf.items,
        .extra_headers = headers.items,
        .response_writer = &response_writer.writer,
    }) catch return error.OAuthTokenRefreshFailed;

    if (fetch_result.status != .ok) return error.OAuthTokenRefreshFailed;

    const response_data = response_writer.written();
    if (response_data.len == 0) return error.OAuthTokenRefreshFailed;

    // Parse new tokens — some providers return a new refresh_token, some don't
    var new_tokens = try parseTokenResponse(response_data, allocator);

    // If server didn't return a new refresh_token, preserve the old one
    if (new_tokens.refresh_token == null) {
        new_tokens.refresh_token = try allocator.dupe(u8, refresh_token);
    }

    return new_tokens;
}

/// Get OAuth tokens for a server, refreshing if expired
pub fn getOAuthTokens(
    self: *MCPClient,
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

    // Simple JSON search: find "server_name":{...}
    // Build the key pattern: "\"server_name\":{"
    var key_buf: [256]u8 = undefined;
    const key_prefix = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{server_name}) catch return error.TokensNotFound;

    const idx = std.mem.indexOf(u8, data, key_prefix) orelse return error.TokensNotFound;
    var i = idx + key_prefix.len;

    // Skip whitespace
    while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return error.TokensNotFound;

    // Extract the object substring
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

    // Parse fields from the object
    var access_token: ?[]const u8 = null;
    var refresh_token: ?[]const u8 = null;
    var token_type: []const u8 = "Bearer";
    var expires_in: ?u64 = null;
    var expires_at: ?i64 = null;
    var scope: ?[]const u8 = null;

    var j: usize = 1; // skip opening {
    while (j < obj_str.len) {
        // Skip whitespace
        while (j < obj_str.len and std.mem.indexOfScalar(u8, " \t\n\r", obj_str[j]) != null) : (j += 1) {}
        if (j >= obj_str.len or obj_str[j] == '}') break;
        if (obj_str[j] != '"') break;

        // Parse field name
        j += 1;
        const fname_start = j;
        while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
        const fname_end = j;
        const fname = obj_str[fname_start..fname_end];
        j += 1;

        // Skip to value
        while (j < obj_str.len and obj_str[j] != ':') : (j += 1) {}
        j += 1;
        while (j < obj_str.len and std.mem.indexOfScalar(u8, " \t\n\r", obj_str[j]) != null) : (j += 1) {}

        if (obj_str[j] == '"') {
            // String value
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
            // Number value
            const ns = j;
            while (j < obj_str.len and obj_str[j] != ',' and obj_str[j] != '}') : (j += 1) {}
            const num_str = std.mem.trim(u8, obj_str[ns..j], " \t\n\r");

            if (std.mem.eql(u8, fname, "expires_at")) {
                expires_at = std.fmt.parseInt(i64, num_str, 10) catch null;
            } else if (std.mem.eql(u8, fname, "expires_in")) {
                expires_in = std.fmt.parseInt(u64, num_str, 10) catch null;
            }
        }

        // Skip comma
        while (j < obj_str.len and (obj_str[j] == ',' or obj_str[j] == ' ')) : (j += 1) {}
    }

    const at = access_token orelse return error.TokensNotFound;

    // Check if expired
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
    // E2E test — requires:
    //   1. RUN_MCP_E2E_TESTS=1 env var
    //   2. mcp-server-filesystem installed and on PATH
    // This test spawns a real MCP server process and exercises:
    //   connect → initialize → discoverTools → executeTool
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

    // Create temp directory
    std.fs.cwd().makePath(tmp_dir) catch {};

    // Connect (spawns process + initialize handshake)
    _ = try client.connectToServer("filesystem", config);

    // Verify connection was stored
    const stored_conn = client.connections.getPtr("filesystem") orelse
        return error.ServerNotConnected;
    try testing.expect(stored_conn.transport == .stdio);
    try testing.expect(stored_conn.process != null);

    // Discover tools
    const tools = try client.discoverTools("filesystem");
    defer testing.allocator.free(tools);

    try testing.expect(tools.len > 0);
    std.debug.print("Discovered {d} tools from MCP filesystem server\n", .{tools.len});
    for (tools[0..@min(3, tools.len)]) |tool| {
        std.debug.print("  - {s}\n", .{tool.name});
    }

    // Verify expected tools exist
    var found_list_directory = false;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, "list_directory")) found_list_directory = true;
    }
    try testing.expect(found_list_directory);

    // Create a test file
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/hello.txt", .{});
        defer f.close();
        try f.writeAll("Hello from Crushcode MCP test!");
    }

    // Execute tool: list_directory
    {
        var list_args = json.ObjectMap.init(testing.allocator);
        defer list_args.deinit();
        try list_args.put("path", .{ .string = tmp_dir });
        const result = try client.executeTool("filesystem", "list_directory", list_args);
        try testing.expect(result.success);
    }

    // Execute tool: read_text_file
    {
        var read_args = json.ObjectMap.init(testing.allocator);
        defer read_args.deinit();
        try read_args.put("path", .{ .string = tmp_dir ++ "/hello.txt" });
        const result = try client.executeTool("filesystem", "read_text_file", read_args);
        try testing.expect(result.success);
    }

    // Clean up
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

    // Verify it contains expected fields
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
