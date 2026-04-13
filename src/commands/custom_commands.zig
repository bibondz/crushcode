const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A custom command loaded from a Markdown file.
/// Users define custom slash commands (e.g., /deploy, /test) via .md files
/// in a commands/ directory with YAML frontmatter.
///
/// Example file (commands/deploy.md):
/// ```md
/// ---
/// name: deploy
/// description: Deploy the current project to staging
/// args: env
/// model: null
/// ---
/// Deploy the project to {{env}} environment. Run tests first, then build and deploy.
/// ```
///
/// Reference: OpenCode interactive slash commands (F16/F15)
pub const CustomCommand = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    /// Expected argument names (comma-separated in frontmatter)
    arg_names: [][]const u8,
    /// Override model for this command (null = use default)
    model: ?[]const u8,
    /// The prompt template body (supports {{arg_name}} substitution)
    template: []const u8,
    /// Source file path
    file_path: []const u8,

    pub fn deinit(self: *CustomCommand) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.template);
        self.allocator.free(self.file_path);
        if (self.model) |m| self.allocator.free(m);
        for (self.arg_names) |a| self.allocator.free(a);
        self.allocator.free(self.arg_names);
    }

    /// Render the template with provided argument values.
    /// Args should be in the same order as arg_names.
    pub fn render(self: *const CustomCommand, allocator: Allocator, args: []const []const u8) ![]const u8 {
        var result = array_list_compat.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        const writer = result.writer();

        var pos: usize = 0;
        const tmpl = self.template;

        while (pos < tmpl.len) {
            // Look for {{placeholder}}
            if (pos + 3 < tmpl.len and tmpl[pos] == '{' and tmpl[pos + 1] == '{') {
                const end = std.mem.indexOfScalarPos(u8, tmpl, pos + 2, '}') orelse {
                    try writer.writeByte(tmpl[pos]);
                    pos += 1;
                    continue;
                };
                // Check for closing }}
                if (end + 1 < tmpl.len and tmpl[end + 1] == '}') {
                    const placeholder = std.mem.trim(u8, tmpl[pos + 2 .. end], " \t");
                    // Find matching arg
                    const rendered = self.renderArg(placeholder, args);
                    try writer.writeAll(rendered);
                    pos = end + 2;
                    continue;
                }
            }
            try writer.writeByte(tmpl[pos]);
            pos += 1;
        }

        return result.toOwnedSlice();
    }

    fn renderArg(self: *const CustomCommand, placeholder: []const u8, args: []const []const u8) []const u8 {
        // Special: {{args}} = all args joined
        if (std.mem.eql(u8, placeholder, "args")) {
            // Return first arg if only one, or concatenate
            if (args.len == 0) return "";
            if (args.len == 1) return args[0];
            return args[0]; // Simplified: return first for now
        }

        // Match against arg_names
        for (self.arg_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, placeholder)) {
                if (i < args.len) return args[i];
                return "";
            }
        }
        return "";
    }
};

/// Loader for custom commands from Markdown files
pub const CustomCommandLoader = struct {
    allocator: Allocator,
    commands: array_list_compat.ArrayList(CustomCommand),

    pub fn init(allocator: Allocator) CustomCommandLoader {
        return CustomCommandLoader{
            .allocator = allocator,
            .commands = array_list_compat.ArrayList(CustomCommand).init(allocator),
        };
    }

    pub fn deinit(self: *CustomCommandLoader) void {
        for (self.commands.items) |*cmd| {
            cmd.deinit();
        }
        self.commands.deinit();
    }

    /// Load custom commands from a directory.
    /// Looks for .md files and parses them as custom command definitions.
    pub fn loadFromDirectory(self: *CustomCommandLoader, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // No commands dir is fine
            else => return err,
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".md")) continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
            errdefer self.allocator.free(full_path);

            const cmd = self.parseCommandFile(full_path) catch |err| {
                if (@import("builtin").mode == .Debug) {
                    const stderr = file_compat.File.stderr().writer();
                    stderr.print("Warning: Failed to parse command {s}: {}\n", .{ full_path, err }) catch {};
                }
                self.allocator.free(full_path);
                continue;
            };

            try self.commands.append(cmd);
        }
    }

    /// Find a command by name (without the leading /)
    pub fn findCommand(self: *CustomCommandLoader, name: []const u8) ?*const CustomCommand {
        // Strip leading / if present
        const lookup = if (name.len > 0 and name[0] == '/') name[1..] else name;

        for (self.commands.items) |*cmd| {
            if (std.mem.eql(u8, cmd.name, lookup)) {
                return cmd;
            }
        }
        return null;
    }

    /// List all loaded command names
    pub fn listNames(self: *CustomCommandLoader) []const []const u8 {
        var names = array_list_compat.ArrayList([]const u8).init(self.allocator);
        for (self.commands.items) |cmd| {
            names.append(cmd.name) catch {};
        }
        return names.items;
    }

    /// Print loaded commands summary
    pub fn printSummary(self: *CustomCommandLoader) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("Loaded {} custom commands:\n", .{self.commands.items.len}) catch {};
        for (self.commands.items) |cmd| {
            stdout.print("  /{s}: {s}\n", .{ cmd.name, cmd.description }) catch {};
        }
    }

    fn parseCommandFile(self: *CustomCommandLoader, path: []const u8) !CustomCommand {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return error.EmptyFile;
        if (file_size > 64 * 1024) return error.FileTooLarge; // 64KB max

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        const content = buffer[0..bytes_read];

        const split = splitFrontmatter(content);

        var cmd = CustomCommand{
            .allocator = self.allocator,
            .name = "",
            .description = "",
            .arg_names = &[_][]const u8{},
            .model = null,
            .template = "",
            .file_path = try self.allocator.dupe(u8, path),
        };

        // Parse YAML frontmatter
        if (split.yaml.len > 0) {
            self.parseYamlFields(split.yaml, &cmd) catch {};
        }

        // Body becomes the template
        if (split.body.len > 0) {
            cmd.template = try self.allocator.dupe(u8, std.mem.trim(u8, split.body, " \t\r\n"));
        }

        // Derive name from filename if not in frontmatter
        if (cmd.name.len == 0) {
            const basename = std.fs.path.basename(path);
            const name_end = if (std.mem.endsWith(u8, basename, ".md"))
                basename.len - 3
            else
                basename.len;
            cmd.name = try self.allocator.dupe(u8, basename[0..name_end]);
        }

        return cmd;
    }

    fn parseYamlFields(self: *CustomCommandLoader, yaml: []const u8, cmd: *CustomCommand) !void {
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
                } else if (std.mem.eql(u8, key, "args")) {
                    cmd.arg_names = try self.parseCommaList(value);
                } else if (std.mem.eql(u8, key, "model")) {
                    if (!std.mem.eql(u8, value, "null") and !std.mem.eql(u8, value, "default")) {
                        cmd.model = try self.allocator.dupe(u8, value);
                    }
                }
            }
        }
    }

    fn parseCommaList(self: *CustomCommandLoader, value: []const u8) ![][]const u8 {
        var items = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit();
        }

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t\"'[]");
            if (trimmed.len == 0) continue;
            try items.append(try self.allocator.dupe(u8, trimmed));
        }

        return items.toOwnedSlice();
    }
};

/// Split YAML frontmatter from markdown body
fn splitFrontmatter(content: []const u8) struct { yaml: []const u8, body: []const u8 } {
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

test "CustomCommand - render with no placeholders" {
    const cmd = CustomCommand{
        .allocator = testing.allocator,
        .name = "test",
        .description = "Test command",
        .arg_names = &.{},
        .model = null,
        .template = "Just a plain prompt",
        .file_path = "test.md",
    };
    const result = try cmd.render(testing.allocator, &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Just a plain prompt", result);
}

test "CustomCommand - render with {{args}} placeholder" {
    const cmd = CustomCommand{
        .allocator = testing.allocator,
        .name = "test",
        .description = "Test",
        .arg_names = &.{},
        .model = null,
        .template = "Deploy to {{args}} now",
        .file_path = "test.md",
    };
    const result = try cmd.render(testing.allocator, &.{"staging"});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Deploy to staging now", result);
}

test "CustomCommand - render with named placeholder" {
    const cmd = CustomCommand{
        .allocator = testing.allocator,
        .name = "deploy",
        .description = "Deploy",
        .arg_names = &.{ "env", "region" },
        .model = null,
        .template = "Deploy to {{env}} in {{region}}",
        .file_path = "deploy.md",
    };
    const args = [_][]const u8{ "production", "us-east-1" };
    const result = try cmd.render(testing.allocator, &args);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Deploy to production in us-east-1", result);
}

test "CustomCommand - render with missing arg returns empty" {
    const cmd = CustomCommand{
        .allocator = testing.allocator,
        .name = "test",
        .description = "Test",
        .arg_names = &.{"env"},
        .model = null,
        .template = "Deploy to {{env}} {{region}}",
        .file_path = "test.md",
    };
    const args = [_][]const u8{"staging"};
    const result = try cmd.render(testing.allocator, &args);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Deploy to staging ", result);
}

test "splitFrontmatter - with YAML frontmatter" {
    const content =
        \\---
        \\name: deploy
        \\description: Deploy project
        \\args: env, region
        \\---
        \\Deploy the project to {{env}} in {{region}}.
    ;

    const result = splitFrontmatter(content);
    try testing.expect(result.yaml.len > 0);
    try testing.expect(result.body.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.yaml, "name: deploy") != null);
    try testing.expect(std.mem.startsWith(u8, result.body, "Deploy the project"));
}

test "splitFrontmatter - no frontmatter" {
    const content = "Just a plain prompt body.";

    const result = splitFrontmatter(content);
    try testing.expect(result.yaml.len == 0);
    try testing.expectEqualStrings("Just a plain prompt body.", result.body);
}

test "CustomCommandLoader - findCommand strips leading slash" {
    var loader = CustomCommandLoader.init(testing.allocator);
    defer loader.deinit();

    try loader.commands.append(.{
        .allocator = testing.allocator,
        .name = "deploy",
        .description = "Deploy it",
        .arg_names = &.{},
        .model = null,
        .template = "Deploy!",
        .file_path = "deploy.md",
    });

    const found = loader.findCommand("/deploy");
    try testing.expect(found != null);
    try testing.expectEqualStrings("deploy", found.?.name);

    const found2 = loader.findCommand("deploy");
    try testing.expect(found2 != null);
}
