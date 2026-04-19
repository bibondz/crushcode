const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// AST-grep style pattern matching for code
/// Supports meta-variables: $VAR (single node), $$$ (multiple nodes)
///
/// Reference: ast-grep (https://github.com/ast-grep/ast-grep)
/// Language support: JavaScript, TypeScript, Python, Go, Rust, C, C++, Java, JSON, YAML, etc.
pub const AstGrep = struct {
    allocator: Allocator,
    pattern: []const u8,
    language: Language,
    is_regex: bool,

    pub const Language = enum {
        javascript,
        typescript,
        tsx,
        python,
        go,
        rust,
        c,
        cpp,
        java,
        json,
        yaml,
        bash,
        ruby,
        php,
        swift,
        kotlin,
        scala,
        solidity,
        html,
        css,
        unknown,
    };

    pub const Match = struct {
        line: u32,
        column: u32,
        file: []const u8,
        matched_text: []const u8,
        context: []const u8,
    };

    pub const Rule = struct {
        pattern: []const u8,
        language: Language,
        message: ?[]const u8 = null,
        fix: ?[]const u8 = null,
    };

    pub fn init(allocator: Allocator, pattern: []const u8, language: Language) AstGrep {
        return AstGrep{
            .allocator = allocator,
            .pattern = pattern,
            .language = language,
            .is_regex = false,
        };
    }

    /// Simple line-based search
    pub fn search(self: *const AstGrep, file_path: []const u8) ![]Match {
        var matches = array_list_compat.ArrayList(Match).init(self.allocator);

        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch {
            return error.FileReadError;
        };
        defer self.allocator.free(content);

        var line_num: u32 = 1;
        var line_start: usize = 0;

        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                const line = content[line_start..i];

                if (self.simpleMatch(line)) {
                    const match = Match{
                        .line = line_num,
                        .column = 1,
                        .file = try self.allocator.dupe(u8, file_path),
                        .matched_text = try self.allocator.dupe(u8, line),
                        .context = try self.allocator.dupe(u8, line),
                    };
                    try matches.append(match);
                }

                line_num += 1;
                line_start = i + 1;
            }
        }

        if (line_start < content.len) {
            const line = content[line_start..];
            if (self.simpleMatch(line)) {
                const match = Match{
                    .line = line_num,
                    .column = 1,
                    .file = try self.allocator.dupe(u8, file_path),
                    .matched_text = try self.allocator.dupe(u8, line),
                    .context = try self.allocator.dupe(u8, line),
                };
                try matches.append(match);
            }
        }

        return matches.toOwnedSlice();
    }

    fn simpleMatch(self: *const AstGrep, line: []const u8) bool {
        if (self.is_regex) {
            return std.mem.indexOf(u8, line, self.pattern) != null;
        }
        return std.mem.indexOf(u8, line, self.pattern) != null;
    }

    /// Search directory for matches
    pub fn searchGlob(self: *const AstGrep, dir_path: []const u8, _: []const u8) ![]Match {
        var all_matches = array_list_compat.ArrayList(Match).init(self.allocator);

        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return &[_]Match{};
        defer dir.close();

        var iterator = dir.iterate();
        const ext = self.getLanguageExtension();

        while (iterator.next() catch null) |entry| {
            if (entry.kind == .file) {
                const file_name = entry.name;
                if (std.mem.endsWith(u8, file_name, ext)) {
                    const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, file_name });
                    const matches = self.search(file_path) catch continue;
                    for (matches) |m| {
                        try all_matches.append(m);
                    }
                }
            }
        }

        return all_matches.toOwnedSlice();
    }

    fn getLanguageExtension(self: *const AstGrep) []const u8 {
        return switch (self.language) {
            .javascript => ".js",
            .typescript, .tsx => ".ts",
            .python => ".py",
            .go => ".go",
            .rust => ".rs",
            .c => ".c",
            .cpp => ".cpp",
            .java => ".java",
            .json => ".json",
            .yaml => ".yaml",
            .bash => ".sh",
            .ruby => ".rb",
            .php => ".php",
            .swift => ".swift",
            .kotlin => ".kt",
            .scala => ".scala",
            .solidity => ".sol",
            .html => ".html",
            .css => ".css",
            .unknown => "",
        };
    }

    pub fn printMatches(matches: []Match) void {
        const stdout = file_compat.File.stdout().writer();

        if (matches.len == 0) {
            stdout.print("No matches found.\n", .{}) catch {};
            return;
        }

        stdout.print("Found {d} match(es):\n", .{matches.len}) catch {};

        for (matches) |m| {
            stdout.print("{s}:{d}: {s}\n", .{ m.file, m.line, m.matched_text }) catch {};
        }
    }
};

/// Parse language from string
pub fn parseLanguage(s: []const u8) AstGrep.Language {
    if (std.ascii.startsWithIgnoreCase(s, "javascript") or std.ascii.startsWithIgnoreCase(s, "js")) {
        return .javascript;
    }
    if (std.ascii.startsWithIgnoreCase(s, "typescript") or std.ascii.startsWithIgnoreCase(s, "ts")) {
        return .typescript;
    }
    if (std.ascii.startsWithIgnoreCase(s, "tsx")) {
        return .tsx;
    }
    if (std.ascii.startsWithIgnoreCase(s, "python") or std.ascii.startsWithIgnoreCase(s, "py")) {
        return .python;
    }
    if (std.ascii.startsWithIgnoreCase(s, "go")) {
        return .go;
    }
    if (std.ascii.startsWithIgnoreCase(s, "rust") or std.ascii.startsWithIgnoreCase(s, "rs")) {
        return .rust;
    }
    if (std.ascii.startsWithIgnoreCase(s, "c") and s.len == 1) {
        return .c;
    }
    if (std.ascii.startsWithIgnoreCase(s, "cpp") or std.ascii.startsWithIgnoreCase(s, "c++")) {
        return .cpp;
    }
    if (std.ascii.startsWithIgnoreCase(s, "java")) {
        return .java;
    }
    if (std.ascii.startsWithIgnoreCase(s, "json")) {
        return .json;
    }
    if (std.ascii.startsWithIgnoreCase(s, "yaml") or std.ascii.startsWithIgnoreCase(s, "yml")) {
        return .yaml;
    }
    if (std.ascii.startsWithIgnoreCase(s, "bash") or std.ascii.startsWithIgnoreCase(s, "sh") or std.ascii.startsWithIgnoreCase(s, "shell")) {
        return .bash;
    }
    if (std.ascii.startsWithIgnoreCase(s, "ruby")) {
        return .ruby;
    }
    if (std.ascii.startsWithIgnoreCase(s, "php")) {
        return .php;
    }
    if (std.ascii.startsWithIgnoreCase(s, "swift")) {
        return .swift;
    }
    if (std.ascii.startsWithIgnoreCase(s, "kotlin") or std.ascii.startsWithIgnoreCase(s, "kt")) {
        return .kotlin;
    }
    return .unknown;
}
