/// Tool schema for the AI API (OpenAI function calling format)
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON Schema as string
};
