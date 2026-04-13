const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const toml = @import("toml");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Provider definition loaded from config
pub const ProviderDef = struct {
    name: []const u8,
    base_url: []const u8,
    description: []const u8,
    models: []const []const u8,
    is_local: bool,
    keep_prefix: bool,
    api_format: []const u8 = "openai",

    pub fn deinit(self: *ProviderDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.base_url);
        allocator.free(self.description);
        allocator.free(self.api_format);
        for (self.models) |m| allocator.free(m);
        allocator.free(self.models);
    }
};

/// Get the path to providers.toml (~/.crushcode/providers.toml)
pub fn getProvidersPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &.{ home, ".crushcode", "providers.toml" });
}

/// Create the default providers.toml with all 20 provider definitions
pub fn createDefaultProvidersFile() !void {
    const allocator = std.heap.page_allocator;
    const path = try getProvidersPath(allocator);
    defer allocator.free(path);

    // Don't overwrite if it already exists
    std.fs.cwd().access(path, .{}) catch {
        // File doesn't exist — create it
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        std.fs.cwd().makePath(dir) catch {};

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const content = default_providers_content;
        try file.writeAll(content);
        out("Created default providers config: {s}\n", .{path});
        return;
    };
    // File exists — skip
}

const default_providers_content =
    \\# Crushcode Provider Definitions
    \\# Edit this file to add/modify providers.
    \\# Run `crushcode connect` to set up API keys.
    \\#
    \\# Schema per provider:
    \\#   base_url    — API endpoint
    \\#   description — Human-readable name
    \\#   models      — List of available model IDs
    \\#   api_format  — openai, anthropic, google, or ollama
    \\#   is_local    — true for local servers (no API key needed)
    \\#   keep_prefix — true if model IDs keep provider/ prefix in API calls
    \\
    \\[providers.openai]
    \\base_url = "https://api.openai.com/v1"
    \\description = "GPT-4, GPT-4o, GPT-3.5 models"
    \\api_format = "openai"
    \\models = ["gpt-4o", "gpt-4-turbo", "gpt-4", "gpt-3.5-turbo"]
    \\
    \\[providers.anthropic]
    \\base_url = "https://api.anthropic.com/v1"
    \\description = "Claude 3.5 Sonnet, Claude 3 Opus"
    \\api_format = "anthropic"
    \\models = ["claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-3-sonnet-20240229"]
    \\
    \\[providers.gemini]
    \\base_url = "https://generativelanguage.googleapis.com/v1"
    \\description = "Gemini Pro, Gemini Flash"
    \\api_format = "google"
    \\models = ["gemini-2.0-flash-exp", "gemini-1.5-pro", "gemini-1.5-flash"]
    \\
    \\[providers.xai]
    \\base_url = "https://api.x.ai/v1"
    \\description = "Grok models"
    \\api_format = "openai"
    \\models = ["grok-beta", "grok-2-1212"]
    \\
    \\[providers.mistral]
    \\base_url = "https://api.mistral.ai/v1"
    \\description = "Mistral Large, Mistral Small"
    \\api_format = "openai"
    \\models = ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"]
    \\
    \\[providers.groq]
    \\base_url = "https://api.groq.com/openai/v1"
    \\description = "Fast inference with Llama, Mixtral"
    \\api_format = "openai"
    \\models = ["llama-3.3-70b-versatile", "llama-3.3-8b-instant", "mixtral-8x7b-32768"]
    \\
    \\[providers.deepseek]
    \\base_url = "https://api.deepseek.com/v1"
    \\description = "DeepSeek Coder, DeepSeek Chat"
    \\api_format = "openai"
    \\models = ["deepseek-chat", "deepseek-coder"]
    \\
    \\[providers.together]
    \\base_url = "https://api.together.xyz/v1"
    \\description = "Llama, Mistral, Qwen models"
    \\api_format = "openai"
    \\models = ["meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", "mistralai/Mixtral-8x7B-Instruct-v0.1"]
    \\
    \\[providers.azure]
    \\base_url = "https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT"
    \\description = "Azure OpenAI"
    \\api_format = "openai"
    \\models = ["gpt-4o", "gpt-4-turbo", "gpt-35-turbo"]
    \\
    \\[providers.vertexai]
    \\base_url = "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/YOUR_LOCATION/publishers/google/models"
    \\description = "Google Vertex AI"
    \\api_format = "google"
    \\models = ["gemini-2.0-flash-exp", "gemini-1.5-pro-001", "gemini-1.5-flash-001"]
    \\
    \\[providers.bedrock]
    \\base_url = "https://bedrock-runtime.us-east-1.amazonaws.com"
    \\description = "AWS Bedrock"
    \\api_format = "anthropic"
    \\models = ["anthropic.claude-3-5-sonnet-20241022-v2:0", "us.anthropic.claude-3-5-haiku-20241022-v1:0"]
    \\
    \\[providers.ollama]
    \\base_url = "http://localhost:11434/api"
    \\description = "Local models (llama2, mistral, etc.)"
    \\api_format = "ollama"
    \\is_local = true
    \\models = ["gemma4:31b-cloud", "phi3.5:3.8b-mini-instruct-q5_K_M"]
    \\
    \\[providers.lm-studio]
    \\base_url = "http://localhost:1234/v1"
    \\description = "LM Studio local models"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["local-model", "your-model-name"]
    \\
    \\[providers.llama-cpp]
    \\base_url = "http://localhost:8080/v1"
    \\description = "llama.cpp server"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["default", "your-model"]
    \\
    \\[providers.openrouter]
    \\base_url = "https://openrouter.ai/api/v1"
    \\description = "Access to 100+ models"
    \\api_format = "openai"
    \\keep_prefix = true
    \\models = ["google/gemma-4-31b-it:free", "google/gemma-4-26b-a4b-it:free", "openai/gpt-oss-20b:free", "z-ai/glm-4.5-air:free", "anthropic/claude-opus-4.6", "anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5", "anthropic/claude-3-haiku", "deepseek/deepseek-chat", "deepseek/deepseek-v3.2", "deepseek/deepseek-r1", "openai/gpt-5.2", "openai/gpt-4o", "openai/gpt-4o-mini", "google/gemini-2.0-flash-001", "google/gemini-2.0-flash", "meta-llama/llama-3.1-8b-instruct", "z-ai/glm-5.1", "z-ai/glm-4.5-air"]
    \\
    \\[providers.zai]
    \\base_url = "https://api.z.ai/api/coding/paas/v4"
    \\description = "GLM models from Z.AI (Coding Plan)"
    \\api_format = "openai"
    \\models = ["glm-4.5-air", "glm-4.7", "glm-5-turbo", "glm-5", "glm-5.1"]
    \\
    \\[providers.vercel-gateway]
    \\base_url = "https://api.vercel.ai/v1"
    \\description = "Vercel AI Gateway"
    \\api_format = "openai"
    \\models = ["your-provider-model"]
    \\
    \\[providers.opencode-zen]
    \\base_url = "https://opencode.ai/zen/v1"
    \\description = "Tested and verified models"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["opencode/minimax-m2.5-free", "opencode/big-pickle", "opencode/qwen3.6-plus-free", "opencode/nemotron-3-super-free", "opencode/gpt-5.4", "opencode/gpt-5.3-codex", "opencode/gpt-5.2", "opencode/gpt-5.1-codex", "opencode/gpt-5-nano", "opencode/claude-opus-4-6", "opencode/claude-sonnet-4-6", "opencode/claude-haiku-4-5", "opencode/gemini-3.1-pro", "opencode/gemini-3-flash", "opencode/minimax-m2.5", "opencode/glm-5.1", "opencode/glm-5", "opencode/kimi-k2.5"]
    \\
    \\[providers.opencode-go]
    \\base_url = "https://opencode.ai/zen/go/v1"
    \\description = "Low-cost subscription models"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["glm-5.1", "glm-5", "kimi-k2.5", "mimo-v2-pro", "mimo-v2-omni", "minimax-m2.7", "minimax-m2.5"]
;

/// Load provider definitions from ~/.crushcode/providers.toml
/// Returns an ArrayList of ProviderDef (caller owns the memory)
pub fn loadProvidersFromFile(allocator: std.mem.Allocator) !?array_list_compat.ArrayList(ProviderDef) {
    const path = try getProvidersPath(allocator);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var doc = try toml.TomlDocument.parse(allocator, content);
    defer doc.deinit();

    var providers = array_list_compat.ArrayList(ProviderDef).init(allocator);

    // Iterate over all sections looking for "providers.XXX"
    var sec_iter = doc.sections.iterator();
    while (sec_iter.next()) |entry| {
        const section_name = entry.key_ptr.*;
        const section = entry.value_ptr.*;

        // Only process sections that start with "providers."
        if (!std.mem.startsWith(u8, section_name, "providers.")) continue;

        const provider_name = section_name["providers.".len..];

        // Extract base_url
        const base_url = section.getString("base_url") orelse continue;
        const description = section.getString("description") orelse "";

        // Extract models array
        var models_list = array_list_compat.ArrayList([]const u8).init(allocator);
        if (section.get("models")) |models_val| {
            if (models_val == .array) {
                for (models_val.array) |item| {
                    if (item == .string) {
                        const model_copy = try allocator.dupe(u8, item.string);
                        try models_list.append(model_copy);
                    }
                }
            }
        }

        // Extract boolean flags
        const is_local = section.getBool("is_local") orelse false;
        const keep_prefix = section.getBool("keep_prefix") orelse false;
        const api_format = section.getString("api_format") orelse "openai";

        const name_copy = try allocator.dupe(u8, provider_name);
        const url_copy = try allocator.dupe(u8, base_url);
        const desc_copy = try allocator.dupe(u8, description);
        const api_format_copy = try allocator.dupe(u8, api_format);
        const models = try models_list.toOwnedSlice();

        try providers.append(.{
            .name = name_copy,
            .base_url = url_copy,
            .description = desc_copy,
            .models = models,
            .is_local = is_local,
            .keep_prefix = keep_prefix,
            .api_format = api_format_copy,
        });
    }

    if (providers.items.len == 0) return null;
    return providers;
}

/// Check if providers.toml exists
pub fn providersFileExists() bool {
    const allocator = std.heap.page_allocator;
    const path = getProvidersPath(allocator) catch return false;
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
