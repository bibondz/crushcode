const std = @import("std");
const lsp = @import("lsp");

const Allocator = std.mem.Allocator;

/// Per-file diagnostic summary for the TUI sidebar
pub const FileDiagnostics = struct {
    file_path: []const u8, // owned
    uri: []const u8, // owned
    errors: u32,
    warnings: u32,
    infos: u32,
    top_messages: [3]?DiagnosticInfo,

    pub const DiagnosticInfo = struct {
        severity: lsp.LSPClient.Severity,
        line: u32,
        message: []const u8, // owned
    };

    pub fn deinit(self: *FileDiagnostics, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.uri);
        for (&self.top_messages) |*msg| {
            if (msg.*) |*m| {
                allocator.free(m.message);
                msg.* = null;
            }
        }
    }
};

/// Wraps one LSP client instance for a specific language
const LanguageServer = struct {
    client: lsp.LSPClient,
    language: []const u8, // owned
    started: bool,

    fn deinit(self: *LanguageServer, allocator: Allocator) void {
        if (self.started) {
            self.client.shutdown() catch {};
            self.started = false;
        }
        self.client.deinit();
        allocator.free(self.language);
    }
};

/// High-level LSP manager for the TUI context.
/// Manages one LSP server per language, auto-detects language from file extension,
/// and provides diagnostic summaries for the sidebar.
pub const LSPManager = struct {
    allocator: Allocator,
    servers: std.ArrayList(LanguageServer),
    file_diagnostics: std.ArrayList(FileDiagnostics),
    workspace_uri: []const u8, // owned
    enabled: bool,

    pub fn init(allocator: Allocator) LSPManager {
        return .{
            .allocator = allocator,
            .servers = std.ArrayList(LanguageServer).empty,
            .file_diagnostics = std.ArrayList(FileDiagnostics).empty,
            .workspace_uri = "",
            .enabled = true,
        };
    }

    pub fn deinit(self: *LSPManager) void {
        for (self.file_diagnostics.items) |*fd| {
            fd.deinit(self.allocator);
        }
        self.file_diagnostics.deinit(self.allocator);
        for (self.servers.items) |*server| {
            server.deinit(self.allocator);
        }
        self.servers.deinit(self.allocator);
        if (self.workspace_uri.len > 0) {
            self.allocator.free(self.workspace_uri);
            self.workspace_uri = "";
        }
    }

    pub fn setWorkspaceUri(self: *LSPManager, workspace_path: []const u8) void {
        if (self.workspace_uri.len > 0) {
            self.allocator.free(self.workspace_uri);
        }
        self.workspace_uri = absolutePathToFileUri(self.allocator, workspace_path) catch "file:///tmp";
    }

    /// Get all file diagnostics for sidebar display
    pub fn getDiagnostics(self: *const LSPManager) []const FileDiagnostics {
        return self.file_diagnostics.items;
    }

    /// Called when a file is opened/edited. Auto-detects language, starts LSP server if needed,
    /// opens the document, and fetches diagnostics.
    /// Errors are logged but never propagated — the TUI must continue working.
    pub fn onFileOpened(self: *LSPManager, file_path: []const u8) void {
        if (!self.enabled) return;

        const language = detectLanguage(file_path) orelse return;

        // Find or create server for this language
        const server_index = self.findOrCreateServer(language) catch |err| {
            std.log.warn("LSP: failed to start server for {s}: {}", .{ language, err });
            return;
        };

        const server = &self.servers.items[server_index];
        if (!server.started) return;

        // Open the document
        const uri = pathToFileUri(self.allocator, file_path) catch |err| {
            std.log.warn("LSP: failed to create URI for {s}: {}", .{ file_path, err });
            return;
        };
        errdefer self.allocator.free(uri);

        const content = readFileContent(self.allocator, file_path) catch |err| {
            std.log.warn("LSP: failed to read {s}: {}", .{ file_path, err });
            self.allocator.free(uri);
            return;
        };
        defer self.allocator.free(content);

        server.client.openDocument(uri, language, content) catch |err| {
            std.log.warn("LSP: failed to open document {s}: {}", .{ file_path, err });
            self.allocator.free(uri);
            return;
        };

        // Fetch diagnostics
        const diagnostics = server.client.getDiagnostics(uri) catch |err| {
            std.log.warn("LSP: failed to get diagnostics for {s}: {}", .{ file_path, err });
            self.allocator.free(uri);
            return;
        };

        self.updateFileDiagnostics(file_path, uri, diagnostics) catch |err| {
            std.log.warn("LSP: failed to update diagnostics: {}", .{err});
            // Free diagnostics since we didn't store them
            for (diagnostics) |d| self.allocator.free(d.message);
            self.allocator.free(diagnostics);
            self.allocator.free(uri);
            return;
        };
        // Ownership transferred to updateFileDiagnostics on success
    }

    /// Refresh diagnostics for all tracked files by polling LSP servers.
    /// Lightweight — only polls already-opened files.
    pub fn refreshDiagnostics(self: *LSPManager) void {
        if (!self.enabled) return;

        // Drain notifications from all active servers first
        for (self.servers.items) |*server| {
            if (server.started) {
                server.client.drainNotifications(0) catch {};
            }
        }

        // Re-poll diagnostics for each tracked file
        var i: usize = 0;
        while (i < self.file_diagnostics.items.len) {
            const fd = &self.file_diagnostics.items[i];

            // Find the server for this file's language
            const language = detectLanguage(fd.file_path) orelse {
                i += 1;
                continue;
            };
            const server_index = self.findServerIndex(language) orelse {
                i += 1;
                continue;
            };
            const server = &self.servers.items[server_index];
            if (!server.started) {
                i += 1;
                continue;
            }

            const diagnostics = server.client.getDiagnostics(fd.uri) catch {
                i += 1;
                continue;
            };

            // Count severities
            var errors: u32 = 0;
            var warnings: u32 = 0;
            var infos: u32 = 0;
            var top_messages: [3]?FileDiagnostics.DiagnosticInfo = .{ null, null, null };

            for (diagnostics, 0..) |d, idx| {
                const sev = d.severity orelse .information;
                switch (sev) {
                    .@"error" => errors += 1,
                    .warning => warnings += 1,
                    .information, .hint => infos += 1,
                }
                if (idx < 3) {
                    top_messages[idx] = .{
                        .severity = sev,
                        .line = d.range.start.line + 1,
                        .message = self.allocator.dupe(u8, d.message) catch "",
                    };
                }
            }

            // Free old top messages
            for (&fd.top_messages) |*msg| {
                if (msg.*) |*m| {
                    self.allocator.free(m.message);
                    msg.* = null;
                }
            }

            fd.errors = errors;
            fd.warnings = warnings;
            fd.infos = infos;
            fd.top_messages = top_messages;

            // Free diagnostics returned by getDiagnostics
            for (diagnostics) |d| self.allocator.free(d.message);
            self.allocator.free(diagnostics);

            i += 1;
        }
    }

    pub fn totalErrors(self: *const LSPManager) u32 {
        var total: u32 = 0;
        for (self.file_diagnostics.items) |fd| {
            total += fd.errors;
        }
        return total;
    }

    pub fn totalWarnings(self: *const LSPManager) u32 {
        var total: u32 = 0;
        for (self.file_diagnostics.items) |fd| {
            total += fd.warnings;
        }
        return total;
    }

    pub fn getDiagnosticsSummary(self: *const LSPManager) []const FileDiagnostics {
        return self.file_diagnostics.items;
    }

    /// Find all references to the symbol at the given position in the file.
    /// Returns an owned slice of Location — caller must free each `.uri` and the slice.
    /// Errors are logged but never propagated (returns null on failure).
    pub fn findReferences(self: *LSPManager, file_path: []const u8, line: u32, character: u32) ?[]lsp.LSPClient.Location {
        if (!self.enabled) return null;

        const language = detectLanguage(file_path) orelse return null;
        const server_index = self.findServerIndex(language) orelse return null;
        const server = &self.servers.items[server_index];
        if (!server.started) return null;

        const uri = pathToFileUri(self.allocator, file_path) catch return null;
        defer self.allocator.free(uri);

        return server.client.findReferences(uri, line, character) catch |err| {
            std.log.warn("LSP: findReferences failed for {s}: {}", .{ file_path, err });
            return null;
        };
    }

    // --- Private methods ---

    fn findOrCreateServer(self: *LSPManager, language: []const u8) !usize {
        // Check if we already have a server for this language
        if (self.findServerIndex(language)) |idx| return idx;

        // Get LSP server config for this language
        const server_config = lsp.getLSPServer(language) catch |err| {
            std.log.warn("LSP: no server for language '{s}': {}", .{ language, err });
            return err;
        };

        // Create new LSP client
        var client = lsp.LSPClient.init(self.allocator, server_config.cmd, server_config.args);
        if (self.workspace_uri.len > 0) {
            client.server_uri = self.workspace_uri;
        }

        // Start the server
        client.start() catch |err| {
            std.log.warn("LSP: failed to start server for {s}: {}", .{ language, err });
            client.deinit();
            return err;
        };

        const language_owned = try self.allocator.dupe(u8, language);
        errdefer self.allocator.free(language_owned);

        try self.servers.append(self.allocator, .{
            .client = client,
            .language = language_owned,
            .started = true,
        });

        return self.servers.items.len - 1;
    }

    fn findServerIndex(self: *const LSPManager, language: []const u8) ?usize {
        for (self.servers.items, 0..) |server, i| {
            if (std.mem.eql(u8, server.language, language)) return i;
        }
        return null;
    }

    fn updateFileDiagnostics(self: *LSPManager, file_path: []const u8, uri: []const u8, diagnostics: []lsp.LSPClient.Diagnostic) !void {
        // Check if file already tracked
        for (self.file_diagnostics.items) |*fd| {
            if (std.mem.eql(u8, fd.file_path, file_path)) {
                // Free old top messages
                for (&fd.top_messages) |*msg| {
                    if (msg.*) |*m| {
                        self.allocator.free(m.message);
                        msg.* = null;
                    }
                }
                // Free old uri, replace with new one
                self.allocator.free(fd.uri);
                fd.uri = uri;

                // Count severities
                fd.errors = 0;
                fd.warnings = 0;
                fd.infos = 0;
                for (diagnostics, 0..) |d, idx| {
                    const sev = d.severity orelse .information;
                    switch (sev) {
                        .@"error" => fd.errors += 1,
                        .warning => fd.warnings += 1,
                        .information, .hint => fd.infos += 1,
                    }
                    if (idx < 3) {
                        fd.top_messages[idx] = .{
                            .severity = sev,
                            .line = d.range.start.line + 1,
                            .message = try self.allocator.dupe(u8, d.message),
                        };
                    }
                }

                // Free diagnostics returned by getDiagnostics
                for (diagnostics) |d| self.allocator.free(d.message);
                self.allocator.free(diagnostics);

                return;
            }
        }

        // New file entry
        var fd = FileDiagnostics{
            .file_path = try self.allocator.dupe(u8, file_path),
            .uri = uri, // take ownership
            .errors = 0,
            .warnings = 0,
            .infos = 0,
            .top_messages = .{ null, null, null },
        };

        for (diagnostics, 0..) |d, idx| {
            const sev = d.severity orelse .information;
            switch (sev) {
                .@"error" => fd.errors += 1,
                .warning => fd.warnings += 1,
                .information, .hint => fd.infos += 1,
            }
            if (idx < 3) {
                fd.top_messages[idx] = .{
                    .severity = sev,
                    .line = d.range.start.line + 1,
                    .message = try self.allocator.dupe(u8, d.message),
                };
            }
        }

        // Free diagnostics returned by getDiagnostics
        for (diagnostics) |d| self.allocator.free(d.message);
        self.allocator.free(diagnostics);

        try self.file_diagnostics.append(self.allocator, fd);
    }
};

// --- Helper functions (reimplemented from lsp_handler.zig patterns) ---

fn detectLanguage(file_path: []const u8) ?[]const u8 {
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

fn pathToFileUri(allocator: Allocator, file_path: []const u8) ![]const u8 {
    const absolute_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(absolute_path);
    return absolutePathToFileUri(allocator, absolute_path);
}

fn absolutePathToFileUri(allocator: Allocator, absolute_path: []const u8) ![]const u8 {
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

fn readFileContent(allocator: Allocator, file_path: []const u8) ![]const u8 {
    return try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
}
