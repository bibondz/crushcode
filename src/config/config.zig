const std = @import("std");
const array_list_compat = @import("array_list_compat");
const env = @import("env");
const project_mod = @import("project");
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

pub const ProviderOverride = struct {
    base_url: ?[]const u8 = null,

    pub fn deinit(self: *ProviderOverride, allocator: std.mem.Allocator) void {
        if (self.base_url) |u| allocator.free(u);
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
    /// Model parameters — max_tokens per response (default: 4096)
    max_tokens: u32 = 4096,
    /// Model parameters — temperature 0.0–2.0 (default: 0.7)
    temperature: f32 = 0.7,
    /// Per-provider config overrides (base_url, etc.)
    provider_overrides: std.StringHashMap(ProviderOverride),
    /// OAuth callback port (default: 19876)
    oauth_port: u16 = 19876,
    /// Skills directory — defaults to ~/.config/crushcode/skills/
    skills_dir: ?[]const u8 = null,
    /// Commands directory — defaults to ~/.config/crushcode/commands/
    commands_dir: ?[]const u8 = null,
    /// Remote skill URLs — fetch index.json and cache skills from these endpoints
    skill_urls: [][]const u8 = &.{},
    /// Shell sandbox mode: "off", "cwd", "custom:/path" (default: "cwd")
    sandbox_mode: []const u8 = "",
    /// External directories AI can read files from (comma-separated paths)
    allowed_paths: [][]const u8 = &.{},
    /// Enable desktop notifications (default: false, opt-in via CRUSHCODE_NOTIFY=1)
    notifications_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .default_provider = "",
            .default_model = "",
            .system_prompt = "",
            .api_keys = std.StringHashMap([]const u8).init(allocator),
            .quantization = QuantizationConfig.init(allocator),
            .mcp_servers = &.{},
            .max_tokens = 4096,
            .temperature = 0.7,
            .provider_overrides = std.StringHashMap(ProviderOverride).init(allocator),
            .oauth_port = 19876,
            .skills_dir = null,
            .commands_dir = null,
            .notifications_enabled = false,
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
        {
            var po_iter = self.provider_overrides.iterator();
            while (po_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            self.provider_overrides.deinit();
        }
        if (self.skills_dir) |d| self.allocator.free(d);
        if (self.commands_dir) |d| self.allocator.free(d);
        for (self.skill_urls) |u| self.allocator.free(u);
        self.allocator.free(self.skill_urls);
        if (self.sandbox_mode.len > 0) self.allocator.free(self.sandbox_mode);
        for (self.allowed_paths) |p| self.allocator.free(p);
        self.allocator.free(self.allowed_paths);
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
        var in_model_section = false;
        var in_provider_overrides_section = false;
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
        var current_override_provider: ?[]const u8 = null;
        var current_override_base_url: ?[]const u8 = null;

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
                // Save any in-progress provider override
                if (in_provider_overrides_section) {
                    try self.saveProviderOverride(current_override_provider, current_override_base_url);
                    current_override_provider = null;
                    current_override_base_url = null;
                }

                if (std.mem.eql(u8, trimmed, "[quantization]")) {
                    in_quantization_section = true;
                    in_mcp_section = false;
                    in_model_section = false;
                    in_provider_overrides_section = false;
                    continue;
                } else if (std.mem.eql(u8, trimmed, "[model]")) {
                    in_model_section = true;
                    in_quantization_section = false;
                    in_mcp_section = false;
                    in_provider_overrides_section = false;
                    continue;
                } else if (std.mem.startsWith(u8, trimmed, "[[mcp_servers]]")) {
                    in_mcp_section = true;
                    in_quantization_section = false;
                    in_model_section = false;
                    in_provider_overrides_section = false;
                    continue;
                } else if (std.mem.startsWith(u8, trimmed, "[[provider_overrides]]")) {
                    in_provider_overrides_section = true;
                    in_quantization_section = false;
                    in_model_section = false;
                    in_mcp_section = false;
                    continue;
                } else if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[[")) {
                    in_quantization_section = false;
                    in_mcp_section = false;
                    in_model_section = false;
                    in_provider_overrides_section = false;
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
                } else if (in_model_section) {
                    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=').?;
                    const model_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                    const model_val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                    if (std.mem.eql(u8, model_key, "max_tokens")) {
                        self.max_tokens = std.fmt.parseInt(u32, model_val, 10) catch 4096;
                    } else if (std.mem.eql(u8, model_key, "temperature")) {
                        self.temperature = std.fmt.parseFloat(f32, model_val) catch 0.7;
                    }
                } else if (in_provider_overrides_section) {
                    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=').?;
                    const po_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                    const po_val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                    if (std.mem.eql(u8, po_key, "provider")) {
                        current_override_provider = try self.allocator.dupe(u8, po_val);
                    } else if (std.mem.eql(u8, po_key, "base_url")) {
                        current_override_base_url = try self.allocator.dupe(u8, po_val);
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

        // Save any trailing provider override
        if (in_provider_overrides_section) {
            try self.saveProviderOverride(current_override_provider, current_override_base_url);
        }
    }

    fn saveProviderOverride(self: *Config, provider: ?[]const u8, base_url: ?[]const u8) !void {
        const name = provider orelse return;
        const key_copy = try self.allocator.dupe(u8, name);
        const url_copy: ?[]const u8 = if (base_url) |u| try self.allocator.dupe(u8, u) else null;
        try self.provider_overrides.put(key_copy, .{ .base_url = url_copy });
    }

    /// Get provider override base_url if configured, null otherwise.
    pub fn getProviderOverrideUrl(self: *Config, provider_name: []const u8) ?[]const u8 {
        if (self.provider_overrides.get(provider_name)) |override| {
            return override.base_url;
        }
        return null;
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
        } else if (std.mem.eql(u8, key, "skill_urls")) {
            // Comma-separated list of URLs for remote skill discovery
            for (self.skill_urls) |u| self.allocator.free(u);
            self.allocator.free(self.skill_urls);
            self.skill_urls = try self.parseCommaList(value);
        } else if (std.mem.eql(u8, key, "sandbox_mode")) {
            self.sandbox_mode = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "allowed_paths")) {
            for (self.allowed_paths) |p| self.allocator.free(p);
            self.allocator.free(self.allowed_paths);
            self.allowed_paths = try self.parseCommaList(value);
        } else if (std.mem.eql(u8, key, "notifications_enabled")) {
            // Parse boolean: true/1/on/yes -> true, everything else -> false
            const lower_val = blk: {
                var buf: [32]u8 = undefined;
                const copied = std.ascii.lowerString(&buf, value);
                break :blk copied;
            };
            self.notifications_enabled = std.mem.eql(u8, lower_val, "true") or
                std.mem.eql(u8, lower_val, "1") or
                std.mem.eql(u8, lower_val, "on") or
                std.mem.eql(u8, lower_val, "yes");
        } else {
            try self.setApiKey(key, value);
        }
    }

    /// Parse comma-separated string into owned slice of strings.
    fn parseCommaList(self: *Config, value: []const u8) ![][]const u8 {
        var items = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit();
        }
        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t\"'[]");
            if (trimmed.len == 0) continue;
            try items.append(try self.allocator.dupe(u8, trimmed));
        }
        return items.toOwnedSlice();
    }

    pub fn getSystemPrompt(self: *Config) ?[]const u8 {
        if (self.system_prompt.len > 0) return self.system_prompt;
        return null;
    }

    /// Merge an override config (project-local) into this config (user-level).
    /// Override values take precedence per field-specific rules.
    /// Strings: override wins if non-empty.
    /// Numbers: override wins if different from the default.
    /// HashMaps: merge — override keys replace matching user keys.
    /// mcp_servers: override replaces entirely.
    pub fn mergeOverride(self: *Config, override: *Config) !void {
        // Strings: override wins if non-empty
        if (override.default_provider.len > 0) {
            if (self.default_provider.len > 0) self.allocator.free(self.default_provider);
            self.default_provider = try self.allocator.dupe(u8, override.default_provider);
        }
        if (override.default_model.len > 0) {
            if (self.default_model.len > 0) self.allocator.free(self.default_model);
            self.default_model = try self.allocator.dupe(u8, override.default_model);
        }
        if (override.system_prompt.len > 0) {
            if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
            self.system_prompt = try self.allocator.dupe(u8, override.system_prompt);
        }

        // Numbers: override wins if != default
        if (override.max_tokens != 4096) {
            self.max_tokens = override.max_tokens;
        }
        if (override.temperature != 0.7) {
            self.temperature = override.temperature;
        }

        // api_keys HashMap: merge — override keys replace, user-only keys preserved
        var override_key_iter = override.api_keys.iterator();
        while (override_key_iter.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            const val_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            // If key already exists, free old value (and old key if re-inserted)
            if (self.api_keys.get(entry.key_ptr.*)) |old_val| {
                self.allocator.free(old_val);
                // We can reuse the existing key allocation
                self.allocator.free(key_copy);
                try self.api_keys.put(entry.key_ptr.*, val_copy);
            } else {
                try self.api_keys.put(key_copy, val_copy);
            }
        }

        // mcp_servers: override replaces entirely
        // Free old servers first
        for (self.mcp_servers) |*server| {
            server.deinit(self.allocator);
        }
        self.allocator.free(self.mcp_servers);
        // Dupe override servers into self's allocator
        var new_servers = array_list_compat.ArrayList(MCPServerDef).init(self.allocator);
        for (override.mcp_servers) |*server| {
            var duped_server: MCPServerDef = .{
                .name = try self.allocator.dupe(u8, server.name),
                .url = null,
                .transport = null,
                .command = null,
                .args = null,
            };
            if (server.url) |u| duped_server.url = try self.allocator.dupe(u8, u);
            if (server.transport) |t| duped_server.transport = try self.allocator.dupe(u8, t);
            if (server.command) |c| duped_server.command = try self.allocator.dupe(u8, c);
            if (server.args) |args| {
                const duped_args = try self.allocator.alloc([]const u8, args.len);
                for (args, 0..) |arg, i| {
                    duped_args[i] = try self.allocator.dupe(u8, arg);
                }
                duped_server.args = duped_args;
            }
            try new_servers.append(duped_server);
        }
        self.mcp_servers = try new_servers.toOwnedSlice();

        // provider_overrides HashMap: merge — same as api_keys
        var override_po_iter = override.provider_overrides.iterator();
        while (override_po_iter.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            var duped_po: ProviderOverride = .{ .base_url = null };
            if (entry.value_ptr.*.base_url) |u| {
                duped_po.base_url = try self.allocator.dupe(u8, u);
            }
            // If key already exists, free old entry
            if (self.provider_overrides.get(entry.key_ptr.*)) |old_po| {
                self.allocator.free(old_po.base_url orelse "");
                // Find and free the old key
                var old_key_to_free: ?[]const u8 = null;
                var self_iter = self.provider_overrides.iterator();
                while (self_iter.next()) |self_entry| {
                    if (std.mem.eql(u8, self_entry.key_ptr.*, entry.key_ptr.*)) {
                        old_key_to_free = self_entry.key_ptr.*;
                        break;
                    }
                }
                if (old_key_to_free) |ok| self.allocator.free(ok);
            }
            try self.provider_overrides.put(key_copy, duped_po);
        }
    }
};

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_CONFIG")) |path| {
        return path;
    } else |_| {}

    const config_dir = try env.getConfigDir(allocator);
    defer allocator.free(config_dir);

    return std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
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
        \\# Default provider and model — run 'crushcode connect' to set up
        \\# default_provider = ""
        \\# default_model = ""
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
        \\lm-studio = ""
        \\llama-cpp = ""
        \\openrouter = "sk-or-your-openrouter-api-key"
        \\zai = "your-zai-api-key"
        \\vercel-gateway = "your-vercel-api-key"
        \\opencode-zen = "your-opencode-zen-api-key"
        \\opencode-go = "your-opencode-go-api-key"
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
    // Run migration from legacy ~/.crushcode/ if needed
    const migrate = @import("migrate");
    if (migrate.needsMigration(allocator)) {
        migrate.runMigration(allocator) catch |err| {
            std.log.warn("Migration failed: {} — continuing with existing config", .{err});
        };
    }

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

    // Hierarchical config: project-local .crushcode/config.toml overrides user-level
    if (project_mod.getProjectConfigPath(allocator)) |project_config_path| {
        defer allocator.free(project_config_path);
        var project_config = Config.init(allocator);
        project_config.load(project_config_path) catch |err| {
            std.log.warn("Failed to load project config: {} — using user config only", .{err});
            project_config.deinit();
            return config;
        };
        try config.mergeOverride(&project_config);
        project_config.deinit();
    }

    // Ensure providers.toml exists (idempotent — skips if already present)
    @import("providers_file").createDefaultProvidersFile() catch {};

    // Resolve skills and commands directories if not set by config
    if (config.skills_dir == null) {
        const config_dir = try env.getConfigDir(allocator);
        defer allocator.free(config_dir);
        config.skills_dir = try std.fs.path.join(allocator, &.{ config_dir, "skills" });
    }
    if (config.commands_dir == null) {
        const config_dir = try env.getConfigDir(allocator);
        defer allocator.free(config_dir);
        config.commands_dir = try std.fs.path.join(allocator, &.{ config_dir, "commands" });
    }

    // Check CRUSHCODE_NOTIFY environment variable (overrides config)
    if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_NOTIFY")) |env_val| {
        defer allocator.free(env_val);
        const lower_val = blk: {
            var buf: [16]u8 = undefined;
            const copied = std.ascii.lowerString(&buf, env_val);
            break :blk copied;
        };
        config.notifications_enabled = std.mem.eql(u8, lower_val, "true") or
            std.mem.eql(u8, lower_val, "1") or
            std.mem.eql(u8, lower_val, "on") or
            std.mem.eql(u8, lower_val, "yes");
    } else |_| {}

    return config;
}

// ==================== Tests ====================

const testing = std.testing;

test "Config.init defaults" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try testing.expectEqualStrings("", config.default_provider);
    try testing.expectEqualStrings("", config.default_model);
    try testing.expectEqualStrings("", config.system_prompt);
    try testing.expectEqual(@as(u32, 4096), config.max_tokens);
    try testing.expectEqual(@as(f32, 0.7), config.temperature);
    try testing.expectEqual(@as(u16, 19876), config.oauth_port);
    try testing.expectEqual(@as(usize, 0), config.api_keys.count());
    try testing.expectEqual(@as(usize, 0), config.mcp_servers.len);
    try testing.expectEqual(@as(usize, 0), config.provider_overrides.count());
    try testing.expect(config.skills_dir == null);
}

test "Config deinit clean" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    config.deinit();
}

test "Config.getApiKey returns null for unset provider" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try testing.expect(config.getApiKey("openai") == null);
    try testing.expect(config.getApiKey("anthropic") == null);
}

test "Config.setApiKey and getApiKey round-trip" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.setApiKey("openai", "sk-test-key");
    const result = config.getApiKey("openai");
    try testing.expect(result != null);
    try testing.expectEqualStrings("sk-test-key", result.?);
}

test "Config.setApiKey multiple keys" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.setApiKey("openai", "sk-openai-key");
    try config.setApiKey("anthropic", "sk-ant-key");
    try config.setApiKey("gemini", "AIza-key");

    try testing.expectEqualStrings("sk-openai-key", config.getApiKey("openai").?);
    try testing.expectEqualStrings("sk-ant-key", config.getApiKey("anthropic").?);
    try testing.expectEqualStrings("AIza-key", config.getApiKey("gemini").?);
    try testing.expectEqual(@as(usize, 3), config.api_keys.count());
}

test "Config.setApiKey overwrite existing key" {
    // setApiKey leaks old value + new key_copy on overwrite — use page_allocator
    const allocator = std.heap.page_allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.setApiKey("openai", "old-key");
    try testing.expectEqualStrings("old-key", config.getApiKey("openai").?);

    try config.setApiKey("openai", "new-key");
    try testing.expectEqualStrings("new-key", config.getApiKey("openai").?);
    try testing.expectEqual(@as(usize, 1), config.api_keys.count());
}

test "Config.saveProviderOverride stores url" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.saveProviderOverride("openrouter", "https://custom.api.com/v1");

    const url = config.getProviderOverrideUrl("openrouter");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://custom.api.com/v1", url.?);
}

test "Config.saveProviderOverride null provider is no-op" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.saveProviderOverride(null, "https://example.com");
    try testing.expectEqual(@as(usize, 0), config.provider_overrides.count());
}

test "Config.saveProviderOverride null base_url stores override with null url" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.saveProviderOverride("ollama", null);

    const url = config.getProviderOverrideUrl("ollama");
    try testing.expect(url == null);
    try testing.expectEqual(@as(usize, 1), config.provider_overrides.count());
}

test "Config.getProviderOverrideUrl returns null for unknown provider" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try testing.expect(config.getProviderOverrideUrl("nonexistent") == null);
}

test "MCPServerDef.deinit cleanup" {
    const allocator = testing.allocator;
    const name = try allocator.dupe(u8, "filesystem");
    const url = try allocator.dupe(u8, "http://localhost:8080");
    const transport = try allocator.dupe(u8, "stdio");
    const command = try allocator.dupe(u8, "npx");
    const args = try allocator.alloc([]const u8, 2);
    args[0] = try allocator.dupe(u8, "arg1");
    args[1] = try allocator.dupe(u8, "arg2");

    var server = MCPServerDef{
        .name = name,
        .url = url,
        .transport = transport,
        .command = command,
        .args = args,
    };
    server.deinit(allocator);
}

test "ProviderOverride.deinit cleanup" {
    const allocator = testing.allocator;
    const base_url = try allocator.dupe(u8, "https://custom.api.com/v1");

    var override = ProviderOverride{ .base_url = base_url };
    override.deinit(allocator);
}

test "Config.getSystemPrompt returns null when empty" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try testing.expect(config.getSystemPrompt() == null);
}

// ============================================================
// Pure Function Tests
// ============================================================

test "Config.parseCommaList - empty string returns empty slice" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const result = try config.parseCommaList("");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "Config.parseCommaList - single item" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const result = try config.parseCommaList("single");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("single", result[0]);
}

test "Config.parseCommaList - multiple items with trimming" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const result = try config.parseCommaList("one, two, three");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("one", result[0]);
    try testing.expectEqualStrings("two", result[1]);
    try testing.expectEqualStrings("three", result[2]);
}

test "Config.parseCommaList - handles quotes and brackets" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const result = try config.parseCommaList("[\"url1\"], \"url2\"");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("url1", result[0]);
    try testing.expectEqualStrings("url2", result[1]);
}

test "Config.parseCommaList - skips empty items" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const result = try config.parseCommaList("one, , three");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("one", result[0]);
    try testing.expectEqualStrings("three", result[1]);
}

test "Config.getSystemPrompt returns value when set" {
    const allocator = testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    const test_prompt = "You are a helpful assistant.";
    config.system_prompt = try allocator.dupe(u8, test_prompt);
    const result = config.getSystemPrompt();
    try testing.expect(result != null);
    try testing.expectEqualStrings(test_prompt, result.?);
}

test "Config.mergeOverride - strings override when non-empty" {
    const user_allocator = testing.allocator;
    const override_allocator = testing.allocator;

    var user_config = Config.init(user_allocator);
    defer user_config.deinit();

    var override_config = Config.init(override_allocator);
    defer override_config.deinit();

    // Set user config values
    user_config.default_provider = try user_allocator.dupe(u8, "openai");
    user_config.default_model = try user_allocator.dupe(u8, "gpt-3.5-turbo");

    // Set override config values
    override_config.default_provider = try override_allocator.dupe(u8, "anthropic");
    override_config.default_model = try override_allocator.dupe(u8, "claude-3");

    try user_config.mergeOverride(&override_config);

    try testing.expectEqualStrings("anthropic", user_config.default_provider);
    try testing.expectEqualStrings("claude-3", user_config.default_model);
}

test "Config.mergeOverride - numbers override when not default" {
    const user_allocator = testing.allocator;
    const override_allocator = testing.allocator;

    var user_config = Config.init(user_allocator);
    defer user_config.deinit();

    var override_config = Config.init(override_allocator);
    defer override_config.deinit();

    user_config.max_tokens = 2048;
    user_config.temperature = 0.5;

    override_config.max_tokens = 8192;
    override_config.temperature = 1.0;

    try user_config.mergeOverride(&override_config);

    try testing.expectEqual(@as(u32, 8192), user_config.max_tokens);
    try testing.expectEqual(@as(f32, 1.0), user_config.temperature);
}

test "Config.mergeOverride - api_keys merge (override replaces)" {
    const user_allocator = testing.allocator;
    const override_allocator = testing.allocator;

    var user_config = Config.init(user_allocator);
    defer user_config.deinit();

    var override_config = Config.init(override_allocator);
    defer override_config.deinit();

    try user_config.setApiKey("openai", "user-key");
    try user_config.setApiKey("gemini", "user-gemini");

    try override_config.setApiKey("openai", "override-key");
    try override_config.setApiKey("anthropic", "override-anthropic");

    try user_config.mergeOverride(&override_config);

    try testing.expectEqualStrings("override-key", user_config.getApiKey("openai").?);
    try testing.expectEqualStrings("user-gemini", user_config.getApiKey("gemini").?);
    try testing.expectEqualStrings("override-anthropic", user_config.getApiKey("anthropic").?);
}

test "Config.mergeOverride - mcp_servers replace entirely" {
    const user_allocator = testing.allocator;
    const override_allocator = testing.allocator;

    var user_config = Config.init(user_allocator);
    defer user_config.deinit();

    var override_config = Config.init(override_allocator);
    defer override_config.deinit();

    // User has one server
    const user_server_name = try user_allocator.dupe(u8, "user-filesystem");
    user_config.mcp_servers = try user_allocator.alloc(MCPServerDef, 1);
    user_config.mcp_servers[0] = .{ .name = user_server_name };

    // Override has two servers
    const override_server1_name = try override_allocator.dupe(u8, "override-filesystem");
    const override_server2_name = try override_allocator.dupe(u8, "override-brave-search");
    override_config.mcp_servers = try override_allocator.alloc(MCPServerDef, 2);
    override_config.mcp_servers[0] = .{ .name = override_server1_name };
    override_config.mcp_servers[1] = .{ .name = override_server2_name };

    try user_config.mergeOverride(&override_config);

    try testing.expectEqual(@as(usize, 2), user_config.mcp_servers.len);
    try testing.expectEqualStrings("override-filesystem", user_config.mcp_servers[0].name);
    try testing.expectEqualStrings("override-brave-search", user_config.mcp_servers[1].name);
}

test "Config.mergeOverride - provider_overrides merge" {
    const user_allocator = testing.allocator;
    const override_allocator = testing.allocator;

    var user_config = Config.init(user_allocator);
    defer user_config.deinit();

    var override_config = Config.init(override_allocator);
    defer override_config.deinit();

    try user_config.saveProviderOverride("openrouter", "https://user.api.com");
    try override_config.saveProviderOverride("openrouter", "https://override.api.com");
    try override_config.saveProviderOverride("ollama", "http://localhost:11434");

    try user_config.mergeOverride(&override_config);

    try testing.expectEqualStrings("https://override.api.com", user_config.getProviderOverrideUrl("openrouter").?);
    try testing.expectEqualStrings("http://localhost:11434", user_config.getProviderOverrideUrl("ollama").?);
}
