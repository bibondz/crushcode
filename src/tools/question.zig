/// Question tool — lets the AI agent ask the user a question with predefined options.
///
/// In non-interactive/TUI mode, returns the first option as default.
/// In interactive mode, reads user selection from stdin.
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const core = @import("core_api");

const Allocator = std.mem.Allocator;

pub const QuestionOption = struct {
    label: []const u8,
    description: []const u8,
};

pub const Question = struct {
    question: []const u8,
    header: []const u8,
    options: []QuestionOption,
    multiple: bool = false,
};

pub const QuestionResult = struct {
    answers: []const []const u8,
    custom_answer: ?[]const u8 = null,
};

/// Extract a string field value from a JSON fragment.
fn extractJsonStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(full_needle);

    const idx = std.mem.indexOf(u8, json, full_needle) orelse return null;
    const rest = json[idx + full_needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\n' or rest[i] == '\r' or rest[i] == ':')) {
        i += 1;
    }
    if (i >= rest.len) return null;

    // Expect opening quote
    if (rest[i] != '"') return null;
    i += 1;

    // Find closing quote (handle escaped quotes)
    const value_start = i;
    while (i < rest.len) {
        if (rest[i] == '"' and (i == 0 or rest[i - 1] != '\\')) {
            break;
        }
        i += 1;
    }
    if (i >= rest.len) return null;

    return rest[value_start..i];
}

/// Extract a boolean field value from a JSON fragment.
fn extractJsonBoolField(json: []const u8, field_name: []const u8) bool {
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return false;
    defer std.heap.page_allocator.free(full_needle);

    const idx = std.mem.indexOf(u8, json, full_needle) orelse return false;
    const rest = json[idx + full_needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\n' or rest[i] == '\r' or rest[i] == ':')) {
        i += 1;
    }
    if (i >= rest.len) return false;

    if (rest.len - i >= 4 and std.mem.eql(u8, rest[i..][0..4], "true")) return true;
    return false;
}

/// Check if stdin is connected to a terminal (interactive mode).
fn isInteractive() bool {
    const stdin = file_compat.File.stdin();
    const stat = std.posix.fstat(stdin.handle) catch return false;
    // Check if it's a character device (terminal)
    return std.posix.S.ISCHR(@intCast(stat.mode));
}

/// Execute the Question tool.
pub fn executeQuestionTool(allocator: Allocator, parsed: core.ParsedToolCall) anyerror!struct { display: []const u8, result: []const u8 } {
    const args = parsed.arguments;

    // Find the "questions" array
    const questions_key = "\"questions\"";
    const questions_pos = std.mem.indexOf(u8, args, questions_key) orelse
        return error.InvalidJson;

    const after_key = args[questions_pos + questions_key.len ..];

    // Find opening [
    var bracket_pos: usize = 0;
    while (bracket_pos < after_key.len and after_key[bracket_pos] != '[') bracket_pos += 1;
    if (bracket_pos >= after_key.len) return error.InvalidJson;

    const array_content = after_key[bracket_pos + 1 ..];

    // Parse each { ... } question block — we process only the first question
    // (multi-question support is future work)
    var i: usize = 0;
    while (i < array_content.len) {
        // Find next {
        while (i < array_content.len and array_content[i] != '{') {
            if (array_content[i] == ']') break;
            i += 1;
        }
        if (i >= array_content.len or array_content[i] == ']') break;

        const block_start = i;
        var depth: u32 = 1;
        i += 1;
        while (i < array_content.len and depth > 0) {
            if (array_content[i] == '{') depth += 1;
            if (array_content[i] == '}') depth -= 1;
            if (array_content[i] == '"') {
                i += 1;
                while (i < array_content.len and array_content[i] != '"') {
                    if (array_content[i] == '\\' and i + 1 < array_content.len) i += 1;
                    i += 1;
                }
            }
            i += 1;
        }
        const block = array_content[block_start..i];

        // Extract question fields
        const question_text = extractJsonStringField(block, "question") orelse continue;
        _ = extractJsonStringField(block, "header") orelse "Question";
        const multiple = extractJsonBoolField(block, "multiple");

        // Parse options array from the block
        var options = array_list_compat.ArrayList(QuestionOption).init(allocator);
        defer options.deinit();

        const options_key = "\"options\"";
        const options_pos = std.mem.indexOf(u8, block, options_key) orelse continue;
        const after_options = block[options_pos + options_key.len ..];

        // Find opening [
        var opt_bracket: usize = 0;
        while (opt_bracket < after_options.len and after_options[opt_bracket] != '[') opt_bracket += 1;
        if (opt_bracket >= after_options.len) continue;

        const opt_content = after_options[opt_bracket + 1 ..];
        var j: usize = 0;
        while (j < opt_content.len) {
            while (j < opt_content.len and opt_content[j] != '{') {
                if (opt_content[j] == ']') break;
                j += 1;
            }
            if (j >= opt_content.len or opt_content[j] == ']') break;

            const opt_start = j;
            var opt_depth: u32 = 1;
            j += 1;
            while (j < opt_content.len and opt_depth > 0) {
                if (opt_content[j] == '{') opt_depth += 1;
                if (opt_content[j] == '}') opt_depth -= 1;
                if (opt_content[j] == '"') {
                    j += 1;
                    while (j < opt_content.len and opt_content[j] != '"') {
                        if (opt_content[j] == '\\' and j + 1 < opt_content.len) j += 1;
                        j += 1;
                    }
                }
                j += 1;
            }
            const opt_block = opt_content[opt_start..j];

            const label = extractJsonStringField(opt_block, "label") orelse continue;
            const description = extractJsonStringField(opt_block, "description") orelse "";

            try options.append(.{
                .label = label,
                .description = description,
            });
        }

        if (options.items.len == 0) continue;

        // Build display for the question
        var display_buf = array_list_compat.ArrayList(u8).init(allocator);
        defer display_buf.deinit();
        const display_writer = display_buf.writer();

        try display_writer.print("\xe2\x9d\x93 {s}\n", .{question_text});
        for (options.items, 1..) |opt, idx| {
            try display_writer.print("{d}. {s} \xe2\x80\x94 {s}\n", .{ idx, opt.label, opt.description });
        }

        // Determine answer
        const answer_label: []const u8 = blk: {
            // In non-interactive mode, return first option as default
            if (!isInteractive()) {
                break :blk options.items[0].label;
            }

            // Interactive mode: prompt user
            const stdout = file_compat.File.stdout().writer();

            stdout.print("\n{s}", .{display_buf.items}) catch {};
            if (multiple) {
                stdout.print("\xe2\x86\x92 Enter choices (comma-separated numbers) or type custom answer: ", .{}) catch {};
            } else {
                stdout.print("\xe2\x86\x92 Enter choice (1-{d}) or type custom answer: ", .{options.items.len}) catch {};
            }

            var input_buf: [256]u8 = undefined;
            const stdin = file_compat.File.stdin().reader();
            const input = stdin.readUntilDelimiterOrEof(&input_buf, '\n') catch "" orelse "";

            if (input.len == 0) {
                break :blk options.items[0].label;
            }

            // Try to parse as number
            const choice_num = std.fmt.parseInt(u32, std.mem.trim(u8, input, " \t\r"), 10) catch 0;
            if (choice_num >= 1 and choice_num <= options.items.len) {
                break :blk options.items[choice_num - 1].label;
            }

            // Treat as custom text answer
            break :blk std.fmt.allocPrint(allocator, "{s}", .{std.mem.trim(u8, input, " \t\r")}) catch options.items[0].label;
        };

        // Build result JSON
        var result_buf = array_list_compat.ArrayList(u8).init(allocator);
        defer result_buf.deinit();
        const result_writer = result_buf.writer();

        try result_writer.print("{{\"answers\": [\"{s}\"]", .{answer_label});
        if (!isInteractive()) {
            try result_writer.writeAll(", \"note\": \"Non-interactive mode — returned first option as default\"");
        }
        try result_writer.writeAll("}");

        const display_text = try std.fmt.allocPrint(allocator, "\xf0\x9f\x91\x8b question \xe2\x86\x92 \"{s}\" selected\n", .{answer_label});

        return .{
            .display = display_text,
            .result = try allocator.dupe(u8, result_buf.items),
        };
    }

    return .{
        .display = try allocator.dupe(u8, "\xf0\x9f\x91\x8b question \xe2\x86\x92 no valid question provided\n"),
        .result = try allocator.dupe(u8, "No valid question provided in arguments"),
    };
}
