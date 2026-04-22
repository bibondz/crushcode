const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A dynamic command loaded from a .md file in config directories.
/// These extend the built-in slash commands with user/project-defined commands.
pub const DynamicCommand = struct {
    allocator: Allocator,
    /// Command name (e.g., "explain" → /explain)
    name: []const u8,
    /// Short description from frontmatter
    description: []const u8,
    /// Which agent type to use (default "build")
    agent: []const u8,
    /// Optional model override
    model: []const u8,
    /// Whether to run as subtask (default false)
    subtask: bool,
    /// The command template body (after frontmatter)
    template: []const u8,
    /// Where the file was loaded from (for diagnostics)
    source_path: []const u8,

    pub fn deinit(self: *DynamicCommand) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.agent);
        self.allocator.free(self.model);
        self.allocator.free(self.template);
        self.allocator.free(self.source_path);
    }
};

/// Registry for dynamic commands discovered from .md files.
/// Searches in order:
///   1. .crushcode/commands/ (project-local)
///   2. ~/.config/crushcode/commands/ (user-global)
pub const DynamicCommandRegistry = struct {
    allocator: Allocator,
    commands: array_list_compat.ArrayList(DynamicCommand),
    initialized: bool,

    pub fn init(allocator: Allocator) DynamicCommandRegistry {
        return DynamicCommandRegistry{
            .allocator = allocator,
            .commands = array_list_compat.ArrayList(DynamicCommand).init(allocator),
            .initialized = false,
        };
    }

    pub fn deinit(self: *DynamicCommandRegistry) void {
        for (self.commands.items) |*cmd| {
            cmd.deinit();
        }
        self.commands.deinit();
    }

    /// Walk directory for *.md files and parse each as a dynamic command.
    pub fn loadFromDirectory(self: *DynamicCommandRegistry, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const basename = entry.basename;
            // Only process .md files, skip SKILL.md and *.skill.md
            if (!std.mem.endsWith(u8, basename, ".md")) continue;
            if (std.mem.eql(u8, basename, "SKILL.md") or
                std.mem.endsWith(u8, basename, ".skill.md")) continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
            errdefer self.allocator.free(full_path);

            const cmd = self.parseCommandFile(full_path) catch |err| {
                std.log.warn("Failed to parse command {s}: {}", .{ full_path, err });
                self.allocator.free(full_path);
                continue;
            };

            try self.commands.append(cmd);
        }

        self.initialized = true;
    }

    /// Parse a single .md command file.
    fn parseCommandFile(self: *DynamicCommandRegistry, path: []const u8) !DynamicCommand {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return error.EmptyFile;

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read == 0) return error.EmptyFile;

        const content = buffer[0..bytes_read];

        var cmd = DynamicCommand{
            .allocator = self.allocator,
            .name = "",
            .description = "",
            .agent = "",
            .model = "",
            .subtask = false,
            .template = "",
            .source_path = try self.allocator.dupe(u8, path),
        };

        // Try to split frontmatter
        const split = splitCommandFrontmatter(content);

        if (split.yaml.len > 0) {
            self.parseCommandYaml(split.yaml, &cmd) catch {};
        }

        // Template is the body after frontmatter
        if (split.body.len > 0) {
            cmd.template = try self.allocator.dupe(u8, std.mem.trim(u8, split.body, " \t\r\n"));
        }

        // Derive name from filename if not in frontmatter
        if (cmd.name.len == 0) {
            const basename = std.fs.path.basename(path);
            if (std.mem.endsWith(u8, basename, ".md")) {
                cmd.name = try self.allocator.dupe(u8, basename[0 .. basename.len - ".md".len]);
            } else {
                cmd.name = try self.allocator.dupe(u8, basename);
            }
        }

        // Default agent
        if (cmd.agent.len == 0) {
            cmd.agent = try self.allocator.dupe(u8, "build");
        }

        return cmd;
    }

    /// Parse simple YAML key: value pairs for command frontmatter.
    fn parseCommandYaml(self: *DynamicCommandRegistry, yaml: []const u8, cmd: *DynamicCommand) !void {
        var line_iter = std.mem.splitScalar(u8, yaml, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\"'");
                if (value.len == 0) continue;

                if (std.mem.eql(u8, key, "name")) {
                    cmd.name = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    cmd.description = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "agent")) {
                    cmd.agent = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "model")) {
                    cmd.model = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "subtask")) {
                    cmd.subtask = std.mem.eql(u8, value, "true") or
                        std.mem.eql(u8, value, "yes") or
                        std.mem.eql(u8, value, "1");
                }
            }
        }
    }

    /// Find a command by name.
    pub fn getCommand(self: *DynamicCommandRegistry, name: []const u8) ?DynamicCommand {
        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) {
                return cmd;
            }
        }
        return null;
    }

    /// List all loaded dynamic commands.
    pub fn listCommands(self: *DynamicCommandRegistry) []DynamicCommand {
        return self.commands.items;
    }

    /// Process a command template by substituting variables.
    /// Supports:
    ///   - $ARGUMENTS — replaced with user's arguments
    ///   - $1, $2, etc. — positional parameters (split args on spaces)
    ///   - !`command` — shell execution (inline output)
    ///   - @filepath — file reference (inline file content)
    pub fn processTemplate(self: *DynamicCommandRegistry, template: []const u8, args: []const u8) ![]const u8 {
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // First pass: replace $ARGUMENTS and $N positional params
        const processed = try self.replaceVariables(template, args);
        defer self.allocator.free(processed);

        // Second pass: process @filepath references
        const file_processed = try self.processFileReferences(processed);
        defer self.allocator.free(file_processed);

        // Third pass: process !`command` shell execution blocks
        const shell_processed = try self.processShellBlocks(file_processed);
        defer self.allocator.free(shell_processed);

        try output.appendSlice(shell_processed);
        return output.toOwnedSlice();
    }

    /// Replace $ARGUMENTS with args, $1/$2/etc with positional params.
    fn replaceVariables(self: *DynamicCommandRegistry, template: []const u8, args: []const u8) ![]const u8 {
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        // Pre-split args for positional params
        var positionals = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (positionals.items) |p| self.allocator.free(p);
            positionals.deinit();
        }
        var arg_iter = std.mem.splitScalar(u8, args, ' ');
        while (arg_iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) {
                try positionals.append(try self.allocator.dupe(u8, trimmed));
            }
        }

        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '$') {
                // Check for $ARGUMENTS
                if (std.mem.startsWith(u8, template[i..], "$ARGUMENTS")) {
                    try result.appendSlice(args);
                    i += "$ARGUMENTS".len;
                    continue;
                }

                // Check for $N positional params
                if (i + 1 < template.len and template[i + 1] >= '0' and template[i + 1] <= '9') {
                    const digit = template[i + 1] - '0';
                    // Check for double-digit (e.g., $10)
                    var num: usize = digit;
                    var digit_end = i + 2;
                    while (digit_end < template.len and template[digit_end] >= '0' and template[digit_end] <= '9') {
                        num = num * 10 + (template[digit_end] - '0');
                        digit_end += 1;
                    }

                    if (num > 0 and num <= positionals.items.len) {
                        try result.appendSlice(positionals.items[num - 1]);
                    }
                    i = digit_end;
                    continue;
                }
            }

            try result.append(template[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }

    /// Process @filepath references — replace with file content.
    fn processFileReferences(self: *DynamicCommandRegistry, template: []const u8) ![]const u8 {
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '@') {
                // Collect filepath (until whitespace or end)
                var end = i + 1;
                while (end < template.len and template[end] != ' ' and template[end] != '\t' and template[end] != '\n' and template[end] != '\r') {
                    end += 1;
                }

                if (end > i + 1) {
                    const filepath = template[i + 1 .. end];
                    // Try to read the file
                    if (std.fs.cwd().openFile(filepath, .{})) |file| {
                        defer file.close();
                        if (file.getEndPos()) |size| {
                            if (size > 0 and size < 1024 * 1024) { // 1MB limit
                                const buf = try self.allocator.alloc(u8, size);
                                defer self.allocator.free(buf);
                                if (file.readAll(buf)) |bytes_read| {
                                    try result.appendSlice(buf[0..bytes_read]);
                                } else |_| {
                                    // Can't read, keep the @filepath as-is
                                    try result.appendSlice(template[i..end]);
                                }
                            } else {
                                try result.appendSlice(template[i..end]);
                            }
                        } else |_| {
                            try result.appendSlice(template[i..end]);
                        }
                    } else |_| {
                        // File not found, keep the @filepath as-is
                        try result.appendSlice(template[i..end]);
                    }
                    i = end;
                    continue;
                }
            }

            try result.append(template[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }

    /// Process !`command` shell execution blocks — replace with command output.
    fn processShellBlocks(self: *DynamicCommandRegistry, template: []const u8) ![]const u8 {
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < template.len) {
            // Look for !` pattern
            if (template[i] == '!' and i + 1 < template.len and template[i + 1] == '`') {
                // Find closing backtick
                const cmd_start = i + 2;
                if (std.mem.indexOfScalarPos(u8, template, cmd_start, '`')) |close_pos| {
                    const command = template[cmd_start..close_pos];

                    // Execute the command
                    const shell_output = self.executeShellCommand(command) catch "(command failed)";
                    try result.appendSlice(shell_output);

                    i = close_pos + 1;
                    continue;
                }
            }

            try result.append(template[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }

    /// Execute a shell command and return its output.
    fn executeShellCommand(self: *DynamicCommandRegistry, command: []const u8) ![]const u8 {
        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", command }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        const result = try child.spawnAndWait();
        _ = result;

        // Read stdout
        if (child.stdout) |stdout| {
            const output = stdout.readToEndAlloc(self.allocator, 64 * 1024) catch
                return try self.allocator.dupe(u8, "(read failed)");
            return std.mem.trimRight(u8, output, " \t\r\n");
        }

        return try self.allocator.dupe(u8, "");
    }
};

/// Split YAML frontmatter from command markdown body.
fn splitCommandFrontmatter(content: []const u8) struct { yaml: []const u8, body: []const u8 } {
    if (content.len < 4 or !std.mem.startsWith(u8, content, "---")) {
        return .{ .yaml = "", .body = content };
    }

    const after_first = content[3..];
    const closing = std.mem.indexOf(u8, after_first, "\n---") orelse
        return .{ .yaml = "", .body = content };

    const yaml_content = std.mem.trim(u8, after_first[0..closing], " \t\r\n");
    const body_start = closing + 4;
    const body = if (body_start < content.len)
        std.mem.trim(u8, content[body_start..], " \t\r\n")
    else
        "";

    return .{ .yaml = yaml_content, .body = body };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "DynamicCommandRegistry - init and deinit" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expect(!registry.initialized);
    try testing.expectEqual(@as(usize, 0), registry.listCommands().len);
}

test "DynamicCommandRegistry - getCommand returns null for empty" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expect(registry.getCommand("nonexistent") == null);
}

test "DynamicCommandRegistry - parseCommandYaml" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var cmd = DynamicCommand{
        .allocator = testing.allocator,
        .name = "",
        .description = "",
        .agent = "",
        .model = "",
        .subtask = false,
        .template = "",
        .source_path = "test.md",
    };

    const yaml =
        \\name: explain
        \\description: Explain code
        \\agent: oracle
        \\model: claude-3.5
        \\subtask: true
    ;

    try registry.parseCommandYaml(yaml, &cmd);
    defer {
        var mut = cmd;
        mut.deinit();
    }

    try testing.expectEqualStrings("explain", cmd.name);
    try testing.expectEqualStrings("Explain code", cmd.description);
    try testing.expectEqualStrings("oracle", cmd.agent);
    try testing.expectEqualStrings("claude-3.5", cmd.model);
    try testing.expect(cmd.subtask);
}

test "splitCommandFrontmatter - with YAML" {
    const content =
        \\---
        \\name: commit
        \\description: Generate commit
        \\---
        \\Analyze the diff and commit. $ARGUMENTS
    ;

    const result = splitCommandFrontmatter(content);
    try testing.expect(result.yaml.len > 0);
    try testing.expect(result.body.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.yaml, "name: commit") != null);
    try testing.expect(std.mem.startsWith(u8, result.body, "Analyze the diff"));
}

test "splitCommandFrontmatter - no YAML" {
    const content = "Just a template body without frontmatter.";

    const result = splitCommandFrontmatter(content);
    try testing.expect(result.yaml.len == 0);
    try testing.expect(std.mem.eql(u8, result.body, content));
}

test "DynamicCommandRegistry - replaceVariables" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    const template = "Hello $ARGUMENTS, first=$1 second=$2";
    const result = try registry.replaceVariables(template, "world foo bar");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("Hello world foo bar, first=world second=foo", result);
}

test "DynamicCommandRegistry - replaceVariables no match" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    const template = "No variables here.";
    const result = try registry.replaceVariables(template, "args");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("No variables here.", result);
}

test "DynamicCommandRegistry - processFileReferences no refs" {
    var registry = DynamicCommandRegistry.init(testing.allocator);
    defer registry.deinit();

    const template = "No file references.";
    const result = try registry.processFileReferences(template);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("No file references.", result);
}
