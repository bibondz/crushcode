const std = @import("std");

/// Result of a self-heal attempt — corrected tool call or alternative approach
pub const SelfHealResult = struct {
    corrected_tool_name: ?[]const u8,
    corrected_arguments: ?[]const u8,
    alternative_approach: ?[]const u8,
    should_retry: bool,
    allocator: std.mem.Allocator,

    /// Create a SelfHealResult indicating no healing is possible
    pub fn none(allocator: std.mem.Allocator) SelfHealResult {
        return SelfHealResult{
            .corrected_tool_name = null,
            .corrected_arguments = null,
            .alternative_approach = null,
            .should_retry = false,
            .allocator = allocator,
        };
    }

    /// Clean up allocated strings
    pub fn deinit(self: *SelfHealResult) void {
        if (self.corrected_tool_name) |name| {
            self.allocator.free(name);
        }
        if (self.corrected_arguments) |args| {
            self.allocator.free(args);
        }
        if (self.alternative_approach) |approach| {
            self.allocator.free(approach);
        }
    }
};

/// Configuration for self-healing behavior
pub const SelfHealConfig = struct {
    max_heal_attempts: u32 = 1,
    enable_repetition_detection: bool = true,
    repetition_window: u32 = 3,
};

/// Build the self-heal prompt that asks the LLM to correct a failed tool call.
/// Returns an allocated prompt string that the caller must free.
pub fn buildSelfHealPrompt(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    tool_arguments: []const u8,
    error_message: []const u8,
) ![]const u8 {
    const prompt = try std.fmt.allocPrint(allocator,
        \\The tool call "{s}" failed with error: {s}
        \\Tool arguments were: {s}
        \\Generate a corrected tool call or explain why the task cannot be completed.
        \\Respond with JSON: {{"tool_name":"...","arguments":"..."}} or {{"alternative":"explanation"}}
    , .{ tool_name, error_message, tool_arguments });
    return prompt;
}

/// JSON structure for parsing the self-heal response with corrected tool call
const HealResponseCorrected = struct {
    tool_name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    alternative: ?[]const u8 = null,
};

/// Parse the LLM's self-heal response into a structured result.
/// Searches for a JSON object in the response text, then extracts
/// corrected tool_name/arguments or an alternative approach.
pub fn parseSelfHealResponse(
    allocator: std.mem.Allocator,
    llm_response: []const u8,
) !SelfHealResult {
    // Find the JSON object in the response (search for first '{')
    const json_start = std.mem.indexOfScalar(u8, llm_response, '{') orelse {
        // No JSON found — treat entire response as alternative approach
        const approach = try allocator.dupe(u8, llm_response);
        return SelfHealResult{
            .corrected_tool_name = null,
            .corrected_arguments = null,
            .alternative_approach = approach,
            .should_retry = false,
            .allocator = allocator,
        };
    };

    // Find matching closing brace
    const json_end = findMatchingBrace(llm_response, json_start) orelse {
        // Malformed JSON — treat as alternative
        const approach = try allocator.dupe(u8, llm_response);
        return SelfHealResult{
            .corrected_tool_name = null,
            .corrected_arguments = null,
            .alternative_approach = approach,
            .should_retry = false,
            .allocator = allocator,
        };
    };

    const json_slice = llm_response[json_start .. json_end + 1];

    // Parse the JSON
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(HealResponseCorrected, arena_alloc, json_slice, .{
        .ignore_unknown_fields = true,
    }) catch {
        // JSON parse failed — treat response as alternative
        const approach = try allocator.dupe(u8, llm_response);
        return SelfHealResult{
            .corrected_tool_name = null,
            .corrected_arguments = null,
            .alternative_approach = approach,
            .should_retry = false,
            .allocator = allocator,
        };
    };

    // Check if we have a corrected tool call
    if (parsed.tool_name) |name| {
        if (name.len > 0) {
            const tool_name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(tool_name_copy);

            const args_copy = if (parsed.arguments) |args|
                try allocator.dupe(u8, args)
            else
                try allocator.dupe(u8, "");

            return SelfHealResult{
                .corrected_tool_name = tool_name_copy,
                .corrected_arguments = args_copy,
                .alternative_approach = null,
                .should_retry = true,
                .allocator = allocator,
            };
        }
    }

    // Check for alternative approach
    if (parsed.alternative) |alt| {
        if (alt.len > 0) {
            const approach = try allocator.dupe(u8, alt);
            return SelfHealResult{
                .corrected_tool_name = null,
                .corrected_arguments = null,
                .alternative_approach = approach,
                .should_retry = false,
                .allocator = allocator,
            };
        }
    }

    // Neither tool_name nor alternative found
    return SelfHealResult.none(allocator);
}

/// Find the closing brace that matches the opening brace at `start`.
/// Handles nested braces.
fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;

    var depth: usize = 0;
    var in_string: bool = false;
    var i: usize = start;

    while (i < text.len) : (i += 1) {
        const ch = text[i];

        if (in_string) {
            if (ch == '\\' and i + 1 < text.len) {
                // Skip escaped character
                i += 1;
                continue;
            }
            if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Detect if the agent is looping on the same failed tool call.
/// Returns true if the last `window` tool names are identical AND
/// the last `window` error messages are similar (first 50 chars match).
pub fn detectRepetition(
    allocator: std.mem.Allocator,
    recent_tool_names: []const []const u8,
    recent_error_messages: []const []const u8,
    window: u32,
) bool {
    _ = allocator;

    const w: usize = @intCast(window);

    // Need at least `window` entries to detect repetition
    if (recent_tool_names.len < w or recent_error_messages.len < w) {
        return false;
    }

    // Check that the last `window` tool names are all identical
    const first_name = recent_tool_names[recent_tool_names.len - w];
    for (recent_tool_names[recent_tool_names.len - w ..]) |name| {
        if (!std.mem.eql(u8, first_name, name)) {
            return false;
        }
    }

    // Check that the last `window` error messages are similar (first 50 chars match)
    const first_error = recent_error_messages[recent_error_messages.len - w];
    const prefix_len = @min(first_error.len, 50);
    const first_prefix = first_error[0..prefix_len];

    for (recent_error_messages[recent_error_messages.len - w ..]) |msg| {
        const msg_prefix_len = @min(msg.len, 50);
        if (msg_prefix_len != prefix_len) {
            return false;
        }
        const msg_prefix = msg[0..msg_prefix_len];
        if (!std.mem.eql(u8, first_prefix, msg_prefix)) {
            return false;
        }
    }

    return true;
}
