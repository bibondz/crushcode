const std = @import("std");
const array_list_compat = @import("array_list_compat");
const QuantizationConfig = @import("quantization_config.zig").QuantizationConfig;
pub const ConfigBackup = @import("backup").ConfigBackup;
pub const ConfigMigrator = @import("backup").ConfigMigrator;
pub const CURRENT_CONFIG_VERSION = @import("backup").CURRENT_CONFIG_VERSION;

pub const MCPServerDef = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: ?[][]const u8 = null,

    pub fn deinit(self: *MCPServerDef, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.url) |u| allocator.free(u);
        if (self.transport) |t| allocator.free(t);
        if (self.command) |c| allocator.free(c);
        if (self.args) |a| {
            for (a) |arg| {
                allocator.free(arg);
            }
            allocator.free(a);
        }
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    default_provider: []const u8,
    default_model: []const u8,
    system_prompt: []const u8,
    api_keys: std.StringHashMap([]const u8),
    quantization: QuantizationConfig,
    mcp_servers: []MCPServerDef,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .default_provider = "",
            .default_model = "",
            .system_prompt = "",
            .api_keys = std.StringHashMap([]const u8).init(allocator),
            .quantization = QuantizationConfig.init(allocator),
            .mcp_servers = &.{},
        };
    }

    pub fn deinit(self: *Config) void {
        var iter = self.api_keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.api_keys.deinit();
        if (self.default_provider.len > 0) self.allocator.free(self.default_provider);
        if (self.default_model.len > 0) self.allocator.free(self.default_model);
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        self.quantization.deinit();
        for (self.mcp_servers) |*server| {
            server.deinit(self.allocator);
        }
        self.allocator.free(self.mcp_servers);
    }

    pub fn load(self: *Config, config_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(config_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        try self.parseToml(buffer);
    }

    pub fn loadDefault(self: *Config) !void {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        self.load(config_path) catch |err| {
            if (err == error.FileNotFound) {
                return error.ConfigNotFound;
            }
            return err;
        };
    }

    pub fn getApiKey(self: *Config, provider_name: []const u8) ?[]const u8 {
        return self.api_keys.get(provider_name);
    }

    pub fn setApiKey(self: *Config, provider_name: []const u8, api_key: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, provider_name);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, api_key);
        errdefer self.allocator.free(value_copy);

        try self.api_keys.put(key_copy, value_copy);
    }

    fn parseToml(self: *Config, content: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var in_quantization_section = false;
        var in_mcp_section = false;
        var mcp_servers = array_list_compat.ArrayList(MCPServerDef).init(self.allocator);
        errdefer {
            for (mcp_servers.items) |*s| s.deinit(self.allocator);
            mcp_servers.deinit();
        }
        var current_mcp_name: ?[]const u8 = null;
        var current_mcp_url: ?[]const u8 = null;
        var current_mcp_transport: ?[]const u8 = null;
        var current_mcp_command: ?[]const u8 = null;
        var quantization_content = array_list_compat.ArrayList(u8).init(self.allocator);
        defer quantization_content.deinit();

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "[")) {
                // Check if entering a new section — save any in-progress MCP server
                if (in_mcp_section) {
                    if (current_mcp_name != null) {
                        try mcp_servers.append(.{
                            .name = current_mcp_name.?,
                            .url = current_mcp_url,
                            .transport = current_mcp_transport,
                            .command = current_mcp_command,
                        });
                    }
                    current_mcp_name = null;
                    current_mcp_url = null;
                    current_mcp_transport = null;
                    current_mcp_command = null;
                }

                if (std.mem.eql(u8, trimmed, "[quantization]")) {
                    in_quantization_section = true;
                    in_mcp_section = false;
                    continue;
                } else if (std.mem.startsWith(u8, trimmed, "[[mcp_servers]]")) {
                    in_mcp_section = true;
                    in_quantization_section = false;
                    continue;
                } else if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[[")) {
                    in_quantization_section = false;
                    in_mcp_section = false;
                    continue;
                }
                continue;
            }

            if (std.mem.indexOfScalar(u8, trimmed, '=') != null) {
                if (in_quantization_section) {
                    try quantization_content.appendSlice(trimmed);
                    try quantization_content.append('\n');
                } else if (in_mcp_section) {
                    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=').?;
                    const mcp_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                    const mcp_val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                    if (std.mem.eql(u8, mcp_key, "name")) {
                        current_mcp_name = try self.allocator.dupe(u8, mcp_val);
                    } else if (std.mem.eql(u8, mcp_key, "url")) {
                        current_mcp_url = try self.allocator.dupe(u8, mcp_val);
                    } else if (std.mem.eql(u8, mcp_key, "transport")) {
                        current_mcp_transport = try self.allocator.dupe(u8, mcp_val);
                    } else if (std.mem.eql(u8, mcp_key, "command")) {
                        current_mcp_command = try self.allocator.dupe(u8, mcp_val);
                    }
                } else {
                    try parseKeyValue(self, trimmed);
                }
            }
        }

        // Parse quantization config if we collected any
        if (quantization_content.items.len > 0) {
            try self.quantization.loadFromToml(quantization_content.items);
        }

        // Save any trailing MCP server
        if (in_mcp_section and current_mcp_name != null) {
            try mcp_servers.append(.{
                .name = current_mcp_name.?,
                .url = current_mcp_url,
                .transport = current_mcp_transport,
                .command = current_mcp_command,
            });
        }
        self.mcp_servers = try mcp_servers.toOwnedSlice();
    }

    fn parseKeyValue(self: *Config, line: []const u8) !void {
        const eq_pos = std.mem.indexOfScalar(u8, line, '=').?;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\"");

        if (std.mem.eql(u8, key, "default_provider")) {
            self.default_provider = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "default_model")) {
            self.default_model = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "system_prompt")) {
            self.system_prompt = try self.allocator.dupe(u8, value);
        } else {
            try self.setApiKey(key, value);
        }
    }

    pub fn getSystemPrompt(self: *Config) ?[]const u8 {
        if (self.system_prompt.len > 0) return self.system_prompt;
        return null;
    }
};

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_CONFIG")) |path| {
        return path;
    } else |_| {}

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |userprofile| {
                return std.fmt.allocPrint(allocator, "{s}\\.crushcode\\config.toml", .{userprofile});
            } else |_| {
                return error.HomeNotFound;
            }
        }
        return err;
    };

    return std.fmt.allocPrint(allocator, "{s}/.crushcode/config.toml", .{home});
}

pub fn createDefaultConfig(config_path: []const u8) !void {
    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(config_dir);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();

    var default_config = Config.init(std.heap.page_allocator);
    defer default_config.deinit();

    const api_keys_section =
        \\# Crushcode Configuration File
        \\
        \\# Default provider and model
        \\default_provider = "openai"
        \\default_model = "gpt-4o"
        \\
        \\# API Keys (replace with your actual keys)
        \\[api_keys]
        \\openai = "sk-your-openai-api-key"
        \\anthropic = "sk-ant-your-anthropic-api-key"
        \\gemini = "AIzaSy-your-gemini-api-key"
        \\xai = "xai-your-xai-api-key"
        \\mistral = "your-mistral-api-key"
        \\groq = "gsk_your-groq-api-key"
        \\deepseek = "sk-your-deepseek-api-key"
        \\together = "your-together-api-key"
        \\azure = "your-azure-api-key"
        \\vertexai = "your-vertexai-api-key"
        \\bedrock = "your-bedrock-api-key"
        \\ollama = ""
        \\lm_studio = ""
        \\llama_cpp = ""
        \\openrouter = "sk-or-your-openrouter-api-key"
        \\zai = "your-zai-api-key"
        \\vercel_gateway = "your-vercel-api-key"
        \\opencode_zen = "your-opencode-zen-api-key"
        \\opencode_go = "your-opencode-go-api-key"
    ;

    const quantization_section = default_config.quantization.defaultToml();

    var default_content = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    defer default_content.deinit();

    try default_content.appendSlice(api_keys_section);
    try default_content.append('\n');
    try default_content.append('\n');
    try default_content.appendSlice(quantization_section);
    try default_content.append('\n');
    try default_content.appendSlice(
        \\
        \\# MCP Server Configuration
        \\#[[mcp_servers]]
        \\#name = "filesystem"
        \\#transport = "stdio"
        \\#command = "npx"
        \\#url = ""
        \\
    );

    _ = try file.writeAll(default_content.items);
}

pub fn loadOrCreateConfig(allocator: std.mem.Allocator) !Config {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    var config = Config.init(allocator);

    config.load(config_path) catch |err| {
        if (err == error.FileNotFound) {
            try createDefaultConfig(config_path);
            try config.load(config_path);
        } else {
            return err;
        }
    };

    return config;
}
