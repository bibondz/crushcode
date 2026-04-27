//! Remote skill discovery — fetch skill packs from URLs and cache locally.
//! Mirrors OpenCode's discovery.ts: fetch index.json, download SKILL.md + assets.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const http_client = @import("http_client");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;

// ---------------------------------------------------------------------------
// RemoteIndexEntry — one skill from a remote index.json
// ---------------------------------------------------------------------------

/// A skill entry parsed from remote index.json:
///   { "name": "react-patterns", "files": ["SKILL.md", "refs/hooks.md"] }
pub const RemoteIndexEntry = struct {
    allocator: Allocator,
    name: []const u8,
    files: [][]const u8,

    pub fn deinit(self: *RemoteIndexEntry) void {
        self.allocator.free(self.name);
        for (self.files) |f| self.allocator.free(f);
        self.allocator.free(self.files);
    }
};

// ---------------------------------------------------------------------------
// RemoteIndex — parsed index.json
// ---------------------------------------------------------------------------

/// Parsed structure of a remote index.json:
///   { "skills": [ { "name": "...", "files": [...] }, ... ] }
pub const RemoteIndex = struct {
    allocator: Allocator,
    skills: []*RemoteIndexEntry,

    pub fn deinit(self: *RemoteIndex) void {
        for (self.skills) |entry| {
            var e = entry.*;
            e.deinit();
            self.allocator.destroy(entry);
        }
        self.allocator.free(self.skills);
    }
};

// ---------------------------------------------------------------------------
// PullResult — outcome of pulling from one URL
// ---------------------------------------------------------------------------

pub const PullResult = struct {
    allocator: Allocator,
    dirs: [][]const u8,
    errors: []PullError,

    pub fn deinit(self: *PullResult) void {
        for (self.dirs) |d| self.allocator.free(d);
        self.allocator.free(self.dirs);
        for (self.errors) |e| {
            self.allocator.free(e.skill_name);
            self.allocator.free(e.message);
        }
        self.allocator.free(self.errors);
    }
};

pub const PullError = struct {
    skill_name: []const u8,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// RemoteSkillDiscovery
// ---------------------------------------------------------------------------

/// Fetches skill packs from remote URLs and caches them locally.
///
/// Usage:
///   var discovery = try RemoteSkillDiscovery.init(allocator);
///   defer discovery.deinit();
///   const result = try discovery.pull("https://example.com/.well-known/skills/");
///   // result.dirs = ["/home/user/.crushcode/cache/skills/react-patterns", ...]
pub const RemoteSkillDiscovery = struct {
    allocator: Allocator,
    cache_dir: []const u8,

    /// Initialize with default cache dir (~/.crushcode/cache/skills/).
    pub fn init(allocator: Allocator) !*RemoteSkillDiscovery {
        const self = try allocator.create(RemoteSkillDiscovery);

        const home = std.process.getEnvVarOwned(allocator, "HOME") catch try allocator.dupe(u8, "/tmp");
        const cache = try std.fmt.allocPrint(allocator, "{s}/.crushcode/cache/skills", .{home});
        allocator.free(home);

        self.* = .{
            .allocator = allocator,
            .cache_dir = cache,
        };
        return self;
    }

    /// Initialize with a custom cache directory (useful for testing).
    pub fn initWithDir(allocator: Allocator, cache_dir: []const u8) !*RemoteSkillDiscovery {
        const self = try allocator.create(RemoteSkillDiscovery);
        self.* = .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
        };
        return self;
    }

    pub fn deinit(self: *RemoteSkillDiscovery) void {
        self.allocator.free(self.cache_dir);
        self.allocator.destroy(self);
    }

    /// Fetch and parse index.json from a base URL.
    /// base_url should end with '/' or not — we normalize it.
    pub fn fetchIndex(self: *RemoteSkillDiscovery, base_url: []const u8) !*RemoteIndex {
        const allocator = self.allocator;

        // Build index.json URL
        const base = if (base_url.len > 0 and base_url[base_url.len - 1] == '/')
            base_url[0 .. base_url.len - 1]
        else
            base_url;

        const index_url = try std.fmt.allocPrint(allocator, "{s}/index.json", .{base});
        defer allocator.free(index_url);

        // Fetch
        const response = try http_client.httpGet(allocator, index_url, &.{
            .{ .name = "Accept", .value = "application/json" },
        });
        defer allocator.free(response.body);

        if (response.status != .ok) {
            return error.HttpError;
        }

        return self.parseRemoteIndex(response.body);
    }

    /// Parse a JSON string into a RemoteIndex.
    pub fn parseRemoteIndex(self: *RemoteSkillDiscovery, json_body: []const u8) !*RemoteIndex {
        const allocator = self.allocator;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const root = parsed.value;

        // Find "skills" array
        const skills_val = switch (root) {
            .object => |obj| obj.get("skills") orelse return error.InvalidJson,
            else => return error.InvalidJson,
        };

        const skills_arr = switch (skills_val) {
            .array => |arr| arr,
            else => return error.InvalidJson,
        };

        var entries = ArrayList(*RemoteIndexEntry).init(allocator);
        errdefer {
            for (entries.items) |e| {
                var entry = e.*;
                entry.deinit();
                allocator.destroy(e);
            }
            entries.deinit();
        }

        for (skills_arr.items) |skill_val| {
            const skill_obj = switch (skill_val) {
                .object => |obj| obj,
                else => continue,
            };

            const name_val = skill_obj.get("name") orelse continue;
            const name = switch (name_val) {
                .string => |s| s,
                else => continue,
            };

            const files_val = skill_obj.get("files") orelse continue;
            const files_arr = switch (files_val) {
                .array => |arr| arr,
                else => continue,
            };

            // Must include SKILL.md
            var has_skill_md = false;
            var files = ArrayList([]const u8).init(allocator);
            errdefer {
                for (files.items) |f| allocator.free(f);
                files.deinit();
            }

            for (files_arr.items) |file_val| {
                const file_name = switch (file_val) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, file_name, "SKILL.md")) has_skill_md = true;
                try files.append(try allocator.dupe(u8, file_name));
            }

            if (!has_skill_md) {
                // Skip skills missing SKILL.md
                for (files.items) |f| allocator.free(f);
                files.deinit();
                continue;
            }

            const entry = try allocator.create(RemoteIndexEntry);
            entry.* = .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .files = try files.toOwnedSlice(),
            };
            try entries.append(entry);
        }

        const index = try allocator.create(RemoteIndex);
        index.* = .{
            .allocator = allocator,
            .skills = try entries.toOwnedSlice(),
        };
        return index;
    }

    /// Download all files for a single skill to the cache directory.
    /// Returns the local directory path where files were saved.
    pub fn downloadSkill(self: *RemoteSkillDiscovery, base_url: []const u8, entry: *RemoteIndexEntry) ![]const u8 {
        const allocator = self.allocator;

        const base = if (base_url.len > 0 and base_url[base_url.len - 1] == '/')
            base_url[0 .. base_url.len - 1]
        else
            base_url;

        // Create cache dir: <cache_dir>/<skill_name>/
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.cache_dir, entry.name });
        errdefer allocator.free(skill_dir);

        std.fs.cwd().makePath(skill_dir) catch {};

        // Download each file
        for (entry.files) |file_name| {
            const file_url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base, entry.name, file_name });
            defer allocator.free(file_url);

            const response = http_client.httpGet(allocator, file_url, null) catch |err| {
                if (err == error.HttpError) continue;
                return err;
            };
            defer allocator.free(response.body);

            if (response.status != .ok) continue;

            // Build local file path
            const local_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ skill_dir, file_name });
            defer allocator.free(local_path);

            // Ensure parent directory exists (for nested paths like refs/hooks.md)
            if (std.fs.path.dirname(local_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }

            const file = std.fs.cwd().createFile(local_path, .{}) catch continue;
            defer file.close();
            file.writeAll(response.body) catch continue;
        }

        // Verify SKILL.md was actually written
        const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        defer allocator.free(skill_md_path);

        std.fs.cwd().access(skill_md_path, .{}) catch return error.SkillDownloadFailed;

        return allocator.dupe(u8, skill_dir);
    }

    /// Pull all skills from a remote URL.
    /// Fetches index.json, downloads each skill, returns cached directory paths.
    pub fn pull(self: *RemoteSkillDiscovery, base_url: []const u8) !*PullResult {
        const allocator = self.allocator;

        var dirs = ArrayList([]const u8).init(allocator);
        errdefer {
            for (dirs.items) |d| allocator.free(d);
            dirs.deinit();
        }

        var errors = ArrayList(PullError).init(allocator);
        errdefer {
            for (errors.items) |e| {
                allocator.free(e.skill_name);
                allocator.free(e.message);
            }
            errors.deinit();
        }

        // Fetch index
        const index = self.fetchIndex(base_url) catch {
            return error.FetchFailed;
        };
        defer index.deinit();

        // Download each skill
        for (index.skills) |skill_entry| {
            const dir_path = self.downloadSkill(base_url, skill_entry) catch {
                try errors.append(.{
                    .skill_name = try allocator.dupe(u8, skill_entry.name),
                    .message = try allocator.dupe(u8, "download failed"),
                });
                continue;
            };
            try dirs.append(dir_path);
        }

        const result = try allocator.create(PullResult);
        result.* = .{
            .allocator = allocator,
            .dirs = try dirs.toOwnedSlice(),
            .errors = try errors.toOwnedSlice(),
        };
        return result;
    }

    /// Get all cached skill directories from the cache dir.
    pub fn getCachedSkills(self: *RemoteSkillDiscovery) ![][]const u8 {
        const allocator = self.allocator;
        var result = ArrayList([]const u8).init(allocator);
        errdefer {
            for (result.items) |r| allocator.free(r);
            result.deinit();
        }

        var dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch return &[_][]const u8{};
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Check if SKILL.md exists in this subdirectory
            const skill_md = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ self.cache_dir, entry.name });
            defer allocator.free(skill_md);

            std.fs.cwd().access(skill_md, .{}) catch continue;
            try result.append(try allocator.dupe(u8, entry.name));
        }

        return result.toOwnedSlice();
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "parseRemoteIndex - parses valid index.json" {
    const allocator = std.testing.allocator;

    const discovery = try allocator.create(RemoteSkillDiscovery);
    discovery.* = .{
        .allocator = allocator,
        .cache_dir = try allocator.dupe(u8, "/tmp/test-cache"),
    };
    defer {
        allocator.free(discovery.cache_dir);
        allocator.destroy(discovery);
    }

    const json =
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "react-patterns",
        \\      "files": ["SKILL.md", "refs/hooks.md"]
        \\    },
        \\    {
        \\      "name": "zig-best-practices",
        \\      "files": ["SKILL.md"]
        \\    }
        \\  ]
        \\}
    ;

    const index = try discovery.parseRemoteIndex(json);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 2), index.skills.len);
    try std.testing.expectEqualStrings("react-patterns", index.skills[0].name);
    try std.testing.expectEqual(@as(usize, 2), index.skills[0].files.len);
    try std.testing.expectEqualStrings("SKILL.md", index.skills[0].files[0]);
    try std.testing.expectEqualStrings("refs/hooks.md", index.skills[0].files[1]);
    try std.testing.expectEqualStrings("zig-best-practices", index.skills[1].name);
    try std.testing.expectEqual(@as(usize, 1), index.skills[1].files.len);
}

test "parseRemoteIndex - handles empty skills array" {
    const allocator = std.testing.allocator;

    const discovery = try allocator.create(RemoteSkillDiscovery);
    discovery.* = .{
        .allocator = allocator,
        .cache_dir = try allocator.dupe(u8, "/tmp/test-cache"),
    };
    defer {
        allocator.free(discovery.cache_dir);
        allocator.destroy(discovery);
    }

    const json = \\{"skills":[]}
    ;

    const index = try discovery.parseRemoteIndex(json);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.skills.len);
}

test "parseRemoteIndex - skips entries without SKILL.md" {
    const allocator = std.testing.allocator;

    const discovery = try allocator.create(RemoteSkillDiscovery);
    discovery.* = .{
        .allocator = allocator,
        .cache_dir = try allocator.dupe(u8, "/tmp/test-cache"),
    };
    defer {
        allocator.free(discovery.cache_dir);
        allocator.destroy(discovery);
    }

    const json =
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "good-skill",
        \\      "files": ["SKILL.md"]
        \\    },
        \\    {
        \\      "name": "bad-skill",
        \\      "files": ["README.md"]
        \\    }
        \\  ]
        \\}
    ;

    const index = try discovery.parseRemoteIndex(json);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 1), index.skills.len);
    try std.testing.expectEqualStrings("good-skill", index.skills[0].name);
}

test "parseRemoteIndex - invalid JSON returns error" {
    const allocator = std.testing.allocator;

    const discovery = try allocator.create(RemoteSkillDiscovery);
    discovery.* = .{
        .allocator = allocator,
        .cache_dir = try allocator.dupe(u8, "/tmp/test-cache"),
    };
    defer {
        allocator.free(discovery.cache_dir);
        allocator.destroy(discovery);
    }

    const result = discovery.parseRemoteIndex("not json at all");
    try std.testing.expect(result == error.InvalidJson);
}

test "RemoteIndexEntry - deinit frees all memory" {
    const allocator = std.testing.allocator;

    const files_slice: [][]const u8 = blk: {
        const tmp = &[_][]const u8{
            try allocator.dupe(u8, "SKILL.md"),
            try allocator.dupe(u8, "refs/guide.md"),
        };
        break :blk @constCast(tmp);
    };
    const entry = try allocator.create(RemoteIndexEntry);
    entry.* = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, "test-skill"),
        .files = files_slice,
    };

    // Just verify no crash — allocator's leak detection handles the rest
    entry.deinit();
    allocator.destroy(entry);
}

test "RemoteSkillDiscovery - init and deinit" {
    const allocator = std.testing.allocator;

    const discovery = try RemoteSkillDiscovery.init(allocator);
    defer discovery.deinit();

    try std.testing.expect(discovery.cache_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, discovery.cache_dir, ".crushcode/cache/skills") != null);
}

test "RemoteSkillDiscovery - initWithDir uses custom path" {
    const allocator = std.testing.allocator;

    const discovery = try RemoteSkillDiscovery.initWithDir(allocator, "/custom/cache/path");
    defer discovery.deinit();

    try std.testing.expectEqualStrings("/custom/cache/path", discovery.cache_dir);
}
