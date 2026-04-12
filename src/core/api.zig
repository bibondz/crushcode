const std = @import("std");
const ai_types = @import("ai_types");
const tool_types = @import("tool_types");

// Re-export AI client types
pub const client = @import("client");
pub const AIClient = client.AIClient;
pub const ChatMessage = ai_types.ChatMessage;
pub const ChatResponse = ai_types.ChatResponse;
pub const ChatRequest = ai_types.ChatRequest;
pub const ToolSchema = tool_types.ToolSchema;
pub const ParsedToolCall = ai_types.ParsedToolCall;
pub const Usage = ai_types.Usage;
pub const StreamCallback = ai_types.StreamCallback;

// Re-export streaming types
pub const streaming_types = @import("streaming_types");
pub const StreamEvent = streaming_types.StreamEvent;
pub const TokenUsage = streaming_types.TokenUsage;
pub const StreamOptions = streaming_types.StreamOptions;

// Re-export streaming session
pub const streaming = @import("streaming");
pub const StreamingSession = streaming.StreamingSession;

// Re-export streaming buffer
pub const buffer = @import("streaming_buffer");
pub const ResponseBuffer = buffer.ResponseBuffer;

// Re-export streaming display
pub const display = @import("streaming_display");
pub const StreamDisplay = display.StreamDisplay;

comptime {
    _ = std;
}
