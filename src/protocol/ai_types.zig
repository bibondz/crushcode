/// Chat message in the AI conversation
pub const ChatMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallInfo = null,
};

pub const ToolCallInfo = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Parsed tool call from AI response
pub const ParsedToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []ChatMessage,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    stream: ?bool = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []ChatChoice,
    usage: ?Usage = null,
    provider: ?[]const u8 = null,
    cost: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,
};

pub const ChatChoice = struct {
    index: u32,
    message: ChatMessage,
    finish_reason: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Extended usage data for tracking (Phase 15 integration)
pub const ExtendedUsage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    estimated_cost_usd: f64 = 0.0,
};

/// Callback type for streaming tokens
pub const StreamCallback = *const fn (token: []const u8, done: bool) void;
