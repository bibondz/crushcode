const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const HybridBridge = struct {
    allocator: Allocator,
    plugin_manager: PluginManager,
    mcp_client: MCPClient,
    tool_registry: std.json.ObjectMap, // Maps Crushcode tool names to MCP tools

    pub fn init(allocator: Allocator, plugin_manager: PluginManager, mcp_client: MCPClient) HybridBridge {
        return HybridBridge{
            .allocator = allocator,
            .plugin_manager = plugin_manager,
            .mcp_client = mcp_client,
            .tool_registry = std.json.ObjectMap.init(allocator),
        };
    }

    pub fn deinit(self: *HybridBridge) void {
        self.tool_registry.deinit();
    }

    // Initialize built-in plugins
    pub fn initializeBuiltIns(self: *HybridBridge) !void {
        // Initialize built-in plugins first
        try self.plugin_manager.initializeBuiltIns();
        
        // Initialize MCP client
        self.mcp_client.init();
        
        // Create default MCP tool mappings
        try self.createDefaultMappings();
        
        std.log.info("Hybrid bridge initialized with built-in plugins and MCP support");
    }

    // Load MCP servers and create tool mappings
    pub fn loadMCPServers(self: *HybridBridge) !void {
        // Get list of default MCP servers
        const server_names = try self.mcp_client.listServers();
        
        for (server_names) |server_name| {
            // Load MCP server configuration
            const config = MCPServerConfig{
                .name = server_name,
                .type = .stdio, // Default to stdio for built-in servers
                .command = try std.fmt.allocPrint(self.allocator, "npx -y @modelcontextprotocol/{s}", .{server_name}),
                .env_vars = std.json.ObjectMap.init(self.allocator),
                .enabled = true,
                .priority = 50,
            };

            // Environment variables for GitHub
            if (std.mem.eql(u8, server_name, "github")) {
                try config.env_vars.put("GITHUB_TOKEN", .{ .string = "${GITHUB_TOKEN}" });
            }

            // Connect to MCP server and discover tools
            const connection = try self.mcp_client.connectToServer(server_name, config);
            
            // Discover tools from the server
            const tools = try self.mcp_client.discoverTools(server_name);
            
            // Map MCP tools to Crushcode tool names
            for (tools) |tool| {
                const crushcode_tool = self.mapToCrushcodeTool(server_name, tool.name);
                if (crushcode_tool) |cc_tool| {
                    const mapping = MCPToolMapping{
                        .mcp_server = try self.allocator.dupe(u8, server_name),
                        .mcp_tool_name = try self.allocator.dupe(u8, tool.name),
                        .crushcode_tool_name = try self.allocator.dupe(u8, cc_tool),
                        .description = try self.allocator.dupe(u8, tool.description orelse ""),
                        .parameters = tool.input_schema,
                    };
                    
                    const mapping_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ server_name, tool.name });
                    try self.tool_registry.put(mapping_key, .{ .object = mapping.toJson(self.allocator) });
                }
            }
        }
    }

    // Route request to appropriate handler (built-in or MCP)
    pub fn routeRequest(self: *HybridBridge, request_type: []const u8, method: []const u8, args: anytype) !anytype {
        // First check if built-in plugin can handle this
        if (self.plugin_manager.registry.findPluginForRequest(request_type)) |plugin| {
            switch (plugin.built_in) {
                .pty => {
                    if (self.plugin_manager.pty_plugin) |pty| {
                        const pty_request = PTYRequest{
                            .method = @enumFromString(PTYMethod, method) orelse PTYMethod.spawn,
                            .args = args,
                        };
                        return pty.handleRequest(pty_request);
                    }
                },
                .table_formatter => {
                    if (self.plugin_manager.table_formatter) |formatter| {
                        if (std.mem.eql(u8, method, "format_tables")) {
                            return formatter.formatMarkdownTables(args.text);
                        }
                    }
                },
                .notifier => {
                    if (self.plugin_manager.notifier) |notifier| {
                        const event_type = @enumFromString(EventType, method) orelse EventType.session_started;
                        const event = NotifierEvent{
                            .type = event_type,
                            .session_id = args.session_id,
                            .task_name = args.task_name,
                            .permission = args.permission,
                            .permission_granted = args.permission_granted,
                            .error_message = args.error_message,
                            .timestamp = std.time.timestamp(),
                        };
                        return notifier.handleEvent(event);
                    }
                },
                .shell_strategy => {
                    if (self.plugin_manager.shell_strategy) |shell| {
                        const command = args.command;
                        const cmd_args = args.args;
                        return shell.processCommand(command, cmd_args);
                    }
                },
                else => {}, // Handle other built-in plugins
            }
        }
        
        // If no built-in plugin can handle it, try MCP
        if (self.isMCPRequest(request_type)) {
            return try self.handleMCPRequest(request_type, method, args);
        }
        
        return error.UnsupportedRequestType;
    }

    // Handle MCP-specific requests
    fn handleMCPRequest(self: *HybridBridge, request_type: []const u8, method: []const u8, args: anytype) !anytype {
        // Parse request_type to extract server and tool
        var parts = std.mem.split(u8, request_type, ':');
        const server_name = parts.next().?;
        const tool_name = parts.next().?;
        
        const mapping_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ server_name, tool_name });
        
        if (self.tool_registry.get(mapping_key)) |mapping| {
            const mcp_tool = MCPTool{
                .name = mapping.mcp_tool_name,
                .arguments = args,
            };
            
            // Execute tool via MCP
            const result = try self.mcp_client.executeTool(server_name, mapping.mcp_tool_name, args);
            
            return result;
        }
        
        return error.ToolMappingNotFound;
    }

    // Create default tool mappings for common tools
    fn createDefaultMappings(self: *HybridBridge) !void {
        // GitHub mappings
        try self.createToolMapping(
            "github",
            "create_issue",
            "github_create_issue",
            "Create GitHub issue with title and body"
        );
        
        try self.createToolMapping(
            "github",
            "search_repositories",
            "github_search",
            "Search GitHub repositories"
        );
        
        try self.createToolMapping(
            "github",
            "get_file",
            "github_get_file",
            "Get file content from GitHub repository"
        );
        
        // Filesystem mappings
        try self.createToolMapping(
            "filesystem",
            "read_file",
            "filesystem_read_file",
            "Read file from local filesystem"
        );
        
        try self.createToolMapping(
            "filesystem",
            "write_file", 
            "filesystem_write_file",
            "Write file to local filesystem"
        );
        
        try self.createToolMapping(
            "filesystem",
            "list_directory",
            "filesystem_list_directory",
            "List directory contents"
        );
    }

    // Create individual tool mapping
    fn createToolMapping(self: *HybridBridge, server: []const u8, tool: []const u8, crushcode_tool: []const u8, description: []const u8) !void {
        const mapping_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ server, tool });
        
        var parameters = std.json.ObjectMap.init(self.allocator);
        defer parameters.deinit();
        
        // Add example parameters for documentation
        if (std.mem.eql(u8, server, "github")) {
            if (std.mem.eql(u8, tool, "create_issue")) {
                try parameters.put("title", .{ .string = "Issue title" });
                try parameters.put("body", .{ .string = "Issue description" });
                try parameters.put("repo", .{ .string = "repository name" });
            }
        }
        
        const mapping = MCPToolMapping{
            .mcp_server = try self.allocator.dupe(u8, server),
            .mcp_tool_name = try self.allocator.dupe(u8, tool),
            .crushcode_tool_name = try self.allocator.dupe(u8, crushcode_tool),
            .description = try self.allocator.dupe(u8, description),
            .parameters = parameters,
        };
        
        try self.tool_registry.put(mapping_key, .{ .object = mapping.toJson(self.allocator) });
    }

    // Map MCP tool names to Crushcode tool names
    fn mapToCrushcodeTool(self: *HybridBridge, server: []const u8, mcp_tool: []const u8) ?[]const u8 {
        // Common mappings for GitHub
        if (std.mem.eql(u8, server, "github")) {
            if (std.mem.startsWith(u8, mcp_tool, "create")) {
                return "github_create_issue";
            }
            if (std.mem.startsWith(u8, mcp_tool, "search")) {
                return "github_search";
            }
            if (std.mem.startsWith(u8, mcp_tool, "get")) {
                return "github_get_file";
            }
        }
        
        // Common mappings for Filesystem
        if (std.mem.eql(u8, server, "filesystem")) {
            if (std.mem.startsWith(u8, mcp_tool, "read")) {
                return "filesystem_read_file";
            }
            if (std.mem.startsWith(u8, mcp_tool, "write")) {
                return "filesystem_write_file";
            }
            if (std.mem.startsWith(u8, mcp_tool, "list")) {
                return "filesystem_list_directory";
            }
        }
        
        // Fallback to mcp:server:tool format
        const fallback = try std.fmt.allocPrint(self.allocator, "mcp:{s}:{s}", .{ server, mcp_tool });
        return fallback;
    }

    // Check if request is MCP-specific
    fn isMCPRequest(self: *HybridBridge, request_type: []const u8) bool {
        return std.mem.startsWith(u8, request_type, "mcp:");
    }

    // Get available tools (built-in + MCP)
    pub fn listAvailableTools(self: *HybridBridge) ![]ToolInfo {
        var tools = std.ArrayList(ToolInfo).init(self.allocator);
        defer tools.deinit();
        
        // Add built-in tools
        const built_in_plugins = try self.plugin_manager.getPluginsByType(.built_in);
        for (built_in_plugins) |plugin| {
            const tool_info = ToolInfo{
                .name = plugin.name,
                .source = "built-in",
                .description = plugin.description,
                .category = self.getPluginCategory(plugin.name),
            };
            try tools.append(tool_info);
        }
        
        // Add MCP tools
        var iter = self.tool_registry.iterator();
        while (iter.next()) |entry| {
            const mapping = entry.value_ptr.object;
            const tool_info = ToolInfo{
                .name = mapping.get("crushcode_tool_name").?.string orelse "",
                .source = mapping.get("mcp_server").?.string orelse "",
                .description = mapping.get("description").?.string orelse "",
                .category = self.getPluginCategory(mapping.get("crushcode_tool_name").?.string orelse ""),
            };
            try tools.append(tool_info);
        }
        
        return tools.toOwnedSlice();
    }

    // Get plugin category
    fn getPluginCategory(self: *HybridBridge, tool_name: []const u8) []const u8 {
        if (std.mem.startsWith(u8, tool_name, "github")) return "version_control";
        if (std.mem.startsWith(u8, tool_name, "filesystem")) return "file_operations";
        if (std.mem.startsWith(u8, tool_name, "pty")) return "terminal";
        if (std.mem.startsWith(u8, tool_name, "table")) return "text_processing";
        if (std.mem.startsWith(u8, tool_name, "notifier")) return "notifications";
        if (std.mem.startsWith(u8, tool_name, "shell")) return "development";
        return "general";
    }
};

// Import existing types
const PluginManager = @import("plugin_manager.zig").PluginManager;
const MCPClient = @import("mcp/client.zig").MCPClient;
const MCPServerConfig = @import("mcp/client.zig").MCPServerConfig;
const MCPToolMapping = @import("mcp/client.zig").MCPToolMapping;
const PTYPlugin = @import("pty.zig").PTYPlugin;
const PTYRequest = @import("pty.zig").PTYRequest;
const PTYMethod = @import("pty.zig").PTYMethod;
const TableFormatterPlugin = @import("table_formatter.zig").TableFormatterPlugin;
const NotifierPlugin = @import("notifier.zig").NotifierPlugin;
const NotifierEvent = @import("notifier.zig").NotifierEvent;
const EventType = @import("notifier.zig").EventType;
const ShellStrategyPlugin = @import("shell_strategy.zig").ShellStrategyPlugin;
const Plugin = @import("registry.zig").Plugin;
const MCPTool = @import("mcp/client.zig").MCPTool;

pub const ToolInfo = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
    category: []const u8,
};