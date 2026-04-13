const std = @import("std");
const args_mod = @import("args");
const lsp_mod = @import("lsp");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Handle LSP (Language Server Protocol) commands
pub fn handleLSP(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        printLSPHelp();
        return;
    }

    var positional = array_list_compat.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    var language: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.remaining.len) {
        const arg = args.remaining[index];
        if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (index + 1 >= args.remaining.len) {
                stdout_print("Missing value for --lang\n", .{});
                return;
            }
            language = args.remaining[index + 1];
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--lang=")) {
            language = arg["--lang=".len..];
            index += 1;
            continue;
        }

        try positional.append(arg);
        index += 1;
    }

    if (positional.items.len == 0 or std.mem.eql(u8, positional.items[0], "help") or std.mem.eql(u8, positional.items[0], "--help") or std.mem.eql(u8, positional.items[0], "-h")) {
        printLSPHelp();
        return;
    }

    const subcommand = positional.items[0];
    const needs_position = std.mem.eql(u8, subcommand, "goto") or
        std.mem.eql(u8, subcommand, "refs") or
        std.mem.eql(u8, subcommand, "hover") or
        std.mem.eql(u8, subcommand, "complete");

    const required_args: usize = if (needs_position) 4 else if (std.mem.eql(u8, subcommand, "diagnostics")) 2 else 0;
    if (required_args == 0 or positional.items.len < required_args) {
        printLSPHelp();
        return;
    }

    const file_path = positional.items[1];
    const resolved_language = language orelse detectLSPLanguage(file_path) orelse {
        stdout_print("Could not detect language for '{s}'. Use --lang.\n", .{file_path});
        return;
    };

    const server = lsp_mod.getLSPServer(resolved_language) catch {
        stdout_print("No LSP server configured for language '{s}'.\n", .{resolved_language});
        return;
    };

    const file_contents = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
        stdout_print("Error reading '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(file_contents);

    const file_uri = try pathToFileUri(allocator, file_path);
    defer allocator.free(file_uri);

    const workspace_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_path);
    const workspace_uri = try absolutePathToFileUri(allocator, workspace_path);
    defer allocator.free(workspace_uri);

    var client = lsp_mod.LSPClient.init(allocator, server.cmd, server.args);
    defer client.deinit();
    client.server_uri = workspace_uri;

    try client.start();
    defer client.shutdown() catch {};

    try client.openDocument(file_uri, resolved_language, file_contents);

    const stdout = file_compat.File.stdout().writer();

    if (std.mem.eql(u8, subcommand, "goto")) {
        const line = try parseLSPIndex(positional.items[2]);
        const character = try parseLSPIndex(positional.items[3]);
        const locations = try client.goToDefinition(file_uri, line, character);
        defer freeLSPLocations(allocator, locations);

        if (locations.len == 0) {
            try stdout.print("No definition found\n", .{});
            return;
        }

        for (locations) |location| {
            try stdout.print("{s}:{d}:{d}\n", .{ location.uri, location.range.start.line + 1, location.range.start.character + 1 });
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "refs")) {
        const line = try parseLSPIndex(positional.items[2]);
        const character = try parseLSPIndex(positional.items[3]);
        const locations = try client.findReferences(file_uri, line, character);
        defer freeLSPLocations(allocator, locations);

        if (locations.len == 0) {
            try stdout.print("No references found\n", .{});
            return;
        }

        for (locations) |location| {
            try stdout.print("{s}:{d}:{d}\n", .{ location.uri, location.range.start.line + 1, location.range.start.character + 1 });
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "hover")) {
        const line = try parseLSPIndex(positional.items[2]);
        const character = try parseLSPIndex(positional.items[3]);
        const hover_text = try client.hover(file_uri, line, character);
        defer if (hover_text) |text| allocator.free(text);

        if (hover_text) |text| {
            try stdout.print("{s}\n", .{text});
        } else {
            try stdout.print("No hover information\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "complete")) {
        const line = try parseLSPIndex(positional.items[2]);
        const character = try parseLSPIndex(positional.items[3]);
        const items = try client.completion(file_uri, line, character);
        defer freeLSPCompletionItems(allocator, items);

        if (items.len == 0) {
            try stdout.print("No completions found\n", .{});
            return;
        }

        for (items) |item| {
            try stdout.print("- {s}", .{item.label});
            if (item.detail) |detail| {
                try stdout.print(" — {s}", .{detail});
            }
            try stdout.print("\n", .{});
            if (item.documentation) |documentation| {
                try stdout.print("  {s}\n", .{documentation});
            }
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "diagnostics")) {
        const diagnostics = try client.getDiagnostics(file_uri);
        defer freeLSPDiagnostics(allocator, diagnostics);

        if (diagnostics.len == 0) {
            try stdout.print("No diagnostics\n", .{});
            return;
        }

        for (diagnostics) |diagnostic| {
            try stdout.print("{s}:{d}:{d}: {s}: {s}\n", .{
                file_path,
                diagnostic.range.start.line + 1,
                diagnostic.range.start.character + 1,
                diagnosticSeverityName(diagnostic.severity),
                diagnostic.message,
            });
        }
        return;
    }

    printLSPHelp();
}

fn printLSPHelp() void {
    stdout_print("Usage: crushcode lsp goto <file> <line> <char> [--lang <language>]\n", .{});
    stdout_print("       crushcode lsp refs <file> <line> <char> [--lang <language>]\n", .{});
    stdout_print("       crushcode lsp hover <file> <line> <char> [--lang <language>]\n", .{});
    stdout_print("       crushcode lsp complete <file> <line> <char> [--lang <language>]\n", .{});
    stdout_print("       crushcode lsp diagnostics <file> [--lang <language>]\n", .{});
}

fn parseLSPIndex(value: []const u8) !u32 {
    const parsed = try std.fmt.parseInt(u32, value, 10);
    return if (parsed > 0) parsed - 1 else 0;
}

fn detectLSPLanguage(file_path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, extension, ".zig")) return "zig";
    if (std.mem.eql(u8, extension, ".rs")) return "rust";
    if (std.mem.eql(u8, extension, ".go")) return "go";
    if (std.mem.eql(u8, extension, ".ts") or std.mem.eql(u8, extension, ".tsx")) return "typescript";
    if (std.mem.eql(u8, extension, ".js") or std.mem.eql(u8, extension, ".jsx") or std.mem.eql(u8, extension, ".mjs") or std.mem.eql(u8, extension, ".cjs")) return "javascript";
    if (std.mem.eql(u8, extension, ".py")) return "python";
    if (std.mem.eql(u8, extension, ".java")) return "java";
    return null;
}

fn pathToFileUri(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const absolute_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(absolute_path);
    return try absolutePathToFileUri(allocator, absolute_path);
}

fn absolutePathToFileUri(allocator: std.mem.Allocator, absolute_path: []const u8) ![]const u8 {
    const normalized_path = try allocator.dupe(u8, absolute_path);
    defer allocator.free(normalized_path);

    for (normalized_path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }

    if (normalized_path.len >= 2 and std.ascii.isAlphabetic(normalized_path[0]) and normalized_path[1] == ':') {
        return try std.fmt.allocPrint(allocator, "file:///{s}", .{normalized_path});
    }

    return try std.fmt.allocPrint(allocator, "file://{s}", .{normalized_path});
}

fn freeLSPLocations(allocator: std.mem.Allocator, locations: []lsp_mod.LSPClient.Location) void {
    for (locations) |location| {
        allocator.free(location.uri);
    }
    allocator.free(locations);
}

fn freeLSPCompletionItems(allocator: std.mem.Allocator, items: []lsp_mod.LSPClient.CompletionItem) void {
    for (items) |item| {
        allocator.free(item.label);
        if (item.detail) |detail| allocator.free(detail);
        if (item.documentation) |documentation| allocator.free(documentation);
    }
    allocator.free(items);
}

fn freeLSPDiagnostics(allocator: std.mem.Allocator, diagnostics: []lsp_mod.LSPClient.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        allocator.free(diagnostic.message);
    }
    allocator.free(diagnostics);
}

fn diagnosticSeverityName(severity: ?lsp_mod.LSPClient.Severity) []const u8 {
    return switch (severity orelse .information) {
        .@"error" => "error",
        .warning => "warning",
        .information => "information",
        .hint => "hint",
    };
}
