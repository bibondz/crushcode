const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const env_mod = @import("env");
const args_mod = @import("args");
const color_mod = @import("color");

const LogLevel = @import("structured_log").LogLevel;

pub fn handleLogs(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse flags from args.remaining
    var tail_count: usize = 20;
    var follow: bool = false;
    var filter_level: ?LogLevel = null;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        const arg = args.remaining[i];
        if (std.mem.eql(u8, arg, "--tail")) {
            i += 1;
            if (i < args.remaining.len) {
                tail_count = std.fmt.parseInt(usize, args.remaining[i], 10) catch 20;
            }
        } else if (std.mem.startsWith(u8, arg, "--tail=")) {
            tail_count = std.fmt.parseInt(usize, arg[7..], 10) catch 20;
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "--level")) {
            i += 1;
            if (i < args.remaining.len) {
                filter_level = parseLevel(args.remaining[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "--level=")) {
            filter_level = parseLevel(arg[8..]);
        }
    }

    // Get log directory
    const log_dir = env_mod.getLogDir(allocator) catch |err| {
        const stderr = file_compat.File.stderr();
        stderr.print("Error: could not determine log directory: {}\n", .{err}) catch {};
        return;
    };
    defer allocator.free(log_dir);

    // Find latest log file
    const latest_file = findLatestLogFile(allocator, log_dir) catch |err| {
        const stderr = file_compat.File.stderr();
        if (err == error.FileNotFound) {
            stderr.print("No log files found in {s}\n", .{log_dir}) catch {};
        } else {
            stderr.print("Error reading log directory: {}\n", .{err}) catch {};
        }
        return;
    };
    defer allocator.free(latest_file);

    const filepath = try std.fs.path.join(allocator, &.{ log_dir, latest_file });
    defer allocator.free(filepath);

    if (follow) {
        try followFile(allocator, filepath, filter_level);
    } else {
        try tailFile(allocator, filepath, filter_level, tail_count);
    }
}

fn parseLevel(str: []const u8) ?LogLevel {
    if (std.mem.eql(u8, str, "debug") or std.mem.eql(u8, str, "DEBUG")) return .debug;
    if (std.mem.eql(u8, str, "info") or std.mem.eql(u8, str, "INFO")) return .info;
    if (std.mem.eql(u8, str, "warn") or std.mem.eql(u8, str, "WARN")) return .warn;
    if (std.mem.eql(u8, str, "err") or std.mem.eql(u8, str, "error") or std.mem.eql(u8, str, "ERR") or std.mem.eql(u8, str, "ERROR")) return .err;
    return null;
}

fn findLatestLogFile(allocator: std.mem.Allocator, log_dir: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(log_dir, .{ .iterate = true });
    defer dir.close();

    var filenames = array_list_compat.ArrayList([]const u8).init(allocator);
    defer {
        for (filenames.items) |name| allocator.free(name);
        filenames.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "crushcode-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try filenames.append(name_copy);
    }

    if (filenames.items.len == 0) return error.FileNotFound;

    // Sort alphabetically — latest file is last
    const items = filenames.items;
    std.sort.block([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return allocator.dupe(u8, items[items.len - 1]);
}

fn tailFile(allocator: std.mem.Allocator, filepath: []const u8, filter_level: ?LogLevel, count: usize) !void {
    const contents = readFileContents(allocator, filepath) catch |err| {
        const stderr = file_compat.File.stderr();
        stderr.print("Error reading log file: {}\n", .{err}) catch {};
        return;
    };
    defer allocator.free(contents);

    var lines = array_list_compat.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    // Split by newlines
    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        // Filter by level if specified
        if (filter_level) |level| {
            if (!lineMatchesLevel(line, level)) continue;
        }
        try lines.append(line);
    }

    const stdout = file_compat.File.stdout();
    // Print last `count` lines
    const start = if (lines.items.len > count) lines.items.len - count else 0;
    var i: usize = start;
    while (i < lines.items.len) : (i += 1) {
        printColoredLine(stdout, lines.items[i]);
    }
}

fn followFile(allocator: std.mem.Allocator, filepath: []const u8, filter_level: ?LogLevel) !void {
    const stdout = file_compat.File.stdout();

    // First, print existing content
    const initial = readFileContents(allocator, filepath) catch |err| {
        const stderr = file_compat.File.stderr();
        stderr.print("Error reading log file: {}\n", .{err}) catch {};
        return;
    };
    defer allocator.free(initial);

    // Print existing lines that match filter
    var line_iter = std.mem.splitSequence(u8, initial, "\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (filter_level) |level| {
            if (!lineMatchesLevel(line, level)) continue;
        }
        printColoredLine(stdout, line);
    }

    // Track file size
    var last_size: usize = initial.len;

    // Poll for new content
    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        const contents = readFileContents(allocator, filepath) catch continue;
        defer allocator.free(contents);

        if (contents.len > last_size) {
            const new_data = contents[last_size..];
            var new_iter = std.mem.splitSequence(u8, new_data, "\n");
            while (new_iter.next()) |line| {
                if (line.len == 0) continue;
                if (filter_level) |level| {
                    if (!lineMatchesLevel(line, level)) continue;
                }
                printColoredLine(stdout, line);
            }
            last_size = contents.len;
        }
    }
}

fn readFileContents(allocator: std.mem.Allocator, filepath: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return allocator.dupe(u8, "");

    const contents = try allocator.alloc(u8, @intCast(stat.size));
    const bytes_read = try file.readAll(contents);
    return allocator.realloc(contents, bytes_read);
}

fn lineMatchesLevel(line: []const u8, level: LogLevel) bool {
    // Search for "level":"xxx" in the JSONL line
    const level_str = std.fmt.allocPrint(std.heap.page_allocator, "\"level\":\"{s}\"", .{level.asString()}) catch return false;
    defer std.heap.page_allocator.free(level_str);
    return std.mem.indexOf(u8, line, level_str) != null;
}

fn printColoredLine(stdout: file_compat.File, line: []const u8) void {
    // Determine level from line for coloring
    const style = getStyleForLine(line);

    // Extract timestamp for display
    const ts = extractField(line, "ts");
    const level = extractField(line, "level");
    const msg = extractField(line, "msg");
    const source = extractField(line, "source");

    if (ts) |t| {
        stdout.print("{s}{s}{s} ", .{ color_mod.Style.dimmed.start(), t, color_mod.Style.dimmed.reset() }) catch {};
    }
    if (level) |l| {
        stdout.print("{s}{s}{s} ", .{ style.start(), l, style.reset() }) catch {};
    }
    if (source) |s| {
        stdout.print("{s}[{s}]{s} ", .{ color_mod.Style.muted.start(), s, color_mod.Style.muted.reset() }) catch {};
    }
    if (msg) |m| {
        stdout.print("{s}\n", .{m}) catch {};
    } else {
        // Fallback: print raw line
        stdout.print("{s}\n", .{line}) catch {};
    }
}

fn getStyleForLine(line: []const u8) color_mod.Style {
    if (std.mem.indexOf(u8, line, "\"level\":\"err\"")) |_| return color_mod.Style.err;
    if (std.mem.indexOf(u8, line, "\"level\":\"warn\"")) |_| return color_mod.Style.warning;
    if (std.mem.indexOf(u8, line, "\"level\":\"info\"")) |_| return color_mod.Style.info;
    if (std.mem.indexOf(u8, line, "\"level\":\"debug\"")) |_| return color_mod.Style.dimmed;
    return color_mod.Style{};
}

/// Extract a JSON field value from a JSONL line.
/// Returns an allocated string (caller must free with page_allocator).
fn extractField(line: []const u8, field_name: []const u8) ?[]const u8 {
    const pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(pattern);

    const start_idx = std.mem.indexOf(u8, line, pattern) orelse return null;
    const value_start = start_idx + pattern.len;

    // Find closing quote (handle escaped quotes)
    var i: usize = value_start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (line[i] == '"') break;
    }

    if (i >= line.len) return null;
    const raw_value = line[value_start..i];

    // Unescape the value
    var buf = array_list_compat.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();

    var j: usize = 0;
    while (j < raw_value.len) : (j += 1) {
        if (raw_value[j] == '\\' and j + 1 < raw_value.len) {
            const next = raw_value[j + 1];
            switch (next) {
                '"' => {
                    buf.append('"') catch return null;
                    j += 1;
                },
                '\\' => {
                    buf.append('\\') catch return null;
                    j += 1;
                },
                'n' => {
                    buf.append('\n') catch return null;
                    j += 1;
                },
                'r' => {
                    buf.append('\r') catch return null;
                    j += 1;
                },
                't' => {
                    buf.append('\t') catch return null;
                    j += 1;
                },
                else => {
                    buf.append(raw_value[j]) catch return null;
                },
            }
        } else {
            buf.append(raw_value[j]) catch return null;
        }
    }

    return buf.toOwnedSlice() catch null;
}
