const std = @import("std");
const json = std.json;
const mcp_client = @import("mcp_client");
const mcp_discovery = @import("discovery");
const client = @import("client");

const Allocator = std.mem.Allocator;

// Re-export types needed by consumers
pub const MCPClient = mcp_client.MCPClient;
pub const MCPTool = mcp_client.MCPTool;
pub const MCPToolResult = mcp_client.MCPToolResult;
pub const TransportType = mcp_client.TransportType;
pub const MCPServerConfig = mcp_client.MCPServerConfig;

/// MCP bridge errors
pub const BridgeError = error{
    ServerNotFound,
    NotConnected,
    ConnectionFailed,
    ToolNotFound,
    ExecutionFailed,
    JsonRpcError,
    ConfigMissing,
};

/// MCP server info
pub const MCPServer = struct {
    name: []const u8,
    connected: bool,
    tools: []mcp_client.MCPTool,
};

/// MCP bridge between Crushcode and external MCP servers
pub const Bridge = struct {
    allocator: Allocator,
    servers: std.ArrayList(MCPServer),
    stdio_processes: std.StringArrayHashMap(*std.process.Child),
    http_servers: std.StringArrayHashMap(*anyopaque),
    tool_index: std.StringArrayHashMap(usize),
    client: *mcp_client.MCPClient,

    pub fn init(allocator: Allocator, mcp_client_ptr: *mcp_client.MCPClient) !Bridge {
        return Bridge{
            .allocator = allocator,
            .servers = std.ArrayList(MCPServer).init(allocator),
            .stdio_processes = std.StringArrayHashMap(*std.process.Child).init(allocator),
            .http_servers = std.StringArrayHashMap(*anyopaque).init(allocator),
            .tool_index = std.StringArrayHashMap(usize).init(allocator),
            .client = mcp_client_ptr,
        };
    }

    pub fn deinit(self: *Bridge) void {
        var proc_iter = self.stdio_processes.iterator();
        while (proc_iter.next()) |entry| {
            _ = entry.value_ptr.*.kill() catch {};
        }
        self.stdio_processes.deinit();
        self.http_servers.deinit();
        for (self.servers.items) |*server| {
            self.allocator.free(server.tools);
        }
        self.servers.deinit();
        self.tool_index.deinit();
    }

    pub fn addServer(self: *Bridge, config: mcp_client.MCPServerConfig) !void {
        const name = try self.allocator.dupe(u8, config.command orelse config.url orelse "unknown");
        errdefer self.allocator.free(name);
        try self.servers.append(.{ .name = name, .connected = false, .tools = &.{} });
    }

    pub fn connectServer(self: *Bridge, name: []const u8, config: mcp_client.MCPServerConfig) BridgeError!void {
        for (self.servers.items, 0..) |server, idx| {
            if (std.mem.eql(u8, server.name, name)) {
                _ = self.client.connectToServer(name, config) catch |err| {
                    std.log.warn("Failed to connect to MCP server '{s}': {}", .{ name, err });
                    return BridgeError.ConnectionFailed;
                };
                self.servers.items[idx].connected = true;
                return;
            }
        }
        return BridgeError.ServerNotFound;
    }

    pub fn connectAll(self: *Bridge, configs: []const mcp_client.MCPServerConfig) void {
        for (self.servers.items) |*server| {
            self.connectServer(server.name, mcp_client.MCPServerConfig{ .transport = .stdio }) catch |err| {
                std.log.warn("Failed to connect to MCP server '{s}': {}", .{ server.name, err });
            };
        }
        _ = configs;
    }

    pub fn executeTool(self: *Bridge, full_name: []const u8, arguments: []const u8) BridgeError![]const u8 {
        _ = arguments;
        const server_idx = self.tool_index.get(full_name) orelse return BridgeError.ToolNotFound;
        if (server_idx >= self.servers.items.len) return BridgeError.ServerNotFound;

        const server = &self.servers.items[server_idx];
        if (!server.connected) return BridgeError.NotConnected;

        const tool_name = if (std.mem.indexOf(u8, full_name, "_")) |pos| full_name[pos + 1 ..] else full_name;
        _ = for (server.tools) |t| {
            if (std.mem.eql(u8, t.name, tool_name)) break t;
        } else return BridgeError.ToolNotFound;

        var tool_arguments = json.ObjectMap.init(self.allocator);
        defer tool_arguments.deinit();

        const result = self.client.executeTool(server.name, tool_name, tool_arguments) catch |err| {
            std.log.err("Tool execution failed: {}", .{err});
            return BridgeError.ExecutionFailed;
        };

        if (!result.success) {
            return BridgeError.JsonRpcError;
        }

        if (result.result) |value| {
            return json.stringifyAlloc(self.allocator, value, .{}) catch {
                return BridgeError.ExecutionFailed;
            };
        }

        return "";
    }

    pub fn getToolSchemas(self: *Bridge, allocator: Allocator) (std.mem.Allocator.Error || std.fmt.AllocPrintError)![]const client.ToolSchema {
        var schemas = std.ArrayList(client.ToolSchema).init(allocator);
        _ = schemas.ensureTotalCapacity(16) catch unreachable;

        for (self.servers.items, 0..) |server, server_idx| {
            if (!server.connected) continue;
            for (server.tools) |tool| {
                const full_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ server.name, tool.name });
                errdefer allocator.free(full_name);
                const wrapped = try std.fmt.allocPrint(allocator, "{{\"type\":\"object\",\"properties\":{{\"input\":{{\"type\":\"string\",\"description\":\"Arguments for {s} as JSON\"}}}},\"required\":[\"input\"]}}", .{tool.name});
                defer allocator.free(wrapped);

                try schemas.append(.{
                    .name = try allocator.dupe(u8, full_name),
                    .description = try std.fmt.allocPrint(allocator, "[MCP:{s}] {s}", .{ server.name, tool.description }),
                    .parameters = try allocator.dupe(u8, wrapped),
                });
                try self.tool_index.put(full_name, server_idx);
            }
        }
        return schemas.toOwnedSlice();
    }

    pub const Stats = struct { servers: usize, tools: usize };

    pub fn getStats(self: *Bridge) Stats {
        var tool_count: usize = 0;
        for (self.servers.items) |server| {
            if (server.connected) tool_count += server.tools.len;
        }
        return .{ .servers = self.servers.items.len, .tools = tool_count };
    }
};
