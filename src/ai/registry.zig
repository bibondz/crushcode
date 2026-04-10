const std = @import("std");

pub const ProviderType = enum {
    openai,
    anthropic,
    gemini,
    xai,
    mistral,
    groq,
    deepseek,
    together,
    azure,
    vertexai,
    bedrock,
    ollama,
    lm_studio,
    llama_cpp,
    openrouter,
    zai,
    vercel_gateway,
    opencode_zen,
    opencode_go,

    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .openai => "openai",
            .anthropic => "anthropic",
            .gemini => "gemini",
            .xai => "xai",
            .mistral => "mistral",
            .groq => "groq",
            .deepseek => "deepseek",
            .together => "together",
            .azure => "azure",
            .vertexai => "vertexai",
            .bedrock => "bedrock",
            .ollama => "ollama",
            .lm_studio => "lm-studio",
            .llama_cpp => "llama-cpp",
            .openrouter => "openrouter",
            .zai => "zai",
            .vercel_gateway => "vercel-gateway",
            .opencode_zen => "opencode-zen",
            .opencode_go => "opencode-go",
        };
    }
};

pub const ProviderConfig = struct {
    base_url: []const u8,
    api_key: []const u8,
    models: []const []const u8,
    is_models_static: bool = false,
};

pub const Provider = struct {
    name: []const u8,
    config: ProviderConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, provider_type: ProviderType) !Provider {
        const name = try allocator.dupe(u8, provider_type.toString());
        errdefer allocator.free(name);

        const config = try getConfigForProvider(allocator, provider_type);
        errdefer allocator.free(config.base_url);
        errdefer allocator.free(config.api_key);
        if (!config.is_models_static) allocator.free(config.models);

        return Provider{
            .name = name,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.name);
        self.allocator.free(self.config.base_url);
        self.allocator.free(self.config.api_key);
        if (!self.config.is_models_static) self.allocator.free(self.config.models);
    }
};

fn getConfigForProvider(allocator: std.mem.Allocator, provider_type: ProviderType) !ProviderConfig {
    return switch (provider_type) {
        .openai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gpt-4o", "gpt-4-turbo", "gpt-4", "gpt-3.5-turbo" },
            .is_models_static = true,
        },
        .anthropic => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-3-sonnet-20240229" },
            .is_models_static = true,
        },
        .gemini => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://generativelanguage.googleapis.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gemini-2.0-flash-exp", "gemini-1.5-pro", "gemini-1.5-flash" },
            .is_models_static = true,
        },
        .xai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.x.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "grok-beta", "grok-2-1212" },
            .is_models_static = true,
        },
        .mistral => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.mistral.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest" },
            .is_models_static = true,
        },
        .groq => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.groq.com/openai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "llama-3.3-70b-versatile", "llama-3.3-8b-instant", "mixtral-8x7b-32768" },
            .is_models_static = true,
        },
        .deepseek => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.deepseek.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "deepseek-chat", "deepseek-coder" },
            .is_models_static = true,
        },
        .together => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.together.xyz/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", "mistralai/Mixtral-8x7B-Instruct-v0.1" },
            .is_models_static = true,
        },
        .azure => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gpt-4o", "gpt-4-turbo", "gpt-35-turbo" },
            .is_models_static = true,
        },
        .vertexai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/YOUR_LOCATION/publishers/google/models"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gemini-2.0-flash-exp", "gemini-1.5-pro-001", "gemini-1.5-flash-001" },
            .is_models_static = true,
        },
        .bedrock => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://bedrock-runtime.us-east-1.amazonaws.com"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "anthropic.claude-3-5-sonnet-20241022-v2:0", "us.anthropic.claude-3-5-haiku-20241022-v1:0" },
            .is_models_static = true,
        },
        .ollama => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:11434/api"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{"phi3.5:3.8b-mini-instruct-q5_K_M"},
            .is_models_static = true,
        },
        .lm_studio => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:1234/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "local-model", "your-model-name" },
            .is_models_static = true,
        },
        .llama_cpp => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:8080/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "default", "your-model" },
            .is_models_static = true,
        },
        .openrouter => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://openrouter.ai/api/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "openai/gpt-4o", "anthropic/claude-3.5-sonnet", "google/gemini-pro-1.5" },
            .is_models_static = true,
        },
        .zai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://open.bigmodel.cn/api/paas/v4"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "glm-4-flash", "glm-4-plus", "glm-4.5-air" },
            .is_models_static = true,
        },
        .vercel_gateway => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.vercel.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{"your-provider-model"},
            .is_models_static = true,
        },
        .opencode_zen => ProviderConfig{
            // OpenCode Zen - models tested by OpenCode team
            .base_url = try allocator.dupe(u8, "https://opencode.ai/zen/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{
                "opencode/gpt-5.1-codex",
                "opencode/claude-sonnet-4.5",
                "opencode/gemini-2.5-pro",
                "opencode/grok-2",
                "opencode/qwen3-coder-480b",
                "opencode/gpt-5-nano", // Free model
                "opencode/big-pickle", // Free model
            },
            .is_models_static = true,
        },
        .opencode_go => ProviderConfig{
            // OpenCode Go - low cost subscription for open coding models
            .base_url = try allocator.dupe(u8, "https://opencode.ai/go/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{
                "opencode/qwen3-8b",
                "opencode/qwen3-14b",
                "opencode/llama3.1-8b",
                "opencode/llama3.1-70b",
            },
            .is_models_static = true,
        },
    };
}

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(Provider),

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return ProviderRegistry{
            .allocator = allocator,
            .providers = std.StringHashMap(Provider).init(allocator),
        };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.providers.deinit();
    }

    pub fn registerProvider(self: *ProviderRegistry, provider_type: ProviderType) !void {
        const provider = try Provider.init(self.allocator, provider_type);
        try self.providers.put(provider.name, provider);
    }

    /// Fetch available models from OpenCode Zen API
    pub fn fetchOpenCodeZenModels(self: *ProviderRegistry, api_key: []const u8) ![]const []const u8 {
        if (api_key.len == 0) {
            return error.AuthenticationRequired;
        }

        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse("https://opencode.ai/zen/v1/models");

        var request = try client.open(.GET, uri, .{});
        defer request.deinit();

        try request.headers.append("Authorization", try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key}));

        const response = try request.send();
        const body = try response.body().?.readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(body);

        if (response.status != .ok) {
            return error.FetchFailed;
        }

        // Parse JSON response to extract model IDs
        var model_list = std.ArrayList([]const u8).init(self.allocator);

        // Simple JSON parsing - look for "id":"..." patterns
        var search_idx: usize = 0;
        while (search_idx < body.len) {
            if (std.mem.indexOf(u8, body[search_idx..], "\"id\":\"")) |idx| {
                const start = search_idx + idx + 5;
                if (start < body.len) {
                    if (std.mem.indexOf(u8, body[start..], "\"")) |end_idx| {
                        const model_id = body[start..(start + end_idx)];
                        try model_list.append(try std.fmt.allocPrint(self.allocator, "opencode/{s}", .{model_id}));
                        search_idx = start + end_idx;
                        continue;
                    }
                }
            }
            search_idx += 1;
        }

        return model_list.toOwnedSlice();
    }

    pub fn registerAllProviders(self: *ProviderRegistry) !void {
        const all_providers = comptime std.enums.values(ProviderType);
        inline for (all_providers) |provider_type| {
            try self.registerProvider(provider_type);
        }
    }

    pub fn getProvider(self: *ProviderRegistry, name: []const u8) ?Provider {
        return self.providers.get(name);
    }

    pub fn listProviders(self: *ProviderRegistry) ![][]const u8 {
        const names = try self.allocator.alloc([]const u8, self.providers.count());
        var i: usize = 0;
        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            names[i] = entry.key_ptr.*;
            i += 1;
        }
        return names;
    }

    pub fn listModels(self: *ProviderRegistry, provider_name: []const u8) ![][]const u8 {
        const provider = self.providers.get(provider_name) orelse return error.ProviderNotFound;
        return self.allocator.dupe([]const u8, provider.config.models);
    }

    pub fn printProviders(self: *ProviderRegistry) !void {
        const provider_names = try self.listProviders();
        defer self.allocator.free(provider_names);

        std.debug.print("Available Providers:\n\n", .{});
        for (provider_names, 0..) |name, i| {
            std.debug.print("  {}. {s}\n", .{ i + 1, name });
        }
    }

    pub fn printModels(self: *ProviderRegistry, provider_name: []const u8) !void {
        const models = try self.listModels(provider_name);
        defer self.allocator.free(models);

        std.debug.print("Available Models for {s}:\n\n", .{provider_name});
        for (models, 0..) |model, i| {
            std.debug.print("  {}. {s}\n", .{ i + 1, model });
        }
    }
};
