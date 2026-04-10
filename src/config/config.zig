const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    default_provider: []const u8,
    default_model: []const u8,
    api_keys: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .default_provider = "",
            .default_model = "",
            .api_keys = std.StringHashMap([]const u8).init(allocator),
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

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "[")) {
                continue;
            }

            if (std.mem.indexOfScalar(u8, trimmed, '=') != null) {
                try parseKeyValue(self, trimmed);
            }
        }
    }

    fn parseKeyValue(self: *Config, line: []const u8) !void {
        const eq_pos = std.mem.indexOfScalar(u8, line, '=').?;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\"");

        if (std.mem.eql(u8, key, "default_provider")) {
            self.default_provider = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "default_model")) {
            self.default_model = try self.allocator.dupe(u8, value);
        } else {
            try self.setApiKey(key, value);
        }
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

    const default_content =
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

    _ = try file.writeAll(default_content);
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
