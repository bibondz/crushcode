const std = @import("std");

pub const SpecMetadata = struct {
    id: []const u8,
    status: []const u8,
    created: ?[]const u8,
    updated: ?[]const u8,
    source: ?[]const u8,
};

pub const Requirement = struct {
    title: []const u8,
    description: []const u8,
    shall_text: []const u8,
    scenarios: []Scenario,
};

pub const Scenario = struct {
    title: []const u8,
    given: []const u8,
    when: []const u8,
    then: []const u8,
};

pub const ChangeProposal = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    description: []const u8,
    created: ?[]const u8,
};

pub const OpenSpecError = error{
    FileNotFound,
    InvalidYAML,
    InvalidFrontMatter,
    MissingRequiredField,
    DuplicateRequirement,
    GherkinSyntaxError,
    InvalidStatus,
};
