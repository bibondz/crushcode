const std = @import("std");
const types = @import("types.zig");

pub const GherkinParser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) GherkinParser {
        return GherkinParser{
            .allocator = allocator,
            .content = content,
        };
    }

    pub fn parseRequirements(self: *GherkinParser) !std.ArrayList(types.Requirement) {
        const lines = std.mem.splitScalar(u8, self.content, '\n');
        var requirements = std.ArrayList(types.Requirement).init(self.allocator);

        var current_requirement: ?types.Requirement = null;
        var scenarios = std.ArrayList(types.Scenario).init(self.allocator);

        for (lines) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\n\r");
            if (trimmed.len == 0) {
                continue;
            }

            // Check for requirement heading (###)
            if (std.mem.startsWith(u8, trimmed, "###")) {
                // Save previous requirement if exists
                if (current_requirement) |req| {
                    try requirements.append(req);
                }

                // Start new requirement
                current_requirement = types.Requirement{
                    .title = trimmed[3..], // Skip "###"
                    .description = "",
                    .shall_text = "",
                    .scenarios = scenarios,
                };
                scenarios.clearAndFree();
                continue;
            }

            // Check for scenario heading (####)
            if (std.mem.startsWith(u8, trimmed, "####")) {
                // Check if we're inside a requirement
                if (current_requirement == null) {
                    // This is a standalone scenario (not in a requirement)
                    continue;
                }

                // Create new scenario
                const scenario = types.Scenario{
                    .title = trimmed[4..], // Skip "####"
                    .given = "",
                    .when = "",
                    .then = "",
                };
                try scenarios.append(scenario);
                continue;
            }

            // Check for SHALL keyword
            if (current_requirement != null) {
                if (std.mem.startsWith(u8, trimmed, "The system SHALL")) {
                    current_requirement.?.shall_text = trimmed;
                }
            }

            // Check for GIVEN in scenarios
            for (scenarios.items) |*scenario| {
                if (std.mem.startsWith(u8, trimmed, "GIVEN")) {
                    const given_text = trimmed[6..]; // Skip "GIVEN"
                    scenario.?.given = std.mem.trim(u8, given_text, " \t");
                } else if (std.mem.startsWith(u8, trimmed, "WHEN")) {
                    const when_text = trimmed[5..]; // Skip "WHEN"
                    scenario.?.when = std.mem.trim(u8, when_text, " \t");
                } else if (std.mem.startsWith(u8, trimmed, "THEN")) {
                    const then_text = trimmed[5..]; // Skip "THEN"
                    scenario.?.then = std.mem.trim(u8, then_text, " \t");
                }
            }
        }

        // Add final requirement
        if (current_requirement) |req| {
            try requirements.append(req);
        }

        scenarios.deinit();
        return requirements;
    }
};
