const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const http_client = @import("http_client");
const providers_file = @import("providers_file");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

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

pub const ApiFormat = enum {
    openai,
    anthropic,
    google,
    ollama,
};

pub const ProviderConfig = struct {
    base_url: []const u8,
    api_key: []const u8,
    models: []const []const u8,
    is_models_static: bool = false,
    api_format: ApiFormat = .openai,
    is_local: bool = false,
    keep_prefix: bool = false,
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
            .api_format = .openai,
        },
        .anthropic => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-3-sonnet-20240229" },
            .is_models_static = true,
            .api_format = .anthropic,
        },
        .gemini => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://generativelanguage.googleapis.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gemini-2.0-flash-exp", "gemini-1.5-pro", "gemini-1.5-flash" },
            .is_models_static = true,
            .api_format = .google,
        },
        .xai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.x.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "grok-beta", "grok-2-1212" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .mistral => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.mistral.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .groq => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.groq.com/openai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "llama-3.3-70b-versatile", "llama-3.3-8b-instant", "mixtral-8x7b-32768" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .deepseek => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.deepseek.com/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "deepseek-chat", "deepseek-coder" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .together => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.together.xyz/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", "mistralai/Mixtral-8x7B-Instruct-v0.1" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .azure => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gpt-4o", "gpt-4-turbo", "gpt-35-turbo" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .vertexai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/YOUR_LOCATION/publishers/google/models"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gemini-2.0-flash-exp", "gemini-1.5-pro-001", "gemini-1.5-flash-001" },
            .is_models_static = true,
            .api_format = .google,
        },
        .bedrock => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://bedrock-runtime.us-east-1.amazonaws.com"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "anthropic.claude-3-5-sonnet-20241022-v2:0", "us.anthropic.claude-3-5-haiku-20241022-v1:0" },
            .is_models_static = true,
            .api_format = .anthropic,
        },
        .ollama => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:11434/api"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "gemma4:31b-cloud", "phi3.5:3.8b-mini-instruct-q5_K_M", "llama3.3:70b-cloud", "mistral-small:24b-cloud", "qwen3:30b-cloud", "deepseek-r1:cloud", "devstral:24b-cloud" },
            .is_models_static = true,
            .api_format = .ollama,
            .is_local = true,
        },
        .lm_studio => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:1234/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "local-model", "your-model-name" },
            .is_models_static = true,
            .api_format = .openai,
            .is_local = true,
        },
        .llama_cpp => ProviderConfig{
            .base_url = try allocator.dupe(u8, "http://localhost:8080/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "default", "your-model" },
            .is_models_static = true,
            .api_format = .openai,
            .is_local = true,
        },
        .openrouter => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://openrouter.ai/api/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{
                // Free models (2026) - tested
                "google/gemma-4-31b-it:free",
                "google/gemma-4-26b-a4b-it:free",
                "openai/gpt-oss-20b:free",
                "z-ai/glm-4.5-air:free",
                // Anthropic models - tested working via OpenRouter
                "anthropic/claude-opus-4.6",
                "anthropic/claude-sonnet-4.6",
                "anthropic/claude-haiku-4.5",
                "anthropic/claude-3-haiku",
                // DeepSeek models - tested working
                "deepseek/deepseek-chat",
                "deepseek/deepseek-v3.2",
                "deepseek/deepseek-r1",
                // OpenAI models - tested working
                "openai/gpt-5.2",
                "openai/gpt-4o",
                "openai/gpt-4o-mini",
                // Google models - tested working
                "google/gemini-2.0-flash-001",
                "google/gemini-2.0-flash",
                // Meta/Llama models - tested working
                "meta-llama/llama-3.1-8b-instruct",
                // Z.ai models - tested working
                "z-ai/glm-5.1",
                "z-ai/glm-4.5-air",
            },
            .is_models_static = true,
            .api_format = .openai,
            .keep_prefix = true,
        },
        .zai => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.z.ai/api/coding/paas/v4"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{ "glm-4.5-air", "glm-4.7", "glm-5-turbo", "glm-5", "glm-5.1" },
            .is_models_static = true,
            .api_format = .openai,
        },
        .vercel_gateway => ProviderConfig{
            .base_url = try allocator.dupe(u8, "https://api.vercel.ai/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{"your-provider-model"},
            .is_models_static = true,
            .api_format = .openai,
        },
        .opencode_zen => ProviderConfig{
            // OpenCode Zen - models tested by OpenCode team
            // Chat Completions API: https://opencode.ai/docs/zen/#endpoints
            .base_url = try allocator.dupe(u8, "https://opencode.ai/zen/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{
                // Free models (tested working)
                "opencode/minimax-m2.5-free", // MiniMax M2.5 Free
                "opencode/big-pickle", // Stealth free model
                "opencode/qwen3.6-plus-free", // Qwen3.6 Plus Free
                "opencode/nemotron-3-super-free", // Nemotron 3 Super Free
                // Paid models (need balance)
                "opencode/gpt-5.4",
                "opencode/gpt-5.3-codex",
                "opencode/gpt-5.2",
                "opencode/gpt-5.1-codex",
                "opencode/gpt-5-nano", // Free
                "opencode/claude-opus-4-6",
                "opencode/claude-sonnet-4-6",
                "opencode/claude-haiku-4-5",
                "opencode/gemini-3.1-pro",
                "opencode/gemini-3-flash",
                "opencode/minimax-m2.5",
                "opencode/glm-5.1",
                "opencode/glm-5",
                "opencode/kimi-k2.5",
            },
            .is_models_static = true,
            .api_format = .openai,
            .is_local = true,
        },
        .opencode_go => ProviderConfig{
            // OpenCode Go - low cost subscription ($5 first month, $10/month)
            // Models: GLM-5, GLM-5.1, Kimi K2.5, MiMo-V2-Pro, MiMo-V2-Omni, MiniMax M2.7, MiniMax M2.5
            // Endpoint is under /zen/go path
            .base_url = try allocator.dupe(u8, "https://opencode.ai/zen/go/v1"),
            .api_key = try allocator.dupe(u8, ""),
            .models = &[_][]const u8{
                "glm-5.1",
                "glm-5",
                "kimi-k2.5",
                "mimo-v2-pro",
                "mimo-v2-omni",
                "minimax-m2.7",
                "minimax-m2.5",
            },
            .is_models_static = true,
            .api_format = .openai,
            .is_local = true,
        },
    };
}

fn parseApiFormat(api_format: []const u8) ApiFormat {
    if (std.mem.eql(u8, api_format, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, api_format, "google")) return .google;
    if (std.mem.eql(u8, api_format, "ollama")) return .ollama;
    return .openai;
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

    /// Generic fetch models from any provider based on api_format.
    /// Returns a caller-owned slice of model ID strings.
    pub fn fetchModels(self: *ProviderRegistry, provider_name: []const u8, api_key: []const u8) ![]const []const u8 {
        const provider = self.providers.get(provider_name) orelse return error.ProviderNotFound;
        const base_url = provider.config.base_url;
        const fmt = provider.config.api_format;

        switch (fmt) {
            .openai => {
                const url = try std.fmt.allocPrint(self.allocator, "{s}/models", .{base_url});
                defer self.allocator.free(url);

                var headers = array_list_compat.ArrayList(std.http.Header).init(self.allocator);
                defer headers.deinit();
                if (api_key.len > 0) {
                    const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
                    defer self.allocator.free(auth);
                    try headers.append(.{ .name = "Authorization", .value = auth });
                }

                const response = http_client.httpGet(self.allocator, url, headers.items) catch return error.FetchFailed;
                defer self.allocator.free(response.body);
                if (response.status != .ok) return error.FetchFailed;

                return self.parseOpenAIModelsJson(response.body);
            },
            .ollama => {
                // Ollama base_url already contains /api (e.g. http://localhost:11434/api)
                // but we need the /api/tags endpoint for listing
                var url: []const u8 = undefined;
                if (std.mem.endsWith(u8, base_url, "/api")) {
                    url = try std.fmt.allocPrint(self.allocator, "{s}/tags", .{base_url});
                } else {
                    url = try std.fmt.allocPrint(self.allocator, "{s}/api/tags", .{base_url});
                }
                defer self.allocator.free(url);

                const response = http_client.httpGet(self.allocator, url, null) catch return error.FetchFailed;
                defer self.allocator.free(response.body);
                if (response.status != .ok) return error.FetchFailed;

                return self.parseOllamaModelsJson(response.body);
            },
            .anthropic => {
                const url = try std.fmt.allocPrint(self.allocator, "{s}/models", .{base_url});
                defer self.allocator.free(url);

                var headers = array_list_compat.ArrayList(std.http.Header).init(self.allocator);
                defer headers.deinit();
                if (api_key.len > 0) {
                    const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
                    defer self.allocator.free(auth);
                    try headers.append(.{ .name = "x-api-key", .value = auth });
                    try headers.append(.{ .name = "anthropic-version", .value = "2023-06-01" });
                }

                const response = http_client.httpGet(self.allocator, url, headers.items) catch return error.FetchFailed;
                defer self.allocator.free(response.body);
                if (response.status != .ok) return error.FetchFailed;

                return self.parseOpenAIModelsJson(response.body);
            },
            .google => {
                // Gemini uses query param auth: ?key=API_KEY
                const url = if (api_key.len > 0)
                    try std.fmt.allocPrint(self.allocator, "https://generativelanguage.googleapis.com/v1beta/models?key={s}", .{api_key})
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/models", .{base_url});
                defer self.allocator.free(url);

                const response = http_client.httpGet(self.allocator, url, null) catch return error.FetchFailed;
                defer self.allocator.free(response.body);
                if (response.status != .ok) return error.FetchFailed;

                return self.parseGeminiModelsJson(response.body);
            },
        }
    }

    /// Parse OpenAI-compatible /v1/models response: {"data":[{"id":"..."},...]}
    fn parseOpenAIModelsJson(self: *ProviderRegistry, body: []const u8) ![]const []const u8 {
        var model_list = array_list_compat.ArrayList([]const u8).init(self.allocator);
        var search_idx: usize = 0;
        while (search_idx < body.len) {
            if (std.mem.indexOf(u8, body[search_idx..], "\"id\":\"")) |idx| {
                const start = search_idx + idx + 5;
                if (start < body.len) {
                    if (std.mem.indexOf(u8, body[start..], "\"")) |end_idx| {
                        const model_id = body[start..(start + end_idx)];
                        if (model_id.len > 0 and model_id.len < 200) {
                            try model_list.append(try self.allocator.dupe(u8, model_id));
                        }
                        search_idx = start + end_idx;
                        continue;
                    }
                }
            }
            search_idx += 1;
        }
        return model_list.toOwnedSlice();
    }

    /// Parse Ollama /api/tags response: {"models":[{"name":"..."},...]}
    fn parseOllamaModelsJson(self: *ProviderRegistry, body: []const u8) ![]const []const u8 {
        var model_list = array_list_compat.ArrayList([]const u8).init(self.allocator);
        var search_idx: usize = 0;
        while (search_idx < body.len) {
            if (std.mem.indexOf(u8, body[search_idx..], "\"name\":\"")) |idx| {
                const start = search_idx + idx + 8;
                if (start < body.len) {
                    if (std.mem.indexOf(u8, body[start..], "\"")) |end_idx| {
                        const model_id = body[start..(start + end_idx)];
                        if (model_id.len > 0 and model_id.len < 200) {
                            try model_list.append(try self.allocator.dupe(u8, model_id));
                        }
                        search_idx = start + end_idx;
                        continue;
                    }
                }
            }
            search_idx += 1;
        }
        return model_list.toOwnedSlice();
    }

    /// Parse Gemini /v1beta/models response: {"models":[{"name":"models/..."},...]}
    fn parseGeminiModelsJson(self: *ProviderRegistry, body: []const u8) ![]const []const u8 {
        var model_list = array_list_compat.ArrayList([]const u8).init(self.allocator);
        var search_idx: usize = 0;
        while (search_idx < body.len) {
            if (std.mem.indexOf(u8, body[search_idx..], "\"name\":\"")) |idx| {
                const start = search_idx + idx + 8;
                if (start < body.len) {
                    if (std.mem.indexOf(u8, body[start..], "\"")) |end_idx| {
                        const raw = body[start..(start + end_idx)];
                        // Strip "models/" prefix from Gemini model names
                        const model_id = if (std.mem.startsWith(u8, raw, "models/")) raw["models/".len..] else raw;
                        if (model_id.len > 0 and model_id.len < 200) {
                            try model_list.append(try self.allocator.dupe(u8, model_id));
                        }
                        search_idx = start + end_idx;
                        continue;
                    }
                }
            }
            search_idx += 1;
        }
        return model_list.toOwnedSlice();
    }

    /// Fetch available models from OpenCode Zen API
    pub fn fetchOpenCodeZenModels(self: *ProviderRegistry, api_key: []const u8) ![]const []const u8 {
        if (api_key.len == 0) {
            return error.AuthenticationRequired;
        }

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };

        const response = try http_client.httpGet(self.allocator, "https://opencode.ai/zen/v1/models", &headers);
        defer self.allocator.free(response.body);

        const body = response.body;

        if (response.status != .ok) {
            return error.FetchFailed;
        }

        // Parse JSON response to extract model IDs
        var model_list = array_list_compat.ArrayList([]const u8).init(self.allocator);

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

    /// Fetch available models from OpenRouter API (no auth required)
    /// Returns models in format "provider/model-name"
    pub fn fetchOpenRouterModels(self: *ProviderRegistry) ![]const []const u8 {
        // Use curl to fetch models (avoids HTTP client compression issues)
        const argv: [5][]const u8 = .{ "curl", "-s", "-m", "30", "https://openrouter.ai/api/v1/models" };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        _ = try child.spawn();

        var stdout = std.ArrayListUnmanaged(u8){};
        var stderr = std.ArrayListUnmanaged(u8){};
        defer {
            stdout.deinit(self.allocator);
            stderr.deinit(self.allocator);
        }

        try child.collectOutput(self.allocator, &stdout, &stderr, 10 * 1024 * 1024);

        const term = try child.wait();

        if (term.Exited != 0) {
            return error.FetchFailed;
        }

        const body = stdout.items;

        // Parse JSON response - search for "id":" patterns
        var model_list = array_list_compat.ArrayList([]const u8).init(self.allocator);

        var search_idx: usize = 0;
        while (search_idx < body.len) {
            const id_pattern = "\"id\":\"";
            if (std.mem.indexOf(u8, body[search_idx..], id_pattern)) |idx| {
                const start = search_idx + idx + id_pattern.len;
                if (start < body.len) {
                    if (std.mem.indexOf(u8, body[start..], "\"")) |end_idx| {
                        const model_id = body[start..(start + end_idx)];
                        if (model_id.len > 0 and model_id.len < 200 and !std.mem.startsWith(u8, model_id, "__")) {
                            try model_list.append(try std.fmt.allocPrint(self.allocator, "{s}", .{model_id}));
                        }
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
        // Try loading providers from config file first
        if (providers_file.loadProvidersFromFile(self.allocator) catch null) |config_providers| {
            for (config_providers.items) |def| {
                self.registerProviderFromDef(def) catch |err| {
                    out("Warning: Failed to register provider '{s}': {}\n", .{ def.name, err });
                };
            }
            // Free the list container (individual defs are now owned by registry)
            const mutable_ptr = @as(*providers_file.ProviderDef, @ptrFromInt(@intFromPtr(&config_providers)));
            _ = mutable_ptr;
            // Deinit just the array list, not the items (they're moved into registry)
            var providers_list = config_providers;
            providers_list.deinit();
        } else {
            // No config file — use hardcoded defaults
            const all_providers = comptime std.enums.values(ProviderType);
            inline for (all_providers) |provider_type| {
                try self.registerProvider(provider_type);
            }
        }
    }

    /// Register a provider from a config-loaded definition
    fn registerProviderFromDef(self: *ProviderRegistry, def: providers_file.ProviderDef) !void {
        // Allocate models slice for the provider
        const models = try self.allocator.alloc([]const u8, def.models.len);
        for (def.models, 0..) |m, i| {
            models[i] = try self.allocator.dupe(u8, m);
        }

        const name = try self.allocator.dupe(u8, def.name);
        const base_url = try self.allocator.dupe(u8, def.base_url);

        const provider = Provider{
            .name = name,
            .config = .{
                .base_url = base_url,
                .api_key = try self.allocator.dupe(u8, ""),
                .models = models,
                .is_models_static = false,
                .api_format = parseApiFormat(def.api_format),
                .is_local = def.is_local,
                .keep_prefix = def.keep_prefix,
            },
            .allocator = self.allocator,
        };

        try self.providers.put(name, provider);
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

        out("Available Providers:\n\n", .{});
        for (provider_names, 0..) |name, i| {
            out("  {}. {s}\n", .{ i + 1, name });
        }
    }

    pub fn printModels(self: *ProviderRegistry, provider_name: []const u8) !void {
        const models = try self.listModels(provider_name);
        defer self.allocator.free(models);

        out("Available Models for {s}:\n\n", .{provider_name});
        for (models, 0..) |model, i| {
            out("  {d}. {s}\n", .{ i + 1, model });
        }
    }

    /// Print models fetched live from OpenRouter API
    pub fn printOpenRouterModelsLive(self: *ProviderRegistry) !void {
        out("Fetching models from OpenRouter API...\n\n", .{});

        const models = self.fetchOpenRouterModels() catch |err| {
            out("Error fetching models: {}\n", .{err});
            out("Showing cached models instead:\n\n", .{});
            try self.printModels("openrouter");
            return;
        };
        defer self.allocator.free(models);

        if (models.len == 0) {
            out("No models found\n", .{});
            return;
        }

        out("Live Models from OpenRouter ({d} total):\n\n", .{models.len});
        for (models, 0..) |model, i| {
            out("  {d}. {s}\n", .{ i + 1, model });
        }
    }
};
