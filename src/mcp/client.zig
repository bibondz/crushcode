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
        
        if (response.error) |err| {
            std.log.err("Failed to discover tools: {s}", .{err.message.?});
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
        const request = MCPRequest{
            .jsonrpc = "2.0",
            .method = "tools/call",
            .params = json.Value{
                .object = blk: {
                    try params.put("name", .{ .string = tool_name });
                    try params.put("arguments", .{ .object = arguments });
                },
            },
            .id = self.generateRequestId(),
        };

        const response = try self.sendRequest(server_name, request);
        
        if (response.error) |err| {
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
        _ = self;
        _ = name;

        return MCPConnection{
            .transport = .stdio,
            .server_name = try self.allocator.dupe(u8, name),
            .command = config.command orelse return error.StdioCommandRequired,
            .env_vars = config.env_vars orelse &[_][]const u8{},
            .args = config.args orelse &[_][]const u8{},
            .process = null,
            .initialized = false,
        };
    }

    // Create SSE connection
    fn createSSEConnection(self: *MCPClient, name: []const u8, config: MCPServerConfig) !MCPConnection {
        _ = self;
        _ = name;
        _ = config;
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
        _ = self;
        _ = name;
        _ = config;
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
        _ = self;
        _ = name;
        _ = config;
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
        _ = self;
        _ = connection;
        _ = request;
        
        // For stdio, write to stdin and read from stdout
        std.log.info("Sending stdio request: {s}", .{request});
        return json.Value{ .string = "stdio request not implemented" };
    }

    // Send SSE request
    fn sendSSERequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        _ = self;
        _ = connection;
        _ = request;
        
        // For SSE, send HTTP request and parse response
        std.log.info("Sending SSE request to {s}: {s}", .{ connection.url, request });
        return json.Value{ .string = "sse request not implemented" };
    }

    // Send HTTP request
    fn sendHTTPRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        _ = self;
        _ = connection;
        _ = request;
        
        // For HTTP, send request and parse response
        std.log.info("Sending HTTP request to {s}: {s}", .{ connection.url, request });
        return json.Value{ .string = "http request not implemented" };
    }

    // Send WebSocket request
    fn sendWebSocketRequest(self: *MCPClient, connection: MCPConnection, request: []const u8) !json.Value {
        _ = self;
        _ = connection;
        _ = request;
        
        // For WebSocket, send message over WebSocket
        std.log.info("Sending WebSocket request to {s}: {s}", .{ connection.url, request });
        return json.Value{ .string = "websocket request not implemented" };
    }

    // Generate unique request ID
    fn generateRequestId(self: *MCPClient) u64 {
        _ = self;
        return @intCast(u64, std.time.timestamp() * 1000);
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
};

pub const MCPRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: json.Value,
    id: u64,
};

pub const MCPResponse = struct {
    jsonrpc: []const u8,
    result: ?json.Value,
    error: ?json.Value,
    id: u64,
};

pub const MCPTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.Value,
    output_schema: ?json.Value,
    
    pub fn fromJson(allocator: Allocator, value: json.Value) !MCPTool {
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

// Helper functions for JSON serialization
pub const MCPServerConfig = struct {
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

pub const MCPConnection = struct {
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

pub const MCPRequest = struct {
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