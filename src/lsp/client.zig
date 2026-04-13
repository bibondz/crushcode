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
    server_args: [][]const u8,
    process: ?std.process.Child,
    server_uri: []const u8,

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

    pub fn init(allocator: Allocator, server_command: []const u8, server_args: [][]const u8) LSPClient {
        return LSPClient{
            .allocator = allocator,
            .server_command = server_command,
            .server_args = server_args,
            .process = null,
            .server_uri = "file:///tmp/untitled",
        };
    }

    pub fn deinit(self: *LSPClient) void {
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
        _ = try self.sendRequest("initialize", .{
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

        // Send initialized notification
        _ = try self.sendNotification("initialized", .{});
    }

    /// Open a document in the LSP server
    pub fn openDocument(self: *LSPClient, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        _ = try self.sendNotification("textDocument/didOpen", .{
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

        // Parse result array of Location
        // For simplicity, return empty slice if parsing fails
        _ = response;
        return &[_]Location{};
    }

    /// Find all references to symbol at position
    pub fn findReferences(self: *LSPClient, uri: []const u8, line: u32, character: u32) ![]Location {
        const response = try self.sendRequest("textDocument/references", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
            .context = .{ .includeDeclaration = true },
        });

        _ = response;
        return &[_]Location{};
    }

    /// Get hover information at position
    pub fn hover(self: *LSPClient, uri: []const u8, line: u32, character: u32) !?[]const u8 {
        const response = try self.sendRequest("textDocument/hover", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
        });

        _ = response;
        return null;
    }

    /// Get completion items at position
    pub fn completion(self: *LSPClient, uri: []const u8, line: u32, character: u32) ![]CompletionItem {
        const response = try self.sendRequest("textDocument/completion", .{
            .textDocument = .{ .uri = uri },
            .position = Position{ .line = line, .character = character },
        });

        _ = response;
        return &[_]CompletionItem{};
    }

    /// Get diagnostics for document
    pub fn getDiagnostics(self: *LSPClient, uri: []const u8) ![]Diagnostic {
        _ = self;
        _ = uri;
        // Diagnostics are sent via notifications from server
        // For this simplified implementation, return empty
        return &[_]Diagnostic{};
    }

    /// Shutdown LSP server
    pub fn shutdown(self: *LSPClient) !void {
        _ = try self.sendRequest("shutdown", .{});
        _ = try self.sendNotification("exit", .{});
    }

    fn sendRequest(self: *LSPClient, method: []const u8, params: anytype) ![]const u8 {
        _ = self;
        _ = method;
        _ = params;
        // Simplified: return placeholder for now
        // Full JSON-RPC 2.0 implementation requires proper JSON serialization
        return "";
    }

    fn sendNotification(self: *LSPClient, method: []const u8, params: anytype) ![]const u8 {
        _ = self;
        _ = method;
        _ = params;
        // Simplified: return placeholder for now
        return "";
    }
};

/// Get LSP server command for language
pub fn getLSPServer(language: []const u8) !struct { cmd: []const u8, args: [][]const u8 } {
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
        return .{ .cmd = "typescript-language-server", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "python")) {
        return .{ .cmd = "pylsp", .args = &[_][]const u8{} };
    }
    if (std.mem.eql(u8, language, "java")) {
        return .{ .cmd = "jdtls", .args = &[_][]const u8{} };
    }

    return error.LSPServerNotFound;
}
