const std = @import("std");
const array_list_compat = @import("array_list_compat");
const builtin = @import("builtin");
const env = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");
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
        // Search common Windows locations for MCP servers
        const search_paths = [_][]const u8{
            "\\Program Files\\crushcode\\mcp-servers",
            "\\Program Files (x86)\\crushcode\\mcp-servers",
        };

        // Search LOCALAPPDATA-based paths
        if (std.process.getEnvVarOwned(self.allocator, "LOCALAPPDATA")) |local_appdata| {
            defer self.allocator.free(local_appdata);
            const npx_path = std.fmt.allocPrint(self.allocator, "{s}\\npm-cache\\_npx", .{local_appdata}) catch return;
            defer self.allocator.free(npx_path);
            _ = self.searchDirectory(results, npx_path, term) catch false;

            const crushcode_path = std.fmt.allocPrint(self.allocator, "{s}\\crushcode\\mcp-servers", .{local_appdata}) catch return;
            defer self.allocator.free(crushcode_path);
            _ = self.searchDirectory(results, crushcode_path, term) catch false;
        } else |_| {}

        // Search USERPROFILE-based paths
        if (std.process.getEnvVarOwned(self.allocator, "USERPROFILE")) |home| {
            defer self.allocator.free(home);
            const appdata_npm = std.fmt.allocPrint(self.allocator, "{s}\\AppData\\Roaming\\npm", .{home}) catch return;
            defer self.allocator.free(appdata_npm);
            _ = self.searchDirectory(results, appdata_npm, term) catch false;
        } else |_| {}

        // Search system paths
        if (std.process.getEnvVarOwned(self.allocator, "SYSTEMDRIVE")) |drive| {
            defer self.allocator.free(drive);
            for (search_paths) |suffix| {
                const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ drive, suffix }) catch continue;
                defer self.allocator.free(full_path);
                _ = self.searchDirectory(results, full_path, term) catch continue;
            }
        } else |_| {}

        std.log.info("Searched Windows paths for MCP servers", .{});
    }

    fn searchUnix(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Search common installation directories
        const search_paths = [_][]const u8{
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/local/share/mcp-servers",
        };

        // Also search HOME-based paths
        if (env.getHomeDir(self.allocator)) |home| {
            defer self.allocator.free(home);
            const npx_path = std.fmt.allocPrint(self.allocator, "{s}/.local/share/npx", .{home}) catch return;
            defer self.allocator.free(npx_path);
            if (self.searchDirectory(results, npx_path, term) catch false) return;

            const npm_path = std.fmt.allocPrint(self.allocator, "{s}/.npm-global/bin", .{home}) catch return;
            defer self.allocator.free(npm_path);
            if (self.searchDirectory(results, npm_path, term) catch false) return;
        } else |_| {}

        for (search_paths) |search_path| {
            if (self.searchDirectory(results, search_path, term) catch false) {
                return; // Found what we're looking for
            }
        }

        // Search package managers
        try self.searchPackageManagers(results, term);
    }

    fn searchDirectory(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), dir: []const u8, term: []const u8) !bool {
        var opened_dir = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open directory {s}: {}", .{ dir, err });
            return false;
        };
        defer opened_dir.close();

        var dir_iter = opened_dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            const filename = entry.name;
            if (self.isMCPServer(filename, term)) {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, filename });
                defer self.allocator.free(full_path);

                const description = try self.getServerDescription(full_path);

                try results.append(MCPDiscoveryResult{
                    .name = full_path[(std.mem.lastIndexOfScalar(u8, full_path, '/') orelse 0) + 1 ..],
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

    fn isMCPServer(self: *MCPDiscovery, filename: []const u8, term: []const u8) bool {
        _ = term;

        // Allocate a lowercase copy of the filename for case-insensitive matching
        const lower_filename = self.allocator.alloc(u8, filename.len) catch return false;
        defer self.allocator.free(lower_filename);
        _ = std.ascii.lowerString(lower_filename, filename);

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

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
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
        var caps = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer caps.deinit();

        try caps.append("tools/list");
        try caps.append("tools/call");

        // Check file extension for specific capabilities
        if (std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".js")) {
            try caps.append("read_file");
            try caps.append("write_file");
        }

        // Join capabilities into a comma-separated string
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (caps.items, 0..) |cap, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice(cap);
        }
        return buf.toOwnedSlice();
    }

    fn searchPackageManagers(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Search npm global packages for MCP servers
        if (env.getHomeDir(self.allocator)) |home| {
            defer self.allocator.free(home);
            const npm_path = std.fmt.allocPrint(self.allocator, "{s}/.npm-global/bin", .{home}) catch return;
            defer self.allocator.free(npm_path);
            if (self.searchDirectory(results, npm_path, term) catch false) {
                return;
            }
        } else |_| {}
    }

    fn searchRegistry(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Search npm registry for MCP servers matching the search term
        // Uses the npm search API: https://registry.npmjs.org/-/v1/search?text=mcp+<term>
        const search_url = std.fmt.allocPrint(self.allocator, "https://registry.npmjs.org/-/v1/search?text=mcp+{s}&size=5", .{term}) catch {
            std.log.warn("Failed to build npm search URL", .{});
            return;
        };
        defer self.allocator.free(search_url);

        const req_result = http_client.httpGet(self.allocator, search_url, null) catch {
            std.log.info("Could not reach npm registry", .{});
            return;
        };
        defer self.allocator.free(req_result.body);

        if (req_result.status != .ok) {
            std.log.info("npm registry returned status {}", .{req_result.status});
            return;
        }

        const data = req_result.body;
        if (data.len == 0) return;

        // Parse response: {"objects":[{"package":{"name":"@mcp/server","description":"...","links":{"npm":"..."}}}]}
        // json_extract only handles flat key/value pairs, so nested package objects stay manual.
        // Find the "objects" array
        const objects_key = "\"objects\"";
        const objects_idx = std.mem.indexOf(u8, data, objects_key) orelse return;
        var idx = objects_idx + objects_key.len;

        // Skip to array
        while (idx < data.len and data[idx] != '[') : (idx += 1) {}
        if (idx >= data.len) return;
        idx += 1; // skip [

        var count: usize = 0;
        while (idx < data.len and count < 5) {
            while (idx < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[idx]) != null) : (idx += 1) {}
            if (idx >= data.len or data[idx] == ']') break;
            if (data[idx] != '{') break;

            // Parse this package object
            idx += 1;
            var pkg_name: []const u8 = "unknown";
            var pkg_desc: []const u8 = "";
            var pkg_url: ?[]const u8 = null;

            while (idx < data.len) {
                while (idx < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[idx]) != null) : (idx += 1) {}
                if (idx >= data.len or data[idx] == '}') {
                    idx += 1;
                    break;
                }
                if (data[idx] != '"') break;

                idx += 1;
                const fk_start = idx;
                while (idx < data.len and data[idx] != '"') : (idx += 1) {}
                const fk_end = idx;
                const field_key = data[fk_start..fk_end];
                idx += 1;

                while (idx < data.len and data[idx] != ':') : (idx += 1) {}
                idx += 1;
                while (idx < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[idx]) != null) : (idx += 1) {}

                if (data[idx] == '"') {
                    idx += 1;
                    const vs = idx;
                    while (idx < data.len and data[idx] != '"') : (idx += 1) {}
                    const val = data[vs..idx];
                    idx += 1;

                    if (std.mem.eql(u8, field_key, "name")) {
                        pkg_name = val;
                    } else if (std.mem.eql(u8, field_key, "description")) {
                        pkg_desc = val;
                    } else if (std.mem.eql(u8, field_key, "npm")) {
                        pkg_url = val;
                    }
                } else if (data[idx] == '{') {
                    // Skip nested object
                    var depth: usize = 1;
                    idx += 1;
                    while (idx < data.len and depth > 0) : (idx += 1) {
                        if (data[idx] == '{') depth += 1;
                        if (data[idx] == '}') depth -= 1;
                    }
                }

                while (idx < data.len and (data[idx] == ',' or data[idx] == ' ')) : (idx += 1) {}
            }

            try results.append(MCPDiscoveryResult{
                .name = pkg_name,
                .description = pkg_desc,
                .url = pkg_url,
                .type = .npm,
                .install_command = try std.fmt.allocPrint(self.allocator, "npm install -g {s}", .{pkg_name}),
                .capabilities = "",
            });
            count += 1;

            // Skip comma
            while (idx < data.len and (data[idx] == ',' or data[idx] == ' ')) : (idx += 1) {}
        }

        std.log.info("Found {d} MCP servers from npm registry matching '{s}'", .{ count, term });
    }

    fn searchConfig(self: *MCPDiscovery, results: *array_list_compat.ArrayList(MCPDiscoveryResult), term: []const u8) !void {
        // Read user-configured MCP servers from ~/.crushcode/mcp_servers.json
        const config_dir = env.getConfigDir(self.allocator) catch {
            std.log.info("Cannot determine home directory for MCP server config", .{});
            return;
        };
        defer self.allocator.free(config_dir);

        const config_path = try std.fs.path.join(self.allocator, &.{ config_dir, "mcp_servers.json" });
        defer self.allocator.free(config_path);

        const file = std.fs.cwd().openFile(config_path, .{}) catch {
            std.log.info("No MCP server config file at {s}", .{config_path});
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0 or file_size > 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buf);

        const bytes_read = try file.readAll(buf);
        const data = buf[0..bytes_read];

        // Parse JSON: {"server_name":{"transport":"stdio","command":"...","url":"...","description":"..."}}
        // json_extract does not handle nested server config objects, so manual parsing remains here.
        var i: usize = 0;
        while (i < data.len and data[i] != '{') : (i += 1) {}
        if (i >= data.len) return;
        i += 1;

        while (i < data.len) {
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] == '}') break;
            if (data[i] != '"') break;

            // Parse server name
            i += 1;
            const name_start = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const server_name = data[name_start..i];
            i += 1;

            // Skip to value
            while (i < data.len and data[i] != ':') : (i += 1) {}
            i += 1;
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] != '{') break;

            // Parse server config fields
            i += 1;
            var transport: []const u8 = "stdio";
            var command: ?[]const u8 = null;
            var url: ?[]const u8 = null;
            var description: []const u8 = "User-configured MCP server";

            while (i < data.len) {
                while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
                if (i >= data.len or data[i] == '}') {
                    i += 1;
                    break;
                }
                if (data[i] != '"') break;

                i += 1;
                const field_start = i;
                while (i < data.len and data[i] != '"') : (i += 1) {}
                const field_name = data[field_start..i];
                i += 1;

                while (i < data.len and data[i] != ':') : (i += 1) {}
                i += 1;
                while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}

                // Parse string values
                if (data[i] == '"') {
                    i += 1;
                    const vs = i;
                    while (i < data.len and data[i] != '"') : (i += 1) {}
                    const val = data[vs..i];
                    i += 1;

                    if (std.mem.eql(u8, field_name, "transport")) {
                        transport = val;
                    } else if (std.mem.eql(u8, field_name, "command")) {
                        command = val;
                    } else if (std.mem.eql(u8, field_name, "url")) {
                        url = val;
                    } else if (std.mem.eql(u8, field_name, "description")) {
                        description = val;
                    }
                }

                while (i < data.len and (data[i] == ',' or data[i] == ' ')) : (i += 1) {}
            }

            // Filter by search term
            if (std.mem.indexOf(u8, server_name, term) != null or
                std.mem.indexOf(u8, description, term) != null)
            {
                const server_type = if (std.mem.eql(u8, transport, "stdio"))
                    MCPServerType.stdio
                else if (std.mem.eql(u8, transport, "sse"))
                    MCPServerType.sse
                else if (std.mem.eql(u8, transport, "http"))
                    MCPServerType.http
                else if (std.mem.eql(u8, transport, "websocket"))
                    MCPServerType.websocket
                else
                    MCPServerType.local;

                try results.append(MCPDiscoveryResult{
                    .name = server_name,
                    .description = description,
                    .url = url,
                    .type = server_type,
                    .install_command = command,
                    .capabilities = "",
                });
            }

            // Skip trailing comma
            while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        }

        std.log.info("Searched user configuration for MCP servers matching '{s}'", .{term});
    }

    pub fn validateServer(self: *MCPDiscovery, config: MCPServerConfig) !bool {
        _ = self;

        // Validate transport type (MCPServerType and TransportType share tag names)
        const transport_tag = @tagName(config.transport);
        const valid_tags = [_][]const u8{ "stdio", "sse", "http", "websocket" };
        var transport_valid = false;
        for (valid_tags) |valid| {
            if (std.mem.eql(u8, transport_tag, valid)) {
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
