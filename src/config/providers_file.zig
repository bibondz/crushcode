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
    \\# Run `crushcode connect <provider>` to set up API keys.
    \\#
    \\# Schema per provider:
    \\#   base_url    — API endpoint
    \\#   description — Human-readable name
    \\#   models      — List of available model IDs
    \\#   api_format  — openai, anthropic, google, or ollama
    \\#   is_local    — true for local servers (no API key needed)
    \\#   keep_prefix — true if model IDs keep provider/ prefix in API calls
    \\#
    \\# FREE TIERS (no credit card needed):
    \\#   groq (30 RPM, fast), gemini (100 req/day), cerebras (1M tok/day),
    \\#   sambanova (free), deepseek (5M free tokens), openrouter (50 req/day free models)
    \\
    \\# ── Free Tier Providers ──────────────────────────────────────────────
    \\
    \\[providers.groq]
    \\base_url = "https://api.groq.com/openai/v1"
    \\description = "Fast inference — 30 RPM free tier (console.groq.com)"
    \\api_format = "openai"
    \\models = ["llama-3.3-70b-versatile", "llama-4-scout-17b-16e-instruct", "qwen3-32b", "mixtral-8x7b-32768"]
    \\
    \\[providers.cerebras]
    \\base_url = "https://api.cerebras.ai/v1"
    \\description = "Ultra-fast inference — 1M tokens/day free (cloud.cerebras.ai)"
    \\api_format = "openai"
    \\models = ["llama-3.3-70b", "qwen3-32b", "qwen3-235b-a22b", "gpt-oss-120b"]
    \\
    \\[providers.sambanova]
    \\base_url = "https://api.sambanova.ai/v1"
    \\description = "Free tier — Llama 405B, Qwen 72B (cloud.sambanova.ai)"
    \\api_format = "openai"
    \\models = ["Meta-Llama-3.3-70B-Instruct", "Meta-Llama-3.1-405B-Instruct", "Qwen2.5-72B-Instruct"]
    \\
    \\[providers.deepseek]
    \\base_url = "https://api.deepseek.com/v1"
    \\description = "5M free tokens on signup (platform.deepseek.com)"
    \\api_format = "openai"
    \\models = ["deepseek-chat", "deepseek-reasoner"]
    \\
    \\[providers.openrouter]
    \\base_url = "https://openrouter.ai/api/v1"
    \\description = "50 free req/day on free models (openrouter.ai)"
    \\api_format = "openai"
    \\keep_prefix = true
    \\models = ["google/gemma-4-31b-it:free", "openai/gpt-oss-20b:free", "z-ai/glm-4.5-air:free", "deepseek/deepseek-chat", "openai/gpt-4o-mini", "z-ai/glm-5.1", "meta-llama/llama-3.1-8b-instruct"]
    \\
    \\[providers.xai]
    \\base_url = "https://api.x.ai/v1"
    \\description = "$25 signup credits (console.x.ai)"
    \\api_format = "openai"
    \\models = ["grok-3", "grok-3-fast", "grok-2-1212"]
    \\
    \\# ── Paid / Trial Credit Providers ───────────────────────────────────
    \\
    \\[providers.openai]
    \\base_url = "https://api.openai.com/v1"
    \\description = "GPT-4o, GPT-5 — pay per token"
    \\api_format = "openai"
    \\models = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]
    \\
    \\[providers.anthropic]
    \\base_url = "https://api.anthropic.com/v1"
    \\description = "Claude 4 Opus/Sonnet — pay per token"
    \\api_format = "anthropic"
    \\models = ["claude-opus-4-20250514", "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"]
    \\
    \\[providers.mistral]
    \\base_url = "https://api.mistral.ai/v1"
    \\description = "Mistral models — 1B tokens/month free tier"
    \\api_format = "openai"
    \\models = ["mistral-large-latest", "mistral-small-latest", "codestral-latest"]
    \\
    \\[providers.together]
    \\base_url = "https://api.together.xyz/v1"
    \\description = "100+ models — $5 signup credit"
    \\api_format = "openai"
    \\models = ["meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", "mistralai/Mixtral-8x7B-Instruct-v0.1", "deepseek-ai/DeepSeek-R1"]
    \\
    \\# ── Google ──────────────────────────────────────────────────────────
    \\
    \\[providers.gemini]
    \\base_url = "https://generativelanguage.googleapis.com/v1beta"
    \\description = "Gemini — 100 req/day free (ai.google.dev)"
    \\api_format = "google"
    \\models = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
    \\
    \\[providers.vertexai]
    \\base_url = "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/YOUR_LOCATION/publishers/google/models"
    \\description = "Google Vertex AI — requires GCP project"
    \\api_format = "google"
    \\models = ["gemini-2.0-flash-exp", "gemini-1.5-pro-001", "gemini-1.5-flash-001"]
    \\
    \\# ── Cloud / Enterprise ──────────────────────────────────────────────
    \\
    \\[providers.azure]
    \\base_url = "https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT"
    \\description = "Azure OpenAI"
    \\api_format = "openai"
    \\models = ["gpt-4o", "gpt-4-turbo", "gpt-35-turbo"]
    \\
    \\[providers.bedrock]
    \\base_url = "https://bedrock-runtime.us-east-1.amazonaws.com"
    \\description = "AWS Bedrock"
    \\api_format = "anthropic"
    \\models = ["anthropic.claude-3-5-sonnet-20241022-v2:0", "us.anthropic.claude-3-5-haiku-20241022-v1:0"]
    \\
    \\# ── Local Providers ─────────────────────────────────────────────────
    \\
    \\[providers.ollama]
    \\base_url = "http://localhost:11434/api"
    \\description = "Local models — no API key needed"
    \\api_format = "ollama"
    \\is_local = true
    \\models = ["llama3.1", "mistral", "qwen2.5-coder", "deepseek-coder-v2"]
    \\
    \\[providers.lm-studio]
    \\base_url = "http://localhost:1234/v1"
    \\description = "LM Studio local models"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["local-model"]
    \\
    \\[providers.llama-cpp]
    \\base_url = "http://localhost:8080/v1"
    \\description = "llama.cpp server"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["default"]
    \\
    \\# ── Z.AI (Coding Plan) ─────────────────────────────────────────────
    \\
    \\[providers.zai]
    \\base_url = "https://api.z.ai/api/coding/paas/v4"
    \\description = "GLM Coding Plan — subscription only (z.ai/subscribe)"
    \\api_format = "openai"
    \\models = ["glm-4.5-air", "glm-4.7", "glm-5-turbo", "glm-5", "glm-5.1"]
    \\
    \\# ── Aggregators ────────────────────────────────────────────────────
    \\
    \\[providers.opencode-zen]
    \\base_url = "https://opencode.ai/zen/v1"
    \\description = "OpenCode Zen — multi-provider"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["opencode/big-pickle", "opencode/glm-5.1", "opencode/claude-sonnet-4-6", "opencode/gemini-3-flash"]
    \\
    \\[providers.opencode-go]
    \\base_url = "https://opencode.ai/zen/go/v1"
    \\description = "OpenCode Go — low-cost subscription"
    \\api_format = "openai"
    \\is_local = true
    \\models = ["glm-5.1", "glm-5", "kimi-k2.5", "mimo-v2-pro", "minimax-m2.5"]
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
