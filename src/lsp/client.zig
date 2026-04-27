const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// Language Server Protocol client
/// Implements JSON-RPC 2.0 communication with LSP servers
///
/// Reference: https://microsoft.github.io/language-server-protocol/
/// Common LSP servers: zls (Zig), rust-analyzer, gopls, typescript-language-server
pub const LSPClient = struct {
    allocator: Allocator,
    server_command: []const u8,
    server_args: []const []const u8,
    process: ?std.process.Child,
    server_uri: []const u8,
    next_id: i64,
    diagnostics: array_list_compat.ArrayList(DocumentDiagnostics),

    const DocumentDiagnostics = struct {
        uri: []const u8,
        diagnostics: []Diagnostic,
    };

    pub const Position = struct {
        line: u32, // 0-based
        character: u32, // UTF-16 code units, 0-based
    };

    pub const Range = struct {
        start: Position,
        end: Position,
    };

    pub const Location = struct {
        uri: []const u8,
        range: Range,
    };

    pub const Diagnostic = struct {
        range: Range,
        severity: ?Severity,
        message: []const u8,
    };

    pub const Severity = enum(u32) {
        @"error" = 1,
        warning = 2,
        information = 3,
        hint = 4,
    };

    pub const TextDocumentItem = struct {
        uri: []const u8,
        languageId: []const u8,
        version: i32,
        text: []const u8,
    };

    pub const CompletionItem = struct {
        label: []const u8,
        kind: ?CompletionItemKind,
        detail: ?[]const u8,
        documentation: ?[]const u8,
    };

    pub const CompletionItemKind = enum(u32) {
        text = 1,
        method = 2,
        function = 3,
        constructor = 4,
        field = 5,
        variable = 6,
        class = 7,
        interface = 8,
        module = 9,
        property = 10,
        unit = 11,
        value = 12,
        @"enum" = 13,
        keyword = 14,
        snippet = 15,
        color = 16,
        file = 17,
        reference = 18,
        folder = 19,
        enumMember = 20,
        constant = 21,
        @"struct" = 22,
        event = 23,
        operator = 24,
        typeParameter = 25,
    };

    pub fn init(allocator: Allocator, server_command: []const u8, server_args: []const []const u8) LSPClient {
        return LSPClient{
            .allocator = allocator,
            .server_command = server_command,
            .server_args = server_args,
            .process = null,
            .server_uri = "file:///tmp/untitled",
            .next_id = 1,
            .diagnostics = array_list_compat.ArrayList(DocumentDiagnostics).init(allocator),
        };
    }

    pub fn deinit(self: *LSPClient) void {
        self.freeAllDiagnostics();
        self.diagnostics.deinit();
        if (self.process) |*p| {
            _ = p.kill() catch {};
            self.process = null;
        }
    }

    /// Start LSP server and initialize
    pub fn start(self: *LSPClient) !void {
        const argv = self.allocator.alloc([]const u8, self.server_args.len + 1) catch return error.OutOfMemory;
        defer self.allocator.free(argv);
        argv[0] = self.server_command;
        for (self.server_args, 0..) |arg, i| {
            argv[i + 1] = arg;
        }

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        self.process = child;

        // Send initialize request
        const initialize_response = try self.sendRequest("initialize", .{
            .processId = null,
            .rootUri = self.server_uri,
            .capabilities = .{
                .textDocument = .{
                    .completion = .{
                        .dynamicRegistration = true,
                    },
                    .definition = .{
                        .dynamicRegistration = true,
                    },
                    .references = .{
                        .dynamicRegistration = true,
                    },
                    .hover = .{
                        .dynamicRegistration = true,
                    },
                },
            },
        });
        defer self.allocator.free(initialize_response);

        // Send initialized notification
        try self.sendNotification("initialized", .{});
    }

    /// Open a document in the LSP server
    pub fn openDocument(self: *LSPClient, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        try self.sendNotification("textDocument/didOpen", .{
            .textDocument = TextDocumentItem{
                .uri = uri,
                .languageId = language_id,
                .version = 1,
                .text = text,
            },
        });
    }

    /// Go to definition at position
    pub fn goToDefinition(self: *LSPClient, uri: []const u8, line: u32, character: u32) ![]Location {
        const response = try self.sendRequest("textDocument/definition", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
        });
        defer self.allocator.free(response);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        return try self.parseLocations(parsed.value);
    }

    /// Find all references to symbol at position
    pub fn findReferences(self: *LSPClient, uri: []const u8, line: u32, character: u32) ![]Location {
        const response = try self.sendRequest("textDocument/references", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
            .context = .{ .includeDeclaration = true },
        });
        defer self.allocator.free(response);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        return try self.parseLocations(parsed.value);
    }

    /// Get hover information at position
    pub fn hover(self: *LSPClient, uri: []const u8, line: u32, character: u32) !?[]const u8 {
        const response = try self.sendRequest("textDocument/hover", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
        });
        defer self.allocator.free(response);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        return try self.parseHover(parsed.value);
    }

    /// Get completion items at position
    pub fn completion(self: *LSPClient, uri: []const u8, line: u32, character: u32) ![]CompletionItem {
        const response = try self.sendRequest("textDocument/completion", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
        });
        defer self.allocator.free(response);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        return try self.parseCompletionItems(parsed.value);
    }

    /// Get diagnostics for document
    pub fn getDiagnostics(self: *LSPClient, uri: []const u8) ![]Diagnostic {
        try self.drainNotifications(500);
        return try self.cloneDiagnosticsForUri(uri);
    }

    /// Shutdown LSP server
    pub fn shutdown(self: *LSPClient) !void {
        const response = try self.sendRequest("shutdown", .{});
        defer self.allocator.free(response);
        try self.sendNotification("exit", .{});
    }

    fn sendRequest(self: *LSPClient, method: []const u8, params: anytype) ![]const u8 {
        const request_id = self.next_id;
        self.next_id += 1;

        const request_json = try stringifyAllocCompat(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .method = method,
            .params = params,
        });
        defer self.allocator.free(request_json);

        try self.writeMessage(request_json);
        return try self.readResponse(request_id);
    }

    fn sendNotification(self: *LSPClient, method: []const u8, params: anytype) !void {
        const notification_json = try stringifyAllocCompat(self.allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        });
        defer self.allocator.free(notification_json);

        try self.writeMessage(notification_json);
    }

    fn writeMessage(self: *LSPClient, json_message: []const u8) !void {
        const process = self.process orelse return error.LSPServerNotStarted;
        const stdin = process.stdin orelse return error.LSPServerNotStarted;
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{json_message.len});
        defer self.allocator.free(header);

        try stdin.writeAll(header);
        try stdin.writeAll(json_message);
    }

    fn readResponse(self: *LSPClient, expected_id: i64) ![]const u8 {
        while (true) {
            const message = try self.readMessage();
            defer self.allocator.free(message);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            if (obj.get("method")) |method_value| {
                if (method_value != .string) continue;

                if (obj.get("id")) |id_value| {
                    try self.respondToServerRequest(id_value);
                } else {
                    try self.handleNotification(method_value.string, obj.get("params"));
                }
                continue;
            }

            const id_value = obj.get("id") orelse continue;
            if (!self.responseMatchesId(id_value, expected_id)) continue;

            if (obj.get("error")) |error_value| {
                self.printResponseError(error_value);
                return error.LSPRequestFailed;
            }

            const result_value = obj.get("result") orelse std.json.Value{ .null = {} };
            return try stringifyAllocCompat(self.allocator, result_value);
        }
    }

    fn readMessage(self: *LSPClient) ![]u8 {
        const process = self.process orelse return error.LSPServerNotStarted;
        const stdout_file = process.stdout orelse return error.LSPServerNotStarted;
        var reader = file_compat.wrap(stdout_file).reader();
        var header_buffer: [4096]u8 = undefined;
        var content_length: ?usize = null;

        while (true) {
            const line = (try reader.readUntilDelimiterOrEof(&header_buffer, '\n')) orelse return error.EndOfStream;
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) break;

            if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
                const raw_length = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
                content_length = try std.fmt.parseInt(usize, raw_length, 10);
            }
        }

        const length = content_length orelse return error.InvalidLSPHeader;
        const body = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(body);
        try reader.readNoEof(body);
        return body;
    }

    pub fn drainNotifications(self: *LSPClient, timeout_ms: i32) !void {
        var current_timeout = timeout_ms;
        while (try self.stdoutReady(current_timeout)) {
            const message = try self.readMessage();
            defer self.allocator.free(message);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            if (parsed.value != .object) {
                current_timeout = 0;
                continue;
            }

            const obj = parsed.value.object;
            if (obj.get("method")) |method_value| {
                if (method_value == .string) {
                    if (obj.get("id")) |id_value| {
                        try self.respondToServerRequest(id_value);
                    } else {
                        try self.handleNotification(method_value.string, obj.get("params"));
                    }
                }
            }

            current_timeout = 0;
        }
    }

    fn stdoutReady(self: *LSPClient, timeout_ms: i32) !bool {
        if (@import("builtin").os.tag == .windows) {
            // Winsock WSAPoll requires SOCKET handles; child stdout is a regular HANDLE.
            // Use a simple sleep + return ready as fallback.
            std.Thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
            return true;
        }
        const process = self.process orelse return false;
        const stdout = process.stdout orelse return false;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stdout.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        return ready > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0;
    }

    fn respondToServerRequest(self: *LSPClient, id_value: std.json.Value) !void {
        const id_json = try stringifyAllocCompat(self.allocator, id_value);
        defer self.allocator.free(id_json);

        const response_json = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_json});
        defer self.allocator.free(response_json);

        try self.writeMessage(response_json);
    }

    fn handleNotification(self: *LSPClient, method: []const u8, params: ?std.json.Value) !void {
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            return;
        }

        const params_value = params orelse return;
        if (params_value != .object) return;

        const uri_value = params_value.object.get("uri") orelse return;
        if (uri_value != .string) return;

        const diagnostics_value = params_value.object.get("diagnostics") orelse return;
        const diagnostics = try self.parseDiagnosticsValue(diagnostics_value);
        errdefer self.freeDiagnosticsSlice(diagnostics);

        try self.storeDiagnostics(uri_value.string, diagnostics);
    }

    fn storeDiagnostics(self: *LSPClient, uri: []const u8, diagnostics: []Diagnostic) !void {
        for (self.diagnostics.items) |*entry| {
            if (std.mem.eql(u8, entry.uri, uri)) {
                self.freeDiagnosticsSlice(entry.diagnostics);
                entry.diagnostics = diagnostics;
                return;
            }
        }

        try self.diagnostics.append(.{
            .uri = try self.allocator.dupe(u8, uri),
            .diagnostics = diagnostics,
        });
    }

    fn cloneDiagnosticsForUri(self: *LSPClient, uri: []const u8) ![]Diagnostic {
        for (self.diagnostics.items) |entry| {
            if (std.mem.eql(u8, entry.uri, uri)) {
                return try self.cloneDiagnostics(entry.diagnostics);
            }
        }

        return try self.allocator.alloc(Diagnostic, 0);
    }

    fn parseLocations(self: *LSPClient, value: std.json.Value) ![]Location {
        return switch (value) {
            .null => self.allocator.alloc(Location, 0),
            .array => |array| blk: {
                const locations = try self.allocator.alloc(Location, array.items.len);
                errdefer self.freeLocations(locations, 0);

                for (array.items, 0..) |item, index| {
                    locations[index] = try self.parseLocation(item);
                }
                break :blk locations;
            },
            .object => blk: {
                const locations = try self.allocator.alloc(Location, 1);
                errdefer self.allocator.free(locations);
                locations[0] = try self.parseLocation(value);
                break :blk locations;
            },
            else => error.InvalidResponse,
        };
    }

    fn parseLocation(self: *LSPClient, value: std.json.Value) !Location {
        if (value != .object) return error.InvalidResponse;

        const uri_value = value.object.get("uri") orelse value.object.get("targetUri") orelse return error.InvalidResponse;
        const range_value = value.object.get("range") orelse value.object.get("targetSelectionRange") orelse value.object.get("targetRange") orelse return error.InvalidResponse;
        if (uri_value != .string) return error.InvalidResponse;

        return .{
            .uri = try self.allocator.dupe(u8, uri_value.string),
            .range = try self.parseRange(range_value),
        };
    }

    fn parseRange(self: *LSPClient, value: std.json.Value) !Range {
        if (value != .object) return error.InvalidResponse;

        return .{
            .start = try self.parsePosition(value.object.get("start") orelse return error.InvalidResponse),
            .end = try self.parsePosition(value.object.get("end") orelse return error.InvalidResponse),
        };
    }

    fn parsePosition(self: *LSPClient, value: std.json.Value) !Position {
        _ = self;
        if (value != .object) return error.InvalidResponse;

        const line_value = value.object.get("line") orelse return error.InvalidResponse;
        const char_value = value.object.get("character") orelse return error.InvalidResponse;
        if (line_value != .integer or char_value != .integer) return error.InvalidResponse;

        return .{
            .line = @intCast(line_value.integer),
            .character = @intCast(char_value.integer),
        };
    }

    fn parseHover(self: *LSPClient, value: std.json.Value) !?[]const u8 {
        if (value == .null) return null;
        if (value != .object) return null;

        const contents = value.object.get("contents") orelse return null;
        return try self.hoverContentsToString(contents);
    }

    fn hoverContentsToString(self: *LSPClient, value: std.json.Value) !?[]const u8 {
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        try self.appendHoverValue(&output, value);
        if (output.items.len == 0) {
            output.deinit();
            return null;
        }

        return try output.toOwnedSlice();
    }

    fn appendHoverValue(self: *LSPClient, output: *array_list_compat.ArrayList(u8), value: std.json.Value) !void {
        switch (value) {
            .null => {},
            .string => |text| try output.appendSlice(text),
            .array => |items| {
                for (items.items, 0..) |item, index| {
                    if (index > 0 and output.items.len > 0) {
                        try output.appendSlice("\n\n");
                    }
                    try self.appendHoverValue(output, item);
                }
            },
            .object => |obj| {
                if (obj.get("value")) |text_value| {
                    if (text_value == .string) {
                        try output.appendSlice(text_value.string);
                    }
                }
            },
            else => {},
        }
    }

    fn parseCompletionItems(self: *LSPClient, value: std.json.Value) ![]CompletionItem {
        return switch (value) {
            .null => self.allocator.alloc(CompletionItem, 0),
            .array => |array| try self.parseCompletionItemArray(array.items),
            .object => |obj| blk: {
                if (obj.get("items")) |items_value| {
                    if (items_value != .array) return error.InvalidResponse;
                    break :blk try self.parseCompletionItemArray(items_value.array.items);
                }

                const items = try self.allocator.alloc(CompletionItem, 1);
                errdefer self.allocator.free(items);
                items[0] = try self.parseCompletionItem(value);
                break :blk items;
            },
            else => error.InvalidResponse,
        };
    }

    fn parseCompletionItemArray(self: *LSPClient, values: []const std.json.Value) ![]CompletionItem {
        const items = try self.allocator.alloc(CompletionItem, values.len);
        errdefer self.freeCompletionItems(items, 0);

        for (values, 0..) |item_value, index| {
            items[index] = try self.parseCompletionItem(item_value);
        }

        return items;
    }

    fn parseCompletionItem(self: *LSPClient, value: std.json.Value) !CompletionItem {
        if (value != .object) return error.InvalidResponse;

        const label_value = value.object.get("label") orelse return error.InvalidResponse;
        if (label_value != .string) return error.InvalidResponse;

        const detail = if (value.object.get("detail")) |detail_value|
            try self.optionalStringFromValue(detail_value)
        else
            null;

        errdefer if (detail) |detail_text| self.allocator.free(detail_text);

        const documentation = if (value.object.get("documentation")) |documentation_value|
            try self.optionalMarkupStringFromValue(documentation_value)
        else
            null;

        errdefer if (documentation) |doc_text| self.allocator.free(doc_text);

        return .{
            .label = try self.allocator.dupe(u8, label_value.string),
            .kind = self.parseCompletionKind(value.object.get("kind")),
            .detail = detail,
            .documentation = documentation,
        };
    }

    fn parseDiagnosticsValue(self: *LSPClient, value: std.json.Value) ![]Diagnostic {
        if (value == .null) return try self.allocator.alloc(Diagnostic, 0);
        if (value != .array) return error.InvalidResponse;

        const diagnostics = try self.allocator.alloc(Diagnostic, value.array.items.len);
        errdefer self.freeDiagnosticsRange(diagnostics, 0);

        for (value.array.items, 0..) |item, index| {
            diagnostics[index] = try self.parseDiagnostic(item);
        }

        return diagnostics;
    }

    fn parseDiagnostic(self: *LSPClient, value: std.json.Value) !Diagnostic {
        if (value != .object) return error.InvalidResponse;

        const range_value = value.object.get("range") orelse return error.InvalidResponse;
        const message_value = value.object.get("message") orelse return error.InvalidResponse;
        if (message_value != .string) return error.InvalidResponse;

        return .{
            .range = try self.parseRange(range_value),
            .severity = self.parseSeverity(value.object.get("severity")),
            .message = try self.allocator.dupe(u8, message_value.string),
        };
    }

    fn optionalStringFromValue(self: *LSPClient, value: std.json.Value) !?[]const u8 {
        if (value == .null) return null;
        if (value != .string) return null;
        return try self.allocator.dupe(u8, value.string);
    }

    fn optionalMarkupStringFromValue(self: *LSPClient, value: std.json.Value) !?[]const u8 {
        return switch (value) {
            .null => null,
            .string => try self.allocator.dupe(u8, value.string),
            .object => |obj| blk: {
                if (obj.get("value")) |inner_value| {
                    if (inner_value == .string) {
                        break :blk try self.allocator.dupe(u8, inner_value.string);
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn parseCompletionKind(self: *LSPClient, value: ?std.json.Value) ?CompletionItemKind {
        _ = self;
        if (value) |kind_value| {
            if (kind_value == .integer and kind_value.integer > 0) {
                return std.meta.intToEnum(CompletionItemKind, @as(u32, @intCast(kind_value.integer))) catch null;
            }
        }
        return null;
    }

    fn parseSeverity(self: *LSPClient, value: ?std.json.Value) ?Severity {
        _ = self;
        if (value) |severity_value| {
            if (severity_value == .integer and severity_value.integer > 0) {
                return std.meta.intToEnum(Severity, @as(u32, @intCast(severity_value.integer))) catch null;
            }
        }
        return null;
    }

    fn responseMatchesId(self: *LSPClient, value: std.json.Value, expected_id: i64) bool {
        _ = self;
        return value == .integer and value.integer == expected_id;
    }

    fn printResponseError(self: *LSPClient, value: std.json.Value) void {
        _ = self;
        if (value != .object) return;
        if (value.object.get("message")) |message_value| {
            if (message_value == .string) {
                std.log.err("LSP error: {s}", .{message_value.string});
            }
        }
    }

    fn cloneDiagnostics(self: *LSPClient, diagnostics: []const Diagnostic) ![]Diagnostic {
        const cloned = try self.allocator.alloc(Diagnostic, diagnostics.len);
        errdefer self.freeDiagnosticsRange(cloned, 0);

        for (diagnostics, 0..) |diagnostic, index| {
            cloned[index] = .{
                .range = diagnostic.range,
                .severity = diagnostic.severity,
                .message = try self.allocator.dupe(u8, diagnostic.message),
            };
        }

        return cloned;
    }

    fn freeAllDiagnostics(self: *LSPClient) void {
        for (self.diagnostics.items) |entry| {
            self.allocator.free(entry.uri);
            self.freeDiagnosticsSlice(entry.diagnostics);
        }
    }

    fn freeLocations(self: *LSPClient, locations: []Location, initialized: usize) void {
        for (locations[0..initialized]) |location| {
            self.allocator.free(location.uri);
        }
        self.allocator.free(locations);
    }

    fn freeCompletionItems(self: *LSPClient, items: []CompletionItem, initialized: usize) void {
        for (items[0..initialized]) |item| {
            self.allocator.free(item.label);
            if (item.detail) |detail| self.allocator.free(detail);
            if (item.documentation) |documentation| self.allocator.free(documentation);
        }
        self.allocator.free(items);
    }

    fn freeDiagnosticsRange(self: *LSPClient, diagnostics: []Diagnostic, initialized: usize) void {
        for (diagnostics[0..initialized]) |diagnostic| {
            self.allocator.free(diagnostic.message);
        }
        self.allocator.free(diagnostics);
    }

    fn freeDiagnosticsSlice(self: *LSPClient, diagnostics: []Diagnostic) void {
        self.freeDiagnosticsRange(diagnostics, diagnostics.len);
    }
};

fn stringifyAllocCompat(allocator: Allocator, value: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

/// Get LSP server command for language
pub fn getLSPServer(language: []const u8) !struct { cmd: []const u8, args: []const []const u8 } {
    if (std.mem.eql(u8, language, "zig")) {
        return .{ .cmd = "zls", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "rust")) {
        return .{ .cmd = "rust-analyzer", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "go")) {
        return .{ .cmd = "gopls", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "javascript")) {
        return .{ .cmd = "typescript-language-server", .args = &[_][]const u8{"--stdio"} };
    }
    if (std.mem.eql(u8, language, "python")) {
        return .{ .cmd = "pylsp", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "java")) {
        return .{ .cmd = "jdtls", .args = &[_][]const u8{} };
    }

    return error.LSPServerNotFound;
}
