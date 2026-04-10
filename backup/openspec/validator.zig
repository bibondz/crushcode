const std = @import("std");
const types = @import("common.zig");
const parser = @import("parser.zig");

pub const SpecValidator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpecValidator {
        return SpecValidator{ .allocator = allocator };
    }

    pub fn validateSpec(self: *SpecValidator, metadata: common.SpecMetadata) !common.OpenSpecError {
        // Validate id field
        if (metadata.id.len == 0) {
            return error.MissingRequiredField;
        }

        // Validate status field
        if (metadata.status.len == 0) {
            return error.MissingRequiredField;
        }

        // Validate status value is one of: draft, review, approved, implemented, archived
        const valid_statuses = [_][]const u8{
            "draft",
            "review",
            "approved",
            "implemented",
            "archived",
        };

        for (valid_statuses) |status| {
            if (std.mem.eql(u8, metadata.status, status)) {
                break;
            }
        } else {
            return error.InvalidStatus;
        }

        // Created field is optional
        // Updated field is optional
        // Source field is optional

        return null;
    }

    pub fn validateGherkinSyntax(self: *SpecValidator, content: []const u8) !common.OpenSpecError {
        const lines = std.mem.splitScalar(u8, content, '\n');
        var in_requirement: bool = false;
        var in_scenario: bool = false;
        var has_shall: bool = false;
        var has_given: bool = false;
        var has_when: bool = false;
        var has_then: bool = false;

        for (lines) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\n\r");
            if (trimmed.len == 0) {
                continue;
            }

            // Check for requirement heading (starts with "###")
            if (std.mem.startsWith(u8, trimmed, "###")) {
                in_requirement = true;
                in_scenario = false;
                has_shall = false;
                has_given = false;
                has_when = false;
                has_then = false;
                continue;
            }

            // Check for scenario heading (starts with "####")
            if (std.mem.startsWith(u8, trimmed, "####")) {
                in_scenario = true;
                has_given = false;
                has_when = false;
                has_then = false;
                continue;
            }

            // Check for MUST/SHALL keyword
            if (in_requirement) {
                if (std.mem.eql(u8, trimmed, "The system SHALL")) {
                    has_shall = true;
                }
            }

            // Check for GIVEN/WHEN/THEN keywords in scenarios
            if (in_scenario) {
                if (std.mem.startsWith(u8, trimmed, "GIVEN")) {
                    has_given = true;
                } else if (std.mem.startsWith(u8, trimmed, "WHEN")) {
                    has_when = true;
                } else if (std.mem.startsWith(u8, trimmed, "THEN")) {
                    has_then = true;
                }
            }
        }

        // Validate requirement has SHALL
        if (in_requirement and !has_shall) {
            return error.GherkinSyntaxError;
        }

        // Validate scenario has GIVEN/WHEN/THEN
        if (in_scenario and !(has_given and has_when and has_then)) {
            return error.GherkinSyntaxError;
        }

        return null;
    }

    pub fn validateFolderStructure(self: *SpecValidator, spec_path: []const u8) !common.OpenSpecError {
        // Check if path ends with /spec.md
        if (!std.mem.endsWith(u8, spec_path, "spec.md")) {
            return error.InvalidFolderStructure;
        }

        // Check if parent directory exists
        // This is handled by the file reading layer

        return null;
    }
};
