const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A single step in a recipe workflow
pub const RecipeStep = struct {
    prompt: []const u8,
    tool: ?[]const u8 = null,
    condition: ?[]const u8 = null,

    pub fn deinit(self: *RecipeStep, allocator: Allocator) void {
        allocator.free(self.prompt);
        if (self.tool) |t| allocator.free(t);
        if (self.condition) |c| allocator.free(c);
    }
};

/// Variable definition for template substitution
pub const VariableDef = struct {
    name: []const u8,
    description: []const u8,
    default_value: ?[]const u8 = null,
    required: bool = true,

    pub fn deinit(self: *VariableDef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.default_value) |d| allocator.free(d);
    }
};

/// Recipe template definition
pub const Recipe = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8 = "1.0",
    author: ?[]const u8 = null,
    variables: []const VariableDef,
    steps: []const RecipeStep,
    source_path: []const u8,

    pub fn deinit(self: *Recipe, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.version);
        if (self.author) |a| allocator.free(a);
        for (self.variables) |*v| v.deinit(allocator);
        allocator.free(self.variables);
        for (self.steps) |*s| s.deinit(allocator);
        allocator.free(self.steps);
        allocator.free(self.source_path);
    }
};

/// Parsed recipe with resolved variables, ready for execution
pub const ResolvedRecipe = struct {
    recipe: Recipe,
    resolved_steps: []const []const u8,
    allocator: Allocator,

    pub fn deinit(self: *ResolvedRecipe) void {
        for (self.resolved_steps) |step| {
            self.allocator.free(step);
        }
        self.allocator.free(self.resolved_steps);
    }
};

/// Resolve template variables in a string.
/// Replaces {{variable_name}} with the provided value.
pub fn resolveTemplate(allocator: Allocator, template: []const u8, variables: std.StringHashMap([]const u8)) ![]const u8 {
    var result = array_list_compat.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (i + 3 < template.len and std.mem.startsWith(u8, template[i..], "{{")) {
            // Find closing }}
            const start = i + 2;
            if (std.mem.indexOfScalar(u8, template[start..], '}')) |close_offset| {
                const end = start + close_offset;
                if (end + 1 < template.len and template[end + 1] == '}') {
                    const var_name = std.mem.trim(u8, template[start..end], " ");
                    if (variables.get(var_name)) |value| {
                        try result.appendSlice(value);
                    } else {
                        // Keep placeholder if not found
                        try result.appendSlice(template[i .. end + 2]);
                    }
                    i = end + 2;
                    continue;
                }
            }
        }
        try result.append(template[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

/// Format recipe summary for display
pub fn formatRecipeSummary(allocator: Allocator, recipe: Recipe) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    writer.print("\xF0\x9F\x93\x8B {s}\n", .{recipe.name}) catch {};
    writer.print("   {s}\n", .{recipe.description}) catch {};
    writer.print("   Version: {s}\n", .{recipe.version}) catch {};
    if (recipe.author) |a| {
        writer.print("   Author: {s}\n", .{a}) catch {};
    }
    writer.print("   Steps: {d}\n", .{recipe.steps.len}) catch {};
    if (recipe.variables.len > 0) {
        writer.print("   Variables:\n", .{}) catch {};
        for (recipe.variables) |v| {
            if (v.required) {
                writer.print("     \xE2\x80\xA2 {s} (required) \xE2\x80\x94 {s}\n", .{ v.name, v.description }) catch {};
            } else {
                writer.print("     \xE2\x80\xA2 {s} (optional) \xE2\x80\x94 {s} [default: {s}]\n", .{ v.name, v.description, v.default_value orelse "none" }) catch {};
            }
        }
    }

    return buf.toOwnedSlice();
}
