const std = @import("std");

/// Token usage data extracted from streaming responses
pub const TokenUsage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,

    pub fn totalTokens(self: TokenUsage) u32 {
        return self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens;
    }

    pub fn add(self: TokenUsage, other: TokenUsage) TokenUsage {
        return TokenUsage{
            .input_tokens = self.input_tokens + other.input_tokens,
            .output_tokens = self.output_tokens + other.output_tokens,
            .cache_read_tokens = self.cache_read_tokens + other.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens + other.cache_write_tokens,
        };
    }
};

/// Tool call information from streaming responses
pub const ToolCallStart = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    /// Index in the tool_calls array (for matching deltas)
    index: u32 = 0,
};

/// Tool call result after execution
pub const ToolCallResult = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    output: []const u8 = "",
};

/// Stream completion info
pub const StreamDone = struct {
    finish_reason: []const u8 = "stop",
    usage: ?TokenUsage = null,
};

/// Stream error information
pub const StreamError = struct {
    code: u32 = 0,
    message: []const u8 = "unknown error",
};

/// Individual streaming event emitted during response processing
pub const StreamEventType = enum {
    token,
    tool_call,
    tool_result,
    thinking,
    done,
    stream_error,
};

pub const StreamEvent = struct {
    event_type: StreamEventType,

    /// Token content (when event_type == .token)
    token: []const u8 = "",
    /// Tool call start info (when event_type == .tool_call)
    tool_call: ToolCallStart = .{},
    /// Tool result info (when event_type == .tool_result)
    tool_result: ToolCallResult = .{},
    /// Thinking content (when event_type == .thinking)
    thinking: []const u8 = "",
    /// Stream done info (when event_type == .done)
    done: StreamDone = .{},
    /// Stream error info (when event_type == .stream_error)
    stream_error: StreamError = .{},

    pub fn tokenEvent(content: []const u8) StreamEvent {
        return StreamEvent{ .event_type = .token, .token = content };
    }
    pub fn thinkingEvent(content: []const u8) StreamEvent {
        return StreamEvent{ .event_type = .thinking, .thinking = content };
    }
    pub fn doneEvent(done: StreamDone) StreamEvent {
        return StreamEvent{ .event_type = .done, .done = done };
    }
    pub fn errorEvent(err: StreamError) StreamEvent {
        return StreamEvent{ .event_type = .stream_error, .stream_error = err };
    }
    pub fn toolCallEvent(tc: ToolCallStart) StreamEvent {
        return StreamEvent{ .event_type = .tool_call, .tool_call = tc };
    }
    pub fn toolResultEvent(tr: ToolCallResult) StreamEvent {
        return StreamEvent{ .event_type = .tool_result, .tool_result = tr };
    }
};

/// Provider streaming format detection
pub const StreamFormat = enum {
    ndjson, // Ollama, OpenCode-style
    sse, // OpenAI, Anthropic, OpenRouter
    jsonrpc, // Codex-style providers
};

/// Options for controlling streaming behavior
pub const StreamOptions = struct {
    /// Callback invoked for each stream event
    on_event: ?*const fn (StreamEvent) void = null,
    /// Internal buffer size for reading HTTP chunks
    buffer_size: usize = 4096,
    /// Whether to display tokens in terminal
    display_tokens: bool = true,
    /// Timeout in milliseconds for stream inactivity
    timeout_ms: u64 = 300_000,
    /// Whether to include thinking tokens in output
    show_thinking: bool = false,
};

/// Detect streaming format based on provider name
pub fn detectStreamFormat(provider_name: []const u8) StreamFormat {
    if (std.mem.eql(u8, provider_name, "ollama")) {
        return .ndjson;
    }
    if (std.mem.eql(u8, provider_name, "lm_studio")) {
        return .ndjson;
    }
    if (std.mem.eql(u8, provider_name, "llama_cpp")) {
        return .ndjson;
    }
    // Default to SSE for OpenAI-compatible providers
    return .sse;
}
