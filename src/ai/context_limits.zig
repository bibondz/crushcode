// src/ai/context_limits.zig
// Model-aware context window size mapping.
// Maps provider + model pairs to actual context window sizes so that
// compaction and context-percent calculations are accurate per model.

const std = @import("std");

/// Default context window size when provider/model is unknown.
pub const default_context_window: u64 = 128_000;

/// Returns the context window size (in tokens) for the given provider + model.
/// Model name matching is prefix-based — e.g., "claude-3.5" matches
/// "claude-3.5-sonnet-20241022". Falls back to 128K for unknown combinations.
pub fn getContextWindow(provider_name: []const u8, model_name: []const u8) u64 {
    // --- Anthropic ---
    if (std.mem.eql(u8, provider_name, "anthropic") or
        std.mem.eql(u8, provider_name, "bedrock"))
    {
        // Strip "anthropic." prefix used by Bedrock model names
        const stripped_model: []const u8 = if (std.mem.startsWith(u8, model_name, "anthropic."))
            model_name["anthropic.".len..]
        else if (std.mem.startsWith(u8, model_name, "us.anthropic."))
            model_name["us.anthropic.".len..]
        else
            model_name;

        // Claude 4.x models
        if (std.mem.startsWith(u8, stripped_model, "claude-sonnet-4") or
            std.mem.startsWith(u8, stripped_model, "claude-opus-4") or
            std.mem.startsWith(u8, stripped_model, "claude-haiku-4"))
        {
            return 200_000;
        }
        // Claude 3.x models
        if (std.mem.startsWith(u8, stripped_model, "claude-3.5") or
            std.mem.startsWith(u8, stripped_model, "claude-3-5") or
            std.mem.startsWith(u8, stripped_model, "claude-3-opus") or
            std.mem.startsWith(u8, stripped_model, "claude-3-haiku") or
            std.mem.startsWith(u8, stripped_model, "claude-3-sonnet"))
        {
            return 200_000;
        }
        // Generic claude — assume 200K for unknown claude variants
        if (std.mem.startsWith(u8, stripped_model, "claude")) {
            return 200_000;
        }
        return default_context_window;
    }

    // --- OpenAI ---
    if (std.mem.eql(u8, provider_name, "openai")) {
        if (std.mem.startsWith(u8, model_name, "o1") or
            std.mem.startsWith(u8, model_name, "o3"))
        {
            return 200_000;
        }
        if (std.mem.startsWith(u8, model_name, "gpt-4o") or
            std.mem.startsWith(u8, model_name, "gpt-4-turbo"))
        {
            return 128_000;
        }
        if (std.mem.startsWith(u8, model_name, "gpt-4")) {
            return 128_000;
        }
        if (std.mem.startsWith(u8, model_name, "gpt-3.5")) {
            return 16_385;
        }
        return default_context_window;
    }

    // --- Google / Gemini ---
    if (std.mem.eql(u8, provider_name, "gemini") or
        std.mem.eql(u8, provider_name, "google") or
        std.mem.eql(u8, provider_name, "vertexai"))
    {
        if (std.mem.startsWith(u8, model_name, "gemini-2.5") or
            std.mem.startsWith(u8, model_name, "gemini-2.0") or
            std.mem.startsWith(u8, model_name, "gemini-1.5"))
        {
            return 1_000_000;
        }
        if (std.mem.startsWith(u8, model_name, "gemini")) {
            return 1_000_000;
        }
        return default_context_window;
    }

    // --- xAI ---
    if (std.mem.eql(u8, provider_name, "xai")) {
        return 131_072;
    }

    // --- DeepSeek ---
    if (std.mem.eql(u8, provider_name, "deepseek")) {
        return 128_000;
    }

    // --- Mistral ---
    if (std.mem.eql(u8, provider_name, "mistral")) {
        if (std.mem.startsWith(u8, model_name, "mistral-large")) {
            return 128_000;
        }
        if (std.mem.startsWith(u8, model_name, "mistral-medium")) {
            return 32_000;
        }
        return 32_000;
    }

    // --- Groq ---
    if (std.mem.eql(u8, provider_name, "groq")) {
        return 32_000;
    }

    // --- Ollama / LM Studio / llama.cpp (local models) ---
    if (std.mem.eql(u8, provider_name, "ollama") or
        std.mem.eql(u8, provider_name, "lm-studio") or
        std.mem.eql(u8, provider_name, "llama-cpp"))
    {
        // Conservative default — actual limit depends on the model loaded.
        // Users with large-context models can override via config.
        return 32_000;
    }

    // --- OpenRouter (strip provider prefix, then re-dispatch) ---
    if (std.mem.eql(u8, provider_name, "openrouter")) {
        if (std.mem.indexOfScalar(u8, model_name, '/')) |slash_idx| {
            const routed_provider = model_name[0..slash_idx];
            const routed_model = model_name[slash_idx + 1 ..];
            // Recursively resolve with the routed provider
            return getContextWindow(routed_provider, routed_model);
        }
        return default_context_window;
    }

    // --- Z.ai ---
    if (std.mem.eql(u8, provider_name, "zai")) {
        return 128_000;
    }

    // --- MiniMax ---
    if (std.mem.eql(u8, provider_name, "minimax")) {
        return 128_000;
    }

    // --- OpenCode Zen / OpenCode Go (strip prefix, then re-dispatch) ---
    if (std.mem.eql(u8, provider_name, "opencode-zen") or
        std.mem.eql(u8, provider_name, "opencode-go"))
    {
        if (std.mem.indexOfScalar(u8, model_name, '/')) |slash_idx| {
            const routed_provider = model_name[0..slash_idx];
            const routed_model = model_name[slash_idx + 1 ..];
            return getContextWindow(routed_provider, routed_model);
        }
        return default_context_window;
    }

    // --- NVIDIA NIM ---
    if (std.mem.eql(u8, provider_name, "nvidia")) {
        return 128_000;
    }

    return default_context_window;
}

// ========== UNIT TESTS ==========

const testing = std.testing;

test "getContextWindow returns 200K for anthropic claude-3.5-sonnet" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("anthropic", "claude-3-5-sonnet-20241022"));
}

test "getContextWindow returns 200K for anthropic claude-3-opus" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("anthropic", "claude-3-opus-20240229"));
}

test "getContextWindow returns 200K for anthropic claude-3-haiku" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("anthropic", "claude-3-haiku-20240307"));
}

test "getContextWindow returns 200K for anthropic claude-sonnet-4" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("anthropic", "claude-sonnet-4-20250514"));
}

test "getContextWindow returns 200K for anthropic generic claude" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("anthropic", "claude-unknown-future"));
}

test "getContextWindow returns 128K for openai gpt-4o" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("openai", "gpt-4o"));
}

test "getContextWindow returns 128K for openai gpt-4-turbo" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("openai", "gpt-4-turbo"));
}

test "getContextWindow returns 200K for openai o1" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("openai", "o1-preview"));
}

test "getContextWindow returns 200K for openai o3" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("openai", "o3-mini"));
}

test "getContextWindow returns 16K for openai gpt-3.5-turbo" {
    try testing.expectEqual(@as(u64, 16_385), getContextWindow("openai", "gpt-3.5-turbo"));
}

test "getContextWindow returns 1M for gemini gemini-2.5-pro" {
    try testing.expectEqual(@as(u64, 1_000_000), getContextWindow("gemini", "gemini-2.5-pro"));
}

test "getContextWindow returns 1M for gemini gemini-2.0-flash" {
    try testing.expectEqual(@as(u64, 1_000_000), getContextWindow("gemini", "gemini-2.0-flash-exp"));
}

test "getContextWindow returns 1M for gemini gemini-1.5-pro" {
    try testing.expectEqual(@as(u64, 1_000_000), getContextWindow("gemini", "gemini-1.5-pro"));
}

test "getContextWindow returns 131072 for xai grok" {
    try testing.expectEqual(@as(u64, 131_072), getContextWindow("xai", "grok-beta"));
}

test "getContextWindow returns 128K for deepseek chat" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("deepseek", "deepseek-chat"));
}

test "getContextWindow returns 128K for deepseek coder" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("deepseek", "deepseek-coder"));
}

test "getContextWindow returns 32K for ollama default" {
    try testing.expectEqual(@as(u64, 32_000), getContextWindow("ollama", "llama3.3:70b-cloud"));
}

test "getContextWindow returns 32K for lm-studio" {
    try testing.expectEqual(@as(u64, 32_000), getContextWindow("lm-studio", "local-model"));
}

test "getContextWindow returns 128K for unknown provider" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("unknown-provider", "some-model"));
}

test "getContextWindow returns 128K for empty provider/model" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("", ""));
}

test "getContextWindow openrouter routes anthropic/claude to 200K" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("openrouter", "anthropic/claude-sonnet-4.6"));
}

test "getContextWindow openrouter routes openai/gpt-4o to 128K" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("openrouter", "openai/gpt-4o"));
}

test "getContextWindow openrouter routes google/gemini to 1M" {
    try testing.expectEqual(@as(u64, 1_000_000), getContextWindow("openrouter", "google/gemini-2.0-flash-001"));
}

test "getContextWindow opencode-zen routes through prefix" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("opencode-zen", "anthropic/claude-sonnet-4-6"));
}

test "getContextWindow bedrock uses anthropic rules" {
    try testing.expectEqual(@as(u64, 200_000), getContextWindow("bedrock", "anthropic.claude-3-5-sonnet-20241022-v2:0"));
}

test "getContextWindow returns 32K for groq" {
    try testing.expectEqual(@as(u64, 32_000), getContextWindow("groq", "llama-3.3-70b-versatile"));
}

test "getContextWindow mistral-large is 128K" {
    try testing.expectEqual(@as(u64, 128_000), getContextWindow("mistral", "mistral-large-latest"));
}

test "getContextWindow mistral-medium is 32K" {
    try testing.expectEqual(@as(u64, 32_000), getContextWindow("mistral", "mistral-medium-latest"));
}
