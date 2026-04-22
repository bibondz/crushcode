const std = @import("std");
const array_list_compat = @import("array_list_compat");
const recipe_mod = @import("recipe");
const loader_mod = @import("loader");

const Allocator = std.mem.Allocator;
const Recipe = recipe_mod.Recipe;

/// Executes recipes by resolving variables and formatting the steps as a prompt.
pub const RecipeRunner = struct {
    allocator: Allocator,
    loader: *loader_mod.RecipeLoader,

    pub fn init(allocator: Allocator, loader: *loader_mod.RecipeLoader) RecipeRunner {
        return RecipeRunner{
            .allocator = allocator,
            .loader = loader,
        };
    }

    pub fn deinit(self: *RecipeRunner) void {
        _ = self;
    }

    /// Execute a recipe with given variable values.
    /// Returns formatted output of all steps combined.
    pub fn executeRecipe(self: *RecipeRunner, recipe_name: []const u8, variables: std.StringHashMap([]const u8)) ![]const u8 {
        const rec = self.loader.getRecipe(recipe_name) orelse {
            return self.allocator.dupe(u8, "Recipe not found.");
        };

        try self.validateVariables(rec, variables);
        return self.formatAsPrompt(rec, variables);
    }

    /// Validate that all required variables are provided.
    pub fn validateVariables(self: *RecipeRunner, rec: Recipe, variables: std.StringHashMap([]const u8)) !void {
        _ = self;
        for (rec.variables) |v| {
            if (v.required and variables.get(v.name) == null and v.default_value == null) {
                const msg = try std.fmt.allocPrint(self.allocator, "Missing required variable: {s}", .{v.name});
                defer self.allocator.free(msg);
                return error.MissingRequiredVariable;
            }
        }
    }

    /// Format the recipe steps as a single prompt for the AI.
    /// Creates a multi-step instruction that the AI can follow.
    pub fn formatAsPrompt(self: *RecipeRunner, rec: Recipe, variables: std.StringHashMap([]const u8)) ![]const u8 {
        // Build full variable map including defaults
        var all_vars = std.StringHashMap([]const u8).init(self.allocator);
        defer all_vars.deinit();

        // Fill in defaults first
        for (rec.variables) |v| {
            if (v.default_value) |def| {
                try all_vars.put(v.name, def);
            }
        }

        // Override with provided values
        var var_iter = variables.iterator();
        while (var_iter.next()) |entry| {
            try all_vars.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("Execute the following recipe step by step:\n\n");
        try writer.print("Recipe: {s}\n", .{rec.name});
        try writer.print("Description: {s}\n\n", .{rec.description});

        for (rec.steps, 0..) |step, idx| {
            const step_num = idx + 1;
            const resolved = recipe_mod.resolveTemplate(self.allocator, step.prompt, all_vars) catch
                try self.allocator.dupe(u8, step.prompt);
            defer self.allocator.free(resolved);

            try writer.print("Step {d}:\n{s}\n\n", .{ step_num, resolved });
        }

        try writer.writeAll("Complete all steps in order. Report progress after each step.\n");

        return buf.toOwnedSlice();
    }
};
