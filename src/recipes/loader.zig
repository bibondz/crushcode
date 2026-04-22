const std = @import("std");
const array_list_compat = @import("array_list_compat");
const recipe = @import("recipe");

const Allocator = std.mem.Allocator;
const Recipe = recipe.Recipe;
const RecipeStep = recipe.RecipeStep;
const VariableDef = recipe.VariableDef;

/// Loads .recipe.md files from standard directories and parses them into Recipe structs.
/// Search order:
///   1. .crushcode/recipes/  (project-local)
///   2. ~/.config/crushcode/recipes/  (user-global)
pub const RecipeLoader = struct {
    allocator: Allocator,
    recipes: array_list_compat.ArrayList(Recipe),

    pub fn init(allocator: Allocator) RecipeLoader {
        return RecipeLoader{
            .allocator = allocator,
            .recipes = array_list_compat.ArrayList(Recipe).init(allocator),
        };
    }

    pub fn deinit(self: *RecipeLoader) void {
        for (self.recipes.items) |*r| {
            r.deinit(self.allocator);
        }
        self.recipes.deinit();
    }

    /// Load all recipes from standard directories
    pub fn loadAll(self: *RecipeLoader) !void {
        // Project-local recipes
        const local_dir = ".crushcode/recipes";
        self.loadFromDirectory(local_dir) catch |err| {
            if (err != error.FileNotFound) {
                std.log.warn("Failed to load local recipes from {s}: {}", .{ local_dir, err });
            }
        };

        // User-global recipes
        if (std.posix.getenv("HOME")) |home| {
            const global_path = try std.fmt.allocPrint(self.allocator, "{s}/.config/crushcode/recipes", .{home});
            defer self.allocator.free(global_path);
            self.loadFromDirectory(global_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.log.warn("Failed to load global recipes from {s}: {}", .{ global_path, err });
                }
            };
        }
    }

    /// Load recipes from a specific directory
    pub fn loadFromDirectory(self: *RecipeLoader, dir_path: []const u8) !void {
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
            if (!std.mem.endsWith(u8, basename, ".recipe.md")) continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
            errdefer self.allocator.free(full_path);

            const parsed = self.parseRecipeFile(full_path) catch |err| {
                std.log.warn("Failed to parse recipe {s}: {}", .{ full_path, err });
                self.allocator.free(full_path);
                continue;
            };

            if (parsed) |r| {
                try self.recipes.append(r);
            } else {
                self.allocator.free(full_path);
            }
        }
    }

    /// Parse a single recipe file. Returns null if the file is empty or invalid.
    pub fn parseRecipeFile(self: *RecipeLoader, source_path: []const u8) !?Recipe {
        const file = try std.fs.cwd().openFile(source_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return null;
        if (file_size > 1024 * 1024) return null; // 1MB limit

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read == 0) return null;

        const content = buffer[0..bytes_read];

        // Split frontmatter from body
        const split = splitFrontmatter(content);

        // Parse frontmatter into a PendingRecipe
        var pending = PendingRecipe{
            .allocator = self.allocator,
            .name = "",
            .description = "",
            .version = "",
            .author = "",
            .has_author = false,
            .variables = array_list_compat.ArrayList(VariableDef).init(self.allocator),
            .steps = array_list_compat.ArrayList(RecipeStep).init(self.allocator),
            .source_path = source_path,
        };
        defer {
            // Only clean up if we didn't transfer ownership
            pending.variables.deinit();
            pending.steps.deinit();
        }

        if (split.yaml.len > 0) {
            try self.parseFrontmatter(split.yaml, &pending);
        }

        // Parse body into steps
        if (split.body.len > 0) {
            try self.parseBodySteps(split.body, &pending);
        }

        // Derive name from filename if not in frontmatter
        if (pending.name.len == 0) {
            const basename = std.fs.path.basename(source_path);
            if (std.mem.endsWith(u8, basename, ".recipe.md")) {
                pending.name = try self.allocator.dupe(u8, basename[0 .. basename.len - ".recipe.md".len]);
            } else {
                pending.name = try self.allocator.dupe(u8, basename);
            }
        }

        if (pending.version.len == 0) {
            pending.version = try self.allocator.dupe(u8, "1.0");
        }

        // Transfer ownership of slices
        const vars_slice = try pending.variables.toOwnedSlice();
        const steps_slice = try pending.steps.toOwnedSlice();

        return Recipe{
            .name = pending.name,
            .description = pending.description,
            .version = pending.version,
            .author = if (pending.has_author) pending.author else null,
            .variables = vars_slice,
            .steps = steps_slice,
            .source_path = try self.allocator.dupe(u8, source_path),
        };
    }

    /// Get a recipe by name
    pub fn getRecipe(self: *RecipeLoader, name_search: []const u8) ?Recipe {
        for (self.recipes.items) |r| {
            if (std.mem.eql(u8, r.name, name_search)) {
                return r;
            }
        }
        return null;
    }

    /// List all loaded recipe names. Caller owns the returned slice and each string.
    pub fn listRecipeNames(self: *RecipeLoader) ![]const []const u8 {
        var names = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit();
        }
        for (self.recipes.items) |r| {
            try names.append(try self.allocator.dupe(u8, r.name));
        }
        return names.toOwnedSlice();
    }

    // ---------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------

    const PendingRecipe = struct {
        allocator: Allocator,
        name: []const u8,
        description: []const u8,
        version: []const u8,
        author: []const u8,
        has_author: bool,
        variables: array_list_compat.ArrayList(VariableDef),
        steps: array_list_compat.ArrayList(RecipeStep),
        source_path: []const u8,
    };

    /// Parse simple YAML key: value pairs from frontmatter.
    /// Also handles the `variables:` section with `- name: ...` entries.
    fn parseFrontmatter(self: *RecipeLoader, yaml: []const u8, pending: *PendingRecipe) !void {
        var line_iter = std.mem.splitScalar(u8, yaml, '\n');
        var in_variables_section = false;

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Detect "variables:" key (starts a list section)
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const raw_value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\"'");

                if (std.mem.eql(u8, key, "variables")) {
                    in_variables_section = true;
                    continue;
                }

                // If we're not in the variables section, parse top-level keys
                if (!in_variables_section) {
                    if (raw_value.len == 0) continue;

                    if (std.mem.eql(u8, key, "name")) {
                        pending.name = try self.allocator.dupe(u8, raw_value);
                    } else if (std.mem.eql(u8, key, "description")) {
                        pending.description = try self.allocator.dupe(u8, raw_value);
                    } else if (std.mem.eql(u8, key, "version")) {
                        pending.version = try self.allocator.dupe(u8, raw_value);
                    } else if (std.mem.eql(u8, key, "author")) {
                        pending.author = try self.allocator.dupe(u8, raw_value);
                        pending.has_author = true;
                    }
                }
            }

            // Parse variable entries (lines starting with "- name:")
            if (in_variables_section and std.mem.startsWith(u8, trimmed, "- name:")) {
                // Start collecting a variable definition
                var var_name: []const u8 = "";
                var var_desc: []const u8 = "";
                var var_default: ?[]const u8 = null;
                var var_required: bool = true;

                // Extract name from "- name: value"
                const name_val = std.mem.trim(u8, trimmed["- name:".len..], " \t\"'");
                if (name_val.len > 0) {
                    var_name = try self.allocator.dupe(u8, name_val);
                }

                // Read subsequent lines for this variable
                while (line_iter.next()) |sub_line| {
                    const sub_trimmed = std.mem.trim(u8, sub_line, " \t\r");
                    if (sub_trimmed.len == 0) continue;

                    // Stop if we hit another variable entry or a new key
                    if (std.mem.startsWith(u8, sub_trimmed, "- name:")) {
                        // Put this back by processing it as a new variable
                        // We can't put it back in the iterator, so handle inline
                        const next_name_val = std.mem.trim(u8, sub_trimmed["- name:".len..], " \t\"'");

                        // Save current variable
                        if (var_name.len > 0) {
                            try pending.variables.append(VariableDef{
                                .name = var_name,
                                .description = if (var_desc.len > 0) var_desc else var_name,
                                .default_value = var_default,
                                .required = var_required,
                            });
                        }

                        // Start new variable
                        var_name = if (next_name_val.len > 0) try self.allocator.dupe(u8, next_name_val) else "";
                        var_desc = "";
                        var_default = null;
                        var_required = true;
                        continue;
                    }

                    // Stop if we hit a non-indented key (not starting with space or -)
                    if (sub_trimmed[0] != ' ' and sub_trimmed[0] != '-' and
                        !std.mem.startsWith(u8, sub_trimmed, "name:") and
                        !std.mem.startsWith(u8, sub_trimmed, "description:") and
                        !std.mem.startsWith(u8, sub_trimmed, "required:") and
                        !std.mem.startsWith(u8, sub_trimmed, "default:"))
                    {
                        in_variables_section = false;
                        break;
                    }

                    if (std.mem.indexOfScalar(u8, sub_trimmed, ':')) |sub_colon| {
                        const sub_key = std.mem.trim(u8, sub_trimmed[0..sub_colon], " \t");
                        const sub_val = std.mem.trim(u8, sub_trimmed[sub_colon + 1 ..], " \t\"'");

                        if (std.mem.eql(u8, sub_key, "description") and sub_val.len > 0) {
                            var_desc = try self.allocator.dupe(u8, sub_val);
                        } else if (std.mem.eql(u8, sub_key, "required") and sub_val.len > 0) {
                            var_required = std.mem.eql(u8, sub_val, "true") or
                                std.mem.eql(u8, sub_val, "yes") or
                                std.mem.eql(u8, sub_val, "1");
                        } else if (std.mem.eql(u8, sub_key, "default") and sub_val.len > 0) {
                            var_default = try self.allocator.dupe(u8, sub_val);
                        }
                    }
                }

                // Save the last variable
                if (var_name.len > 0) {
                    try pending.variables.append(VariableDef{
                        .name = var_name,
                        .description = if (var_desc.len > 0) var_desc else var_name,
                        .default_value = var_default,
                        .required = var_required,
                    });
                }
            }
        }
    }

    /// Parse body content split by "## Step N:" headers into individual steps.
    fn parseBodySteps(self: *RecipeLoader, body: []const u8, pending: *PendingRecipe) !void {
        var step_buffers = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (step_buffers.items) |buf| self.allocator.free(buf);
            step_buffers.deinit();
        }

        var current_step = array_list_compat.ArrayList(u8).init(self.allocator);
        defer current_step.deinit();

        var line_iter = std.mem.splitScalar(u8, body, '\n');
        var first_step_found = false;

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Detect step headers: "## Step N:" or "## Step N - Title"
            if (std.mem.startsWith(u8, trimmed, "## Step ")) {
                if (first_step_found) {
                    // Save the previous step
                    const step_content = std.mem.trim(u8, current_step.items, " \t\r\n");
                    if (step_content.len > 0) {
                        try step_buffers.append(try self.allocator.dupe(u8, step_content));
                    }
                    current_step.clearRetainingCapacity();
                }
                first_step_found = true;

                // Skip the header line itself (it becomes the step title, we don't include it in prompt)
                continue;
            }

            if (first_step_found) {
                try current_step.appendSlice(line);
                try current_step.append('\n');
            }
        }

        // Save the last step
        if (first_step_found) {
            const step_content = std.mem.trim(u8, current_step.items, " \t\r\n");
            if (step_content.len > 0) {
                try step_buffers.append(try self.allocator.dupe(u8, step_content));
            }
        }

        // If no step headers found, treat the entire body as a single step
        if (step_buffers.items.len == 0) {
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len > 0) {
                try step_buffers.append(try self.allocator.dupe(u8, body_trimmed));
            }
        }

        // Convert buffers into RecipeSteps
        for (step_buffers.items) |buf| {
            try pending.steps.append(RecipeStep{
                .prompt = buf,
            });
        }
    }
};

/// Split YAML frontmatter from markdown body.
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
