const std = @import("std");
const gherkin = @import("gherkin.zig");
const types = @import("common.zig");

pub const SpecManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpecManager {
        return SpecManager{ .allocator = allocator };
    }

    pub fn listSpecs(self: *SpecManager, root_dir: []const u8) !std.ArrayList(common.SpecMetadata) {
        var specs = std.ArrayList(common.SpecMetadata).init(self.allocator);

        // TODO: Implement actual directory walking
        // For now, return a placeholder
        // const dir = try std.fs.cwd().openDir(root_dir, .{});
        // defer dir.close();

        return specs;
    }

    pub fn loadSpec(self: *SpecManager, spec_path: []const u8) !common.SpecMetadata {
        // Read file content
        const file = try std.fs.cwd().openFile(spec_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB per spec
        defer self.allocator.free(file_content);

        // Parse YAML front matter
        const yaml_parser = @import("parser.zig").YAMLParser.init(self.allocator, file_content);
        const metadata = try yaml_parser.parseFrontMatter();

        return metadata;
    }

    pub fn validateSpec(self: *SpecManager, spec_path: []const u8) !common.OpenSpecError {
        // Load spec and validate it
        const metadata = try self.loadSpec(spec_path);
        const validator = @import("validator.zig").SpecValidator.init(self.allocator);
        return validator.validateSpec(metadata);
    }

    pub fn getSpecPath(self: *SpecManager, capability_id: []const u8) ![]const u8 {
        // Construct path: openspec/specs/[capability_id]/spec.md
        const spec_path = try std.fmt.allocPrint(self.allocator, "openspec/specs/{s}/spec.md", .{capability_id});
        return spec_path;
    }

    pub fn parseRequirements(self: *SpecManager, spec_path: []const u8) !std.ArrayList(common.Requirement) {
        // Read file content
        const file = try std.fs.cwd().openFile(spec_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB per spec
        defer self.allocator.free(file_content);

        // Parse requirements using Gherkin parser
        const parser = gherkin.GherkinParser.init(self.allocator, file_content);
        return parser.parseRequirements();
    }
};
