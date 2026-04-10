const std = @import("std");
const common = @import("common.zig");

pub const YAMLParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) YAMLParser {
        return YAMLParser{
            .allocator = allocator,
            .input = input,
            .position = 0,
        };
    }

    pub fn parseFrontMatter(self: *YAMLParser) !common.SpecMetadata {
        // Find the opening ---
        try self.skipWhitespace();
        if (self.position >= self.input.len) {
            return error.InvalidFrontMatter;
        }
        if (self.input[self.position] != '-') {
            return error.InvalidFrontMatter;
        }
        try self.skipWhitespace();

        if (self.input[self.position + 1] != '-') {
            return error.InvalidFrontMatter;
        }
        try self.skipWhitespace();

        if (self.input[self.position + 2] != '-') {
            return error.InvalidFrontMatter;
        }

        self.position += 3; // Skip ---
        try self.skipWhitespace();

        // Parse key-value pairs until closing ---
        const metadata = try self.parseMetadataMap();

        // Find closing ---
        try self.skipWhitespace();
        if (self.position >= self.input.len) {
            return error.InvalidFrontMatter;
        }
        if (self.input[self.position] != '-') {
            return error.InvalidFrontMatter;
        }
        try self.skipWhitespace();

        if (self.input[self.position + 1] != '-') {
            return error.InvalidFrontMatter;
        }
        try self.skipWhitespace();

        if (self.input[self.position + 2] != '-') {
            return error.InvalidFrontMatter;
        }

        self.position += 3; // Skip ---

        return metadata;
    }

    fn parseMetadataMap(self: *YAMLParser) !common.SpecMetadata {
        var metadata = common.SpecMetadata{
            .id = undefined,
            .status = undefined,
            .created = null,
            .updated = null,
            .source = null,
        };

        // Parse each line as a key: value pair
        while (true) {
            try self.skipWhitespace();

            // Check if we've reached the end
            if (self.position >= self.input.len or
                (self.input[self.position] == '-' and
                 self.position + 2 < self.input.len and
                 self.input[self.position + 1] == '-' and
                 self.input[self.position + 2] == '-')) {
                break;
            }

            // Parse key
            const key_start = self.position;
            while (self.position < self.input.len) {
                const c = self.input[self.position];
                if (c == ':' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
                self.position += 1;
            }

            if (self.position < self.input.len and self.input[self.position] == ':') {
                self.position += 1; // Skip ':'
            }

            try self.skipWhitespace();

            const key = self.input[key_start:self.position];
            try self.skipWhitespace();

            // Parse value
            const value_start = self.position;
            while (self.position < self.input.len) {
                if (self.input[self.position] == '\n') break;
                self.position += 1;
            }

            const value = self.input[value_start:self.position];

            // Store in metadata
            if (std.mem.eql(u8, key, "id")) {
                metadata.id = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "status")) {
                metadata.status = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "created")) {
                metadata.created = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "updated")) {
                metadata.updated = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "source")) {
                metadata.source = try self.allocator.dupe(u8, value);
            }

            self.position += 1; // Skip newline
        }

        // Validate required fields
        if (metadata.id == null or metadata.status == null) {
            return error.MissingRequiredField;
        }

        return metadata;
    }

    fn skipWhitespace(self: *YAMLParser) !void {
        while (self.position < self.input.len) {
            switch (self.input[self.position]) {
                ' ', '\t', '\n', '\r' => self.position += 1,
                else => break,
            }
        }
    }
};
