const std = @import("std");
const array_list_compat = @import("array_list_compat");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// JSON helpers — lightweight field extraction without full parse
// ---------------------------------------------------------------------------

/// Extract a string field value from a JSON string.
/// Finds `"field":"value"` patterns, handling whitespace after the colon.
fn extractJsonStringField(json: []const u8, field: []const u8) ?[]const u8 {
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
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

/// Extract an integer field value from a JSON string.
/// Finds `"field":number` patterns.
fn extractJsonIntField(json: []const u8, field: []const u8) ?i64 {
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(full_needle);

    const idx = std.mem.indexOf(u8, json, full_needle) orelse return null;
    const rest = json[idx + full_needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\n' or rest[i] == '\r' or rest[i] == ':')) {
        i += 1;
    }
    if (i >= rest.len) return null;

    // Handle optional negative sign
    const negative = if (rest[i] == '-') blk: {
        i += 1;
        break :blk true;
    } else false;

    if (i >= rest.len or rest[i] < '0' or rest[i] > '9') return null;

    var value: i64 = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') {
        value = value * 10 + (rest[i] - '0');
        i += 1;
    }

    return if (negative) -value else value;
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

/// Get a specific 0-indexed line from text. Returns empty slice if out of range.
fn getLineSlice(text: []const u8, line_num: u32) []const u8 {
    var current_line: u32 = 0;
    for (text, 0..) |ch, i| {
        if (current_line == line_num) {
            // Find end of this line
            var end = i;
            while (end < text.len and text[end] != '\n') {
                end += 1;
            }
            return text[i..end];
        }
        if (ch == '\n') {
            current_line += 1;
        }
    }
    // Handle last line (no trailing newline)
    if (current_line == line_num) {
        // Walk back to find the last line start
        var line_start: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
            line_start = nl + 1;
        }
        var end: usize = text.len;
        if (std.mem.indexOfScalar(u8, text[line_start..], '\n')) |nl2| {
            end = line_start + nl2;
        }
        return text[line_start..end];
    }
    return "";
}

/// Extract the identifier (word) at a given 0-indexed line and character position.
fn getWordAtPosition(text: []const u8, line: u32, character: u32) []const u8 {
    const line_text = getLineSlice(text, line);
    if (line_text.len == 0) return "";
    const char_idx: usize = @min(@as(usize, character), line_text.len -| 1);

    // Find word boundaries — identifier chars: alphanumeric and underscore
    var start = char_idx;
    while (start > 0 and isIdentChar(line_text[start - 1])) {
        start -= 1;
    }
    var end = char_idx;
    while (end < line_text.len and isIdentChar(line_text[end])) {
        end += 1;
    }
    if (start == end) return "";
    return line_text[start..end];
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

/// Read a file's contents into an allocated slice.
fn readFileAlloc(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

/// Collect all .zig source files under src/ into a list of allocated paths.
fn collectZigFiles(allocator: Allocator) ![]const []const u8 {
    var files = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    var src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch {
        // If no src/ dir, just return empty
        return try files.toOwnedSlice();
    };
    defer src_dir.close();

    var walker = src_dir.walk(allocator) catch {
        return try files.toOwnedSlice();
    };
    defer walker.deinit();

    while (walker.next() catch return try files.toOwnedSlice()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full_path = std.fmt.allocPrint(allocator, "src/{s}", .{entry.path}) catch continue;
        files.append(full_path) catch continue;
    }

    return try files.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Definition contexts — patterns that indicate a symbol definition
// ---------------------------------------------------------------------------

const definition_prefixes = [_][]const u8{
    "pub fn ",
    "fn ",
    "pub const ",
    "const ",
    "pub struct ",
    "struct ",
    "pub enum ",
    "enum ",
    "pub union ",
    "union ",
    "pub var ",
    "var ",
    "pub threadlocal var ",
    "threadlocal var ",
};

// ---------------------------------------------------------------------------
// Tool: lsp_definition
// ---------------------------------------------------------------------------

/// Find the definition of a symbol at a specific position in a file.
/// Reads the file, extracts the word at the given position, then searches
/// all .zig files in the project for definition patterns matching that word.
pub fn executeDefinition(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");
    const line_num: u32 = if (extractJsonIntField(args_json, "line")) |l| @intCast(@max(l, 0)) else 0;
    const character: u32 = if (extractJsonIntField(args_json, "character")) |c| @intCast(@max(c, 0)) else 0;

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    const word = getWordAtPosition(content, line_num, character);
    if (word.len == 0)
        return allocator.dupe(u8, "No symbol found at the given position");

    // Search project .zig files for definition patterns
    const zig_files = collectZigFiles(allocator) catch &.{};
    defer {
        for (zig_files) |f| allocator.free(f);
        allocator.free(zig_files);
    }

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Symbol: {s}\nSource: {s}:{d}:{d}\n\n", .{ word, file_path, line_num + 1, character + 1 });

    var found_count: u32 = 0;

    // Also search the file itself
    const search_files = blk: {
        var all = array_list_compat.ArrayList([]const u8).init(allocator);
        try all.append(file_path);
        for (zig_files) |f| {
            if (!std.mem.eql(u8, f, file_path)) {
                try all.append(f);
            }
        }
        break :blk try all.toOwnedSlice();
    };
    defer allocator.free(search_files);

    for (search_files) |search_path| {
        const file_content = readFileAlloc(allocator, search_path) catch continue;
        defer allocator.free(file_content);

        var line_idx: u32 = 0;
        var line_start: usize = 0;
        for (file_content, 0..) |ch, i| {
            if (ch == '\n' or i == file_content.len - 1) {
                const line_end = if (ch == '\n') i else i + 1;
                const line_text = file_content[line_start..line_end];

                // Check if this line contains the word in a definition context
                for (definition_prefixes) |prefix| {
                    if (std.mem.indexOf(u8, line_text, prefix)) |prefix_pos| {
                        const after_prefix = line_text[prefix_pos + prefix.len ..];
                        // Check if word appears at the start of after_prefix (possibly with pub or other qualifiers)
                        if (std.mem.startsWith(u8, after_prefix, word)) {
                            // Make sure it's a whole word match
                            const after_word_idx = word.len;
                            if (after_word_idx >= after_prefix.len or !isIdentChar(after_prefix[after_word_idx])) {
                                try writer.print("  {s}:{d}: {s}\n", .{ search_path, line_idx + 1, std.mem.trim(u8, line_text, " \t") });
                                found_count += 1;
                            }
                        }
                    }
                }

                line_idx += 1;
                line_start = i + 1;
            }
        }
    }

    if (found_count == 0) {
        try writer.print("No definition found for '{s}'\n", .{word});
    } else {
        try writer.print("\nFound {d} definition(s)\n", .{found_count});
    }

    return try result_buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tool: lsp_references
// ---------------------------------------------------------------------------

/// Find all references to a symbol at a position across project files.
pub fn executeReferences(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");
    const line_num: u32 = if (extractJsonIntField(args_json, "line")) |l| @intCast(@max(l, 0)) else 0;
    const character: u32 = if (extractJsonIntField(args_json, "character")) |c| @intCast(@max(c, 0)) else 0;

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    const word = getWordAtPosition(content, line_num, character);
    if (word.len == 0)
        return allocator.dupe(u8, "No symbol found at the given position");

    // Search project files
    const zig_files = collectZigFiles(allocator) catch &.{};
    defer {
        for (zig_files) |f| allocator.free(f);
        allocator.free(zig_files);
    }

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("References to '{s}':\n\n", .{word});

    var found_count: u32 = 0;

    // Build list of all files to search (file_path + zig_files)
    const search_files = blk: {
        var all = array_list_compat.ArrayList([]const u8).init(allocator);
        try all.append(file_path);
        for (zig_files) |f| {
            if (!std.mem.eql(u8, f, file_path)) {
                try all.append(f);
            }
        }
        break :blk try all.toOwnedSlice();
    };
    defer allocator.free(search_files);

    for (search_files) |search_path| {
        const file_content = readFileAlloc(allocator, search_path) catch continue;
        defer allocator.free(file_content);

        var line_idx: u32 = 0;
        var line_start: usize = 0;
        for (file_content, 0..) |ch, i| {
            if (ch == '\n' or i == file_content.len - 1) {
                const line_end = if (ch == '\n') i else i + 1;
                const line_text = file_content[line_start..line_end];

                // Search for whole-word occurrences of word in this line
                var search_pos: usize = 0;
                while (search_pos < line_text.len) {
                    if (std.mem.indexOf(u8, line_text[search_pos..], word)) |match_offset| {
                        const abs_pos = search_pos + match_offset;
                        // Check whole word boundaries
                        const prev_ok = (abs_pos == 0 or !isIdentChar(line_text[abs_pos - 1]));
                        const next_idx = abs_pos + word.len;
                        const next_ok = (next_idx >= line_text.len or !isIdentChar(line_text[next_idx]));
                        if (prev_ok and next_ok) {
                            try writer.print("  {s}:{d}:{d}: {s}\n", .{ search_path, line_idx + 1, abs_pos + 1, std.mem.trim(u8, line_text, " \t") });
                            found_count += 1;
                        }
                        search_pos = abs_pos + 1;
                    } else {
                        break;
                    }
                }

                line_idx += 1;
                line_start = i + 1;
            }
        }
    }

    if (found_count == 0) {
        try writer.print("No references found for '{s}'\n", .{word});
    } else {
        try writer.print("\nFound {d} reference(s)\n", .{found_count});
    }

    return try result_buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tool: lsp_diagnostics
// ---------------------------------------------------------------------------

/// Check for basic issues in a file: unclosed braces, TODO/FIXME/HACK/XXX markers.
pub fn executeDiagnostics(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Diagnostics for {s}:\n\n", .{file_path});

    var issue_count: u32 = 0;

    // Check for unclosed braces/parens/brackets
    var curly: i32 = 0;
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var line_idx: u32 = 0;
    var line_start: usize = 0;

    for (content, 0..) |ch, i| {
        switch (ch) {
            '{' => curly += 1,
            '}' => curly -= 1,
            '(' => paren += 1,
            ')' => paren -= 1,
            '[' => bracket += 1,
            ']' => bracket -= 1,
            '\n' => {
                const line_text = content[line_start..i];
                // Check for TODO/FIXME/HACK/XXX comments
                const markers = [_][]const u8{ "TODO", "FIXME", "HACK", "XXX" };
                for (markers) |marker| {
                    if (std.mem.indexOf(u8, line_text, marker)) |_| {
                        // Make sure it looks like a comment (after // or inside string — heuristic)
                        try writer.print("  [{s}] {s}:{d}: {s}\n", .{ marker, file_path, line_idx + 1, std.mem.trim(u8, line_text, " \t") });
                        issue_count += 1;
                    }
                }
                line_idx += 1;
                line_start = i + 1;
            },
            else => {},
        }
    }

    // Check last line for markers too
    if (line_start < content.len) {
        const line_text = content[line_start..];
        const markers = [_][]const u8{ "TODO", "FIXME", "HACK", "XXX" };
        for (markers) |marker| {
            if (std.mem.indexOf(u8, line_text, marker)) |_| {
                try writer.print("  [{s}] {s}:{d}: {s}\n", .{ marker, file_path, line_idx + 1, std.mem.trim(u8, line_text, " \t") });
                issue_count += 1;
            }
        }
    }

    // Report brace mismatches
    if (curly != 0) {
        const direction = if (curly > 0) "unclosed" else "extra closing";
        try writer.print("  [Brace] {s}: {d} unmatched curly braces ({s})\n", .{ file_path, @abs(curly), direction });
        issue_count += 1;
    }
    if (paren != 0) {
        const direction = if (paren > 0) "unclosed" else "extra closing";
        try writer.print("  [Paren] {s}: {d} unmatched parentheses ({s})\n", .{ file_path, @abs(paren), direction });
        issue_count += 1;
    }
    if (bracket != 0) {
        const direction = if (bracket > 0) "unclosed" else "extra closing";
        try writer.print("  [Bracket] {s}: {d} unmatched square brackets ({s})\n", .{ file_path, @abs(bracket), direction });
        issue_count += 1;
    }

    if (issue_count == 0) {
        try writer.print("No issues detected.\n", .{});
    } else {
        try writer.print("\n{d} issue(s) found.\n", .{issue_count});
    }

    return try result_buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tool: lsp_hover
// ---------------------------------------------------------------------------

/// Get type info and documentation for a symbol at a position.
/// Extracts doc comments (///) above the line and the full declaration line.
pub fn executeHover(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");
    const line_num: u32 = if (extractJsonIntField(args_json, "line")) |l| @intCast(@max(l, 0)) else 0;
    const character: u32 = if (extractJsonIntField(args_json, "character")) |c| @intCast(@max(c, 0)) else 0;

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    const word = getWordAtPosition(content, line_num, character);
    if (word.len == 0)
        return allocator.dupe(u8, "No symbol found at the given position");

    const current_line = getLineSlice(content, line_num);

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Hover info for '{s}' at {s}:{d}:{d}:\n\n", .{ word, file_path, line_num + 1, character + 1 });

    // Collect doc comments above the line
    var doc_lines = array_list_compat.ArrayList([]const u8).init(allocator);
    defer doc_lines.deinit();

    var scan_line: u32 = line_num;
    while (scan_line > 0) : (scan_line -= 1) {
        const prev_line = getLineSlice(content, scan_line - 1);
        const trimmed = std.mem.trim(u8, prev_line, " \t");
        if (std.mem.startsWith(u8, trimmed, "///")) {
            try doc_lines.append(trimmed);
        } else if (trimmed.len == 0) {
            // Skip blank lines between doc comments
            continue;
        } else {
            break;
        }
    }

    // Print doc comments in order (reversed since we collected backwards)
    if (doc_lines.items.len > 0) {
        try writer.print("Documentation:\n", .{});
        var i: usize = doc_lines.items.len;
        while (i > 0) : (i -= 1) {
            const doc = doc_lines.items[i - 1];
            // Strip the /// prefix
            const doc_content = if (doc.len > 3 and doc[3] == ' ')
                doc[4..]
            else if (doc.len > 3)
                doc[3..]
            else
                "";
            try writer.print("  {s}\n", .{doc_content});
        }
        try writer.print("\n", .{});
    }

    // Print the declaration line
    try writer.print("Declaration:\n  {s}\n", .{std.mem.trim(u8, current_line, " \t")});

    // If the word looks like it could be a function call, try to find its definition
    for (definition_prefixes) |prefix| {
        if (std.mem.indexOf(u8, current_line, prefix)) |_| {
            // This line IS a definition, note that
            try writer.print("\n(kind: definition)\n", .{});
            break;
        }
    }

    return try result_buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tool: lsp_symbols
// ---------------------------------------------------------------------------

/// List all symbols defined in a file.
/// Scans for function definitions, constants, structs, enums, etc.
pub fn executeSymbols(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Symbols in {s}:\n\n", .{file_path});

    var symbol_count: u32 = 0;
    var line_idx: u32 = 0;
    var line_start: usize = 0;

    for (content, 0..) |ch, i| {
        if (ch == '\n' or i == content.len - 1) {
            const line_end = if (ch == '\n') i else i + 1;
            const line_text = content[line_start..line_end];
            const trimmed = std.mem.trim(u8, line_text, " \t");

            // Skip empty lines and comments
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
                for (definition_prefixes) |prefix| {
                    if (std.mem.indexOf(u8, trimmed, prefix)) |pos| {
                        // Avoid matching inside strings or comments — heuristic: prefix should be near line start
                        // Only consider if the prefix is in the first 30 chars (before any string literals)
                        if (pos < 30) {
                            const after_prefix = trimmed[pos + prefix.len ..];
                            // Extract the symbol name (first identifier)
                            var name_end: usize = 0;
                            while (name_end < after_prefix.len and isIdentChar(after_prefix[name_end])) {
                                name_end += 1;
                            }
                            if (name_end > 0) {
                                const symbol_name = after_prefix[0..name_end];
                                // Determine kind from prefix
                                const kind = getSymbolKind(prefix);
                                try writer.print("  {s:>6}  L{d:>4}: {s}\n", .{ kind, line_idx + 1, symbol_name });
                                symbol_count += 1;
                            }
                        }
                    }
                }
            }

            line_idx += 1;
            line_start = i + 1;
        }
    }

    if (symbol_count == 0) {
        try writer.print("No symbols found.\n", .{});
    } else {
        try writer.print("\n{d} symbol(s) found.\n", .{symbol_count});
    }

    return try result_buf.toOwnedSlice();
}

fn getSymbolKind(prefix: []const u8) []const u8 {
    if (std.mem.indexOf(u8, prefix, "fn ") != null) return "func";
    if (std.mem.indexOf(u8, prefix, "struct ") != null) return "struct";
    if (std.mem.indexOf(u8, prefix, "enum ") != null) return "enum";
    if (std.mem.indexOf(u8, prefix, "union ") != null) return "union";
    if (std.mem.indexOf(u8, prefix, "var ") != null) return "var";
    if (std.mem.indexOf(u8, prefix, "const ") != null) return "const";
    return "other";
}

// ---------------------------------------------------------------------------
// Tool: lsp_rename
// ---------------------------------------------------------------------------

/// Preview renaming a symbol across the workspace.
/// Returns a list of locations where the rename would occur, but does NOT modify files.
pub fn executeRename(allocator: Allocator, args_json: []const u8) ![]const u8 {
    const file_path = extractJsonStringField(args_json, "file_path") orelse
        return allocator.dupe(u8, "Error: missing 'file_path' parameter");
    const line_num: u32 = if (extractJsonIntField(args_json, "line")) |l| @intCast(@max(l, 0)) else 0;
    const character: u32 = if (extractJsonIntField(args_json, "character")) |c| @intCast(@max(c, 0)) else 0;
    const new_name = extractJsonStringField(args_json, "new_name") orelse
        return allocator.dupe(u8, "Error: missing 'new_name' parameter");

    if (new_name.len == 0)
        return allocator.dupe(u8, "Error: 'new_name' cannot be empty");

    // Validate new_name is a valid identifier
    for (new_name) |ch| {
        if (!isIdentChar(ch))
            return std.fmt.allocPrint(allocator, "Error: '{s}' is not a valid identifier", .{new_name});
    }

    const content = readFileAlloc(allocator, file_path) catch
        return std.fmt.allocPrint(allocator, "Error: cannot read file '{s}'", .{file_path});
    defer allocator.free(content);

    const old_name = getWordAtPosition(content, line_num, character);
    if (old_name.len == 0)
        return allocator.dupe(u8, "No symbol found at the given position");

    if (std.mem.eql(u8, old_name, new_name))
        return allocator.dupe(u8, "Old name and new name are identical. No changes needed.");

    // Search project files for references
    const zig_files = collectZigFiles(allocator) catch &.{};
    defer {
        for (zig_files) |f| allocator.free(f);
        allocator.free(zig_files);
    }

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Rename preview: '{s}' → '{s}'\n\n", .{ old_name, new_name });

    var change_count: u32 = 0;

    const search_files = blk: {
        var all = array_list_compat.ArrayList([]const u8).init(allocator);
        try all.append(file_path);
        for (zig_files) |f| {
            if (!std.mem.eql(u8, f, file_path)) {
                try all.append(f);
            }
        }
        break :blk try all.toOwnedSlice();
    };
    defer allocator.free(search_files);

    for (search_files) |search_path| {
        const file_content = readFileAlloc(allocator, search_path) catch continue;
        defer allocator.free(file_content);

        var line_idx: u32 = 0;
        var line_start: usize = 0;
        var file_had_changes = false;

        for (file_content, 0..) |ch, i| {
            if (ch == '\n' or i == file_content.len - 1) {
                const line_end = if (ch == '\n') i else i + 1;
                const line_text = file_content[line_start..line_end];

                // Search for whole-word occurrences
                var search_pos: usize = 0;
                while (search_pos < line_text.len) {
                    if (std.mem.indexOf(u8, line_text[search_pos..], old_name)) |match_offset| {
                        const abs_pos = search_pos + match_offset;
                        const prev_ok = (abs_pos == 0 or !isIdentChar(line_text[abs_pos - 1]));
                        const next_idx = abs_pos + old_name.len;
                        const next_ok = (next_idx >= line_text.len or !isIdentChar(line_text[next_idx]));
                        if (prev_ok and next_ok) {
                            if (!file_had_changes) {
                                try writer.print("  {s}:\n", .{search_path});
                                file_had_changes = true;
                            }
                            try writer.print("    L{d}: {s}\n", .{ line_idx + 1, std.mem.trim(u8, line_text, " \t") });
                            change_count += 1;
                        }
                        search_pos = abs_pos + 1;
                    } else {
                        break;
                    }
                }

                line_idx += 1;
                line_start = i + 1;
            }
        }
    }

    if (change_count == 0) {
        try writer.print("No occurrences found to rename.\n", .{});
    } else {
        try writer.print("\n{d} occurrence(s) would be renamed from '{s}' to '{s}'.\n", .{ change_count, old_name, new_name });
        try writer.print("(Preview only — no files were modified)\n", .{});
    }

    return try result_buf.toOwnedSlice();
}
