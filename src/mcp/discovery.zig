const std = @import("std");
const array_list_compat = @import("array_list_compat");
const builtin = @import("builtin");
const MCPClient = @import("mcp_client").MCPClient;
const MCPServerConfig = @import("mcp_client").MCPServerConfig;

const Allocator = std.mem.Allocator;

pub const MCPDiscovery = struct {
    allocator: Allocator,
    client: *MCPClient,

    pub fn init(allocator: Allocator, client: *MCPClient) MCPDiscovery {
        return MCPDiscovery{
            .allocator = allocator,
            .client = client,
        };
    }

    pub fn discoverServers(self: *MCPDiscovery, search_term: ?[]const u8) ![]MCPDiscoveryResult {
        var results = array_list_compat.ArrayList(MCPDiscoveryResult).init(self.allocator);
        defer results.deinit();

        // Add default servers
        try self.addDefaultServers(&results);

        // Search for additional servers in common locations
        if (search_term) |term| {
            try self.searchFilesystem(&results, term);
            try self.searchRegistry(&results, term);
            try self.searchConfig(&results, term);
        }

        return results.toOwnedSlice();
    }

    pub fn addDefaultServers(_: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult)) !void {
        // GitHub MCP server
        try results.append(MCPDiscoveryResult{
            .name = "GitHub",
            .description = "GitHub repository search and issue management",
            .url = "https://github.com/modelcontextprotocol/github",
            .install_command = "npm install -g @modelcontextprotocol/github",
            .type = .npm,
            .capabilities = "search_repositories, create_issue, get_file, list_issues, get_repository",
        });

        // Filesystem MCP server
        try results.append(MCPDiscoveryResult{
            .name = "Filesystem",
            .description = "Local filesystem operations across projects",
            .url = "https://github.com/modelcontextprotocol/filesystem",
            .install_command = "npm install -g @modelcontextprotocol/filesystem",
            .type = .npm,
            .capabilities = "read_file, write_file, list_directory, create_directory, delete_file, move_file, copy_file",
        });

        // Context7 MCP server
        try results.append(MCPDiscoveryResult{
            .name = "Context7",
            .description = "Library documentation search and retrieval",
            .url = "https://github.com/modelcontextprotocol/context7",
            .install_command = "npm install -g @modelcontextprotocol/context7",
            .type = .npm,
            .capabilities = "search_libraries, get_library_documentation, search_functions",
        });

        // Exa Search Engine MCP server
        try results.append(MCPDiscoveryResult{
            .name = "Exa Search",
            .description = "Web search engine integration",
            .url = "https://github.com/modelcontextprotocol/exa",
            .install_command = "npm install -g @modelcontextprotocol/exa",
            .type = .npm,
            .capabilities = "web_search, search_images, search_news",
        });
    }

    pub fn searchFilesystem(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        if (builtin.target.os.tag == .windows) {
            try self.searchWindows(results, term);
        } else {
            try self.searchUnix(results, term);
        }
    }

    fn searchWindows(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        _ = self;
        _ = results;
        _ = term;

        // Search Windows Registry for MCP servers
        std.log.info("Searching Windows registry for MCP servers");
        // TODO: Implement Windows registry search
    }

    fn searchUnix(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Search common installation directories
        const search_paths = [_][]const u8{
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/local/share/mcp-servers",
            std.fmt.allocPrint(self.allocator, "{s}/.local/share/npx", .{std.process.getEnvVar("HOME") orelse "/home"}),
            std.fmt.allocPrint(self.allocator, "{s}/.npm-global/bin", .{std.process.getEnvVar("HOME") orelse "/home/user"}),
        };

        for (search_paths) |search_path| {
            if (self.searchDirectory(results, search_path, term)) {
                return; // Found what we're looking for
            }
        }

        // Search package managers
        try self.searchPackageManagers(results, term);
    }

    fn searchDirectory(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), dir: []const u8, term: []const u8) !bool {
        var dir_iter = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open directory {s}: {}", .{ dir, err });
            return false;
        };
        defer dir_iter.close();

        while (dir_iter.next() catch null) |entry| {
            const filename = entry.name;
            if (self.isMCPServer(filename, term)) {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, filename });
                defer self.allocator.free(full_path);

                const description = try self.getServerDescription(full_path);

                try results.append(MCPDiscoveryResult{
                    .name = std.mem.slice(full_path, std.mem.lastIndexOf(u8, full_path, '/') + 1),
                    .description = description,
                    .url = try std.fmt.allocPrint(self.allocator, "file://{s}", .{full_path}),
                    .type = .local,
                    .install_command = null,
                    .capabilities = try self.detectServerCapabilities(full_path),
                });
            }
        }

        return false;
    }

    fn isMCPServer(_: *MCPDiscovery, filename: []const u8, term: []const u8) bool {
        _ = term;

        const lower_filename = std.ascii.lowerString(filename);

        // Check if filename contains common MCP server keywords
        const mcp_keywords = [_][]const u8{ "mcp", "server", "context", "model", "protocol", "gateway" };

        for (mcp_keywords) |keyword| {
            if (std.mem.indexOf(u8, lower_filename, keyword) != null) {
                return true;
            }
        }

        return false;
    }

    fn getServerDescription(self: *MCPDiscovery, path: []const u8) ![]const u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            return try self.allocator.dupe(u8, "Failed to read file");
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator);
        defer self.allocator.free(content);

        // Extract description from file content
        var desc_start: ?usize = null;
        var desc_end: ?usize = null;

        var i: usize = 0;
        while (i < content.len) {
            if (content.len > i + 20) {
                if (content[i] == '#' and content[i + 1] == '!') {
                    desc_start = i + 2;
                }
            }

            if (content[i] == '\n' and desc_start != null) {
                desc_end = i;
                break;
            }
            i += 1;
        }

        if (desc_start) |start| {
            if (desc_end) |end| {
                const description = content[start..end];
                return try self.allocator.dupe(u8, std.mem.trim(u8, description, " \t\r\n"));
            }
        }

        return try self.allocator.dupe(u8, "MCP server");
    }

    fn detectServerCapabilities(self: *MCPDiscovery, path: []const u8) ![]const u8 {
        // For local servers, assume basic capabilities
        var capabilities = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer capabilities.deinit();

        try capabilities.append("tools/list");
        try capabilities.append("tools/call");

        // Check file extension for specific capabilities
        if (std.mem.endsWith(u8, path, ".py")) {
            try capabilities.append("read_file");
            try capabilities.append("write_file");
        }
        if (std.mem.endsWith(u8, path, ".js")) {
            try capabilities.append("read_file");
            try capabilities.append("write_file");
        }

        return capabilities.toOwnedSlice();
    }

    fn searchPackageManagers(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Search npm global packages for MCP servers
        const npm_path = try std.fmt.allocPrint(self.allocator, "{s}/.npm-global/bin", .{std.process.getEnvVar("HOME") orelse "/home/user"});
        if (self.searchDirectory(results, npm_path, term)) {
            return;
        }
    }

    fn searchRegistry(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        _ = self;
        _ = results;
        _ = term;

        // TODO: Search npm registry for MCP servers
        std.log.info("Searching npm registry for MCP servers");
    }

    fn searchConfig(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        _ = self;
        _ = results;
        _ = term;

        // TODO: Read user configuration for MCP servers
        std.log.info("Searching user configuration for MCP servers");
    }

    pub fn validateServer(self: *MCPDiscovery, config: MCPServerConfig) !bool {
        _ = self;

        // Basic validation
        if (config.name.len == 0) {
            return false;
        }

        // Validate transport type
        const valid_transports = [_]MCPServerType{ .stdio, .sse, .http, .websocket };
        var transport_valid = false;
        for (valid_transports) |valid| {
            if (config.transport == valid) {
                transport_valid = true;
            }
        }

        if (!transport_valid) {
            return false;
        }

        // Validate command for stdio
        if (config.transport == .stdio and config.command == null) {
            return false;
        }

        // Validate URL for HTTP/SSE/WebSocket
        if (config.transport == .http or config.transport == .sse or config.transport == .websocket) {
            if (config.url == null) {
                return false;
            }
        }

        return true;
    }
};

pub const MCPDiscoveryResult = struct {
    name: []const u8,
    description: []const u8,
    url: ?[]const u8,
    type: MCPServerType,
    install_command: ?[]const u8,
    capabilities: []const u8,
};

pub const MCPServerType = enum {
    npm,
    local,
    stdio,
    sse,
    http,
    websocket,
};
