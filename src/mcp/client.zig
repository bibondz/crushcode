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
