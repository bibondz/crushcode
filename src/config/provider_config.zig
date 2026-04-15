const std = @import("std");
const toml_mod = @import("toml");

pub const ProviderConfig = struct {
    name: []const u8,
    type: ProviderType,
    base_url: []const u8,
    models: []const []const u8,
    default_model: []const u8,
    rate_limits: RateLimits,
    auth: AuthConfig,
    headers: std.json.ObjectMap,
    timeout_seconds: u32,
};

pub const ProviderType = enum {
    api,
    local,
    custom,

    pub fn fromString(s: []const u8) ProviderType {
        if (std.mem.eql(u8, s, "local")) return .local;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return .api;
    }
};

pub const RateLimits = struct {
    requests_per_minute: u32,
    tokens_per_minute: ?u32,
    concurrent_requests: u32,
};

pub const AuthConfig = struct {
    type: AuthType,
    env_var: ?[]const u8,
    header_name: ?[]const u8,
    header_value: ?[]const u8,
};

pub const AuthType = enum {
    api_key,
    bearer_token,
    basic_auth,
    oauth,

    pub fn fromString(s: []const u8) AuthType {
        if (std.mem.eql(u8, s, "bearer_token")) return .bearer_token;
        if (std.mem.eql(u8, s, "basic_auth")) return .basic_auth;
        if (std.mem.eql(u8, s, "oauth")) return .oauth;
        return .api_key;
    }
};

pub const FallbackConfig = struct {
    enabled: bool,
    providers: []const []const u8,
    switch_on_errors: []const []const u8,
    retry_with_fallback: bool,
};

pub const RetryPolicy = struct {
    default_max_attempts: u32,
    default_backoff_factor: f32,
    max_backoff_seconds: u32,
    jitter: bool,
    provider_overrides: std.json.ObjectMap,
};

pub const ErrorHandlingConfig = struct {
    retry_on_errors: []const []const u8,
    fail_fast_on_errors: []const []const u8,
    log_all_errors: bool,
    log_success: bool,
};

pub const PerformanceConfig = struct {
    request_timeout: u32,
    connect_timeout: u32,
    keep_alive: bool,
    compression: []const u8,
};

pub const ExtendedConfig = struct {
    default: struct {
        provider: []const u8,
        model: []const u8,
    },
    providers: std.json.ObjectMap,
    fallback: FallbackConfig,
    retry_policy: RetryPolicy,
    error_handling: ErrorHandlingConfig,
    performance: PerformanceConfig,

    allocator: std.mem.Allocator,
    toml_doc: ?toml_mod.TomlDocument,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .default = .{
                .provider = "",
                .model = "",
            },
            .providers = std.json.ObjectMap.init(allocator),
            .fallback = .{
                .enabled = true,
                .providers = &[_][]const u8{ "anthropic", "openai" },
                .switch_on_errors = &[_][]const u8{ "rate_limit", "timeout", "server_error" },
                .retry_with_fallback = true,
            },
            .retry_policy = .{
                .default_max_attempts = 3,
                .default_backoff_factor = 2.0,
                .max_backoff_seconds = 60,
                .jitter = true,
                .provider_overrides = std.json.ObjectMap.init(allocator),
            },
            .error_handling = .{
                .retry_on_errors = &[_][]const u8{ "timeout", "connection_error", "rate_limit" },
                .fail_fast_on_errors = &[_][]const u8{ "authentication", "invalid_request" },
                .log_all_errors = true,
                .log_success = false,
            },
            .performance = .{
                .request_timeout = 30,
                .connect_timeout = 10,
                .keep_alive = true,
                .compression = "gzip",
            },
            .allocator = allocator,
            .toml_doc = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.providers.deinit();
        self.retry_policy.provider_overrides.deinit();
        if (self.toml_doc) |*doc| {
            doc.deinit();
        }
    }

    /// Load configuration from a TOML file using the real parser
    pub fn loadFromFile(self: *Self, file_path: []const u8) !void {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("Provider config file not found: {s}, using defaults", .{file_path});
                return;
            },
            else => return err,
        };
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        var doc = try toml_mod.TomlDocument.parse(self.allocator, contents);
        errdefer doc.deinit();

        // Extract root-level defaults
        if (doc.root.getString("default_provider")) |p| {
            self.default.provider = p;
        }
        if (doc.root.getString("default_model")) |m| {
            self.default.model = m;
        }

        // Extract [fallback] section
        if (doc.getSection("fallback")) |fallback| {
            if (fallback.getBool("enabled")) |b| self.fallback.enabled = b;
            if (fallback.getBool("retry_with_fallback")) |b| self.fallback.retry_with_fallback = b;
        }

        // Extract [retry_policy] section
        if (doc.getSection("retry_policy")) |retry| {
            if (retry.getInt("default_max_attempts")) |v| self.retry_policy.default_max_attempts = @intCast(v);
            if (retry.getFloat("default_backoff_factor")) |v| self.retry_policy.default_backoff_factor = @floatCast(v);
            if (retry.getInt("max_backoff_seconds")) |v| self.retry_policy.max_backoff_seconds = @intCast(v);
            if (retry.getBool("jitter")) |b| self.retry_policy.jitter = b;
        }

        // Extract [error_handling] section
        if (doc.getSection("error_handling")) |eh| {
            if (eh.getBool("log_all_errors")) |b| self.error_handling.log_all_errors = b;
            if (eh.getBool("log_success")) |b| self.error_handling.log_success = b;
        }

        // Extract [performance] section
        if (doc.getSection("performance")) |perf| {
            if (perf.getInt("request_timeout")) |v| self.performance.request_timeout = @intCast(v);
            if (perf.getInt("connect_timeout")) |v| self.performance.connect_timeout = @intCast(v);
            if (perf.getBool("keep_alive")) |b| self.performance.keep_alive = b;
            if (perf.getString("compression")) |s| self.performance.compression = s;
        }

        self.toml_doc = doc;
    }

    /// Get a provider configuration by name from parsed TOML
    pub fn getProviderConfig(self: Self, provider_name: []const u8) ?ProviderConfig {
        if (self.toml_doc) |doc| {
            // Try direct section: [providers.openai]
            const section_key = std.fmt.allocPrint(self.allocator, "providers.{s}", .{provider_name}) catch return null;
            defer self.allocator.free(section_key);

            if (doc.getSection(section_key)) |provider_sec| {
                return ProviderConfig{
                    .name = provider_name,
                    .type = if (provider_sec.getString("type")) |t| ProviderType.fromString(t) else .api,
                    .base_url = provider_sec.getString("base_url") orelse "",
                    .models = &[_][]const u8{provider_sec.getString("default_model") orelse ""},
                    .default_model = provider_sec.getString("default_model") orelse "",
                    .rate_limits = .{
                        .requests_per_minute = @intCast(provider_sec.getInt("requests_per_minute") orelse 60),
                        .tokens_per_minute = if (provider_sec.getInt("tokens_per_minute")) |v| @intCast(v) else null,
                        .concurrent_requests = @intCast(provider_sec.getInt("concurrent_requests") orelse 5),
                    },
                    .auth = .{
                        .type = if (provider_sec.getString("auth_type")) |t| AuthType.fromString(t) else .api_key,
                        .env_var = provider_sec.getString("env_var"),
                        .header_name = provider_sec.getString("header_name"),
                        .header_value = provider_sec.getString("header_value"),
                    },
                    .headers = std.json.ObjectMap.init(self.allocator),
                    .timeout_seconds = @intCast(provider_sec.getInt("timeout_seconds") orelse 30),
                };
            }
        }
        return null;
    }

    /// Update or add a provider configuration
    pub fn updateProvider(self: *Self, provider_config: ProviderConfig) !void {
        if (self.toml_doc == null) {
            self.toml_doc = toml_mod.TomlDocument.init(self.allocator);
        }
        var doc = &self.toml_doc.?;

        // Create [providers.<name>] section with provider config values
        const section_key = try std.fmt.allocPrint(self.allocator, "providers.{s}", .{provider_config.name});
        defer self.allocator.free(section_key);

        const table = try self.allocator.create(toml_mod.TomlTable);
        table.* = toml_mod.TomlTable.init(self.allocator);

        try table.put("type", .{ .string = try self.allocator.dupe(u8, @tagName(provider_config.type)) });
        try table.put("base_url", .{ .string = try self.allocator.dupe(u8, provider_config.base_url) });
        try table.put("default_model", .{ .string = try self.allocator.dupe(u8, provider_config.default_model) });
        try table.put("requests_per_minute", .{ .integer = provider_config.rate_limits.requests_per_minute });
        try table.put("concurrent_requests", .{ .integer = provider_config.rate_limits.concurrent_requests });
        try table.put("timeout_seconds", .{ .integer = provider_config.timeout_seconds });

        if (provider_config.auth.env_var) |ev| {
            try table.put("env_var", .{ .string = try self.allocator.dupe(u8, ev) });
        }

        const key_copy = try self.allocator.dupe(u8, section_key);
        try doc.sections.put(key_copy, table);
    }

    /// Save configuration to a TOML file
    pub fn saveToFile(self: Self, file_path: []const u8) !void {
        var doc = if (self.toml_doc) |d| d else toml_mod.TomlDocument.init(self.allocator);

        // Ensure root defaults are set
        try doc.root.put("default_provider", .{ .string = try self.allocator.dupe(u8, self.default.provider) });
        try doc.root.put("default_model", .{ .string = try self.allocator.dupe(u8, self.default.model) });

        const output = try toml_mod.TomlDocument.serialize(&doc, self.allocator);
        defer self.allocator.free(output);

        const config_dir = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(config_dir);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(output);
    }
};
