const std = @import("std");
const registry_mod = @import("registry.zig");
const config_mod = @import("../config/config.zig");

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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Load default configuration
        return Self{
            .default = .{
                .provider = "openai",
                .model = "gpt-4",
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
        };
    }

    pub fn deinit(self: *Self) void {
        self.providers.deinit();
        self.retry_policy.provider_overrides.deinit();
    }

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

        // Parse TOML (simplified - in real implementation use TOML parser)
        // For now, we'll load from existing config module and extend
        const base_config = try config_mod.Config.loadOrCreateConfig(self.allocator);

        // Apply defaults for extended configuration
        // TODO: Implement full TOML parsing for provider configuration
    }

    pub fn getProviderConfig(self: Self, provider_name: []const u8) ?ProviderConfig {
        if (self.providers.get(provider_name)) |provider_data| {
            // Convert JSON to ProviderConfig
            // TODO: Implement proper JSON parsing
            return ProviderConfig{
                .name = provider_name,
                .type = .api, // Parse from config
                .base_url = "https://api.openai.com/v1", // Parse from config
                .models = &[_][]const u8{"gpt-4"}, // Parse from config
                .default_model = "gpt-4", // Parse from config
                .rate_limits = .{
                    .requests_per_minute = 60,
                    .tokens_per_minute = 150000,
                    .concurrent_requests = 5,
                },
                .auth = .{
                    .type = .api_key,
                    .env_var = "OPENAI_API_KEY",
                    .header_name = null,
                    .header_value = null,
                },
                .headers = std.json.ObjectMap.init(self.allocator),
                .timeout_seconds = 30,
            };
        }
        return null;
    }

    pub fn updateProvider(self: *Self, provider_config: ProviderConfig) !void {
        // Add or update provider configuration
        // TODO: Implement proper JSON serialization
    }

    pub fn saveToFile(self: Self, file_path: []const u8) !void {
        // Save configuration to TOML file
        // TODO: Implement TOML serialization
    }
};
