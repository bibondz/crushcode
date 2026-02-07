const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const client_mod = @import("client");

const Config = config_mod.Config;

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        std.debug.print("Crushcode - AI Coding Assistant\n", .{});
        std.debug.print("Usage: crushcode chat <message> [--provider <name>] [--model <name>]\n\n", .{});
        std.debug.print("Available Providers:\n", .{});
        std.debug.print("  openai - GPT models\n", .{});
        std.debug.print("  anthropic - Claude models\n", .{});
        std.debug.print("  gemini - Gemini models\n", .{});
        std.debug.print("  xai - Grok models\n", .{});
        std.debug.print("  mistral - Mistral models\n", .{});
        std.debug.print("  groq - Groq models\n", .{});
        std.debug.print("  deepseek - DeepSeek models\n", .{});
        std.debug.print("  together - Together AI\n", .{});
        std.debug.print("  azure - Azure OpenAI\n", .{});
        std.debug.print("  vertexai - Google Vertex AI\n", .{});
        std.debug.print("  bedrock - AWS Bedrock\n", .{});
        std.debug.print("  ollama - Local LLM\n", .{});
        std.debug.print("  lm-studio - LM Studio\n", .{});
        std.debug.print("  llama-cpp - llama.cpp\n", .{});
        std.debug.print("  openrouter - OpenRouter\n", .{});
        std.debug.print("  zai - Zhipu AI\n", .{});
        std.debug.print("  vercel-gateway - Vercel Gateway\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  crushcode chat \"Hello! Can you help me?\"\n", .{});
        std.debug.print("  crushcode chat --provider openai --model gpt-4o \"Hello\"\n", .{});
        std.debug.print("  crushcode chat --provider anthropic \"Help me code\"\n", .{});
        std.debug.print("  crushcode list --providers\n", .{});
        std.debug.print("  crushcode list --models openai\n", .{});
        return;
    }

    const message = args.remaining[0];
    const provider_name = args.provider orelse config.default_provider;
    const model_name = args.model orelse config.default_model;

    // Initialize registry and get provider
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
        std.debug.print("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // Get API key from config
    const api_key = config.getApiKey(provider_name) orelse "";

    // Use provider config to get base URL (will be used for HTTP client)
    _ = provider.config.base_url;

    if (api_key.len == 0) {
        std.debug.print("Warning: No API key found for provider '{s}'\n", .{provider_name});
        std.debug.print("Add your API key to ~/.crushcode/config.toml\n", .{});
        std.debug.print("Example: {s} = \"your-api-key\"\n\n", .{provider_name});

        // For local providers (ollama, lm_studio, llama_cpp), proceed without API key
        if (!std.mem.eql(u8, provider_name, "ollama") and
            !std.mem.eql(u8, provider_name, "lm_studio") and
            !std.mem.eql(u8, provider_name, "llama_cpp"))
        {
            return error.MissingApiKey;
        }
    }

    // Initialize AI client
    var client = try client_mod.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    std.debug.print("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    // Send chat request
    const response = client.sendChat(message) catch |err| {
        std.debug.print("\nError sending request: {}\n", .{err});
        return err;
    };

    // Display response
    std.debug.print("\n{s}\n\n", .{response.choices[0].message.content});
    std.debug.print("---\n", .{});
    std.debug.print("Provider: {s}\n", .{provider_name});
    std.debug.print("Model: {s}\n", .{model_name});
    std.debug.print("Tokens used: {d} prompt + {d} completion = {d} total\n", .{
        response.usage.prompt_tokens,
        response.usage.completion_tokens,
        response.usage.total_tokens,
    });
}

pub const Args = struct {
    command: []const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    config_file: ?[]const u8,
    remaining: [][]const u8,
};
