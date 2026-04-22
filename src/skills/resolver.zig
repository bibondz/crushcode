const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const agents_parser = @import("skills_agents_parser");

const Allocator = std.mem.Allocator;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Where a skill was discovered
pub const ResolutionSource = enum {
    agents_md,
    index_md,
    trigger_match,
    keyword_match,
    direct_path,
};

/// A resolved skill reference with relevance scoring
pub const SkillResolution = struct {
    skill_name: []const u8,
    skill_path: []const u8,
    relevance: f64,
    source: ResolutionSource,

    pub fn deinit(self: *SkillResolution, allocator: Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.skill_path);
    }
};

/// An entry parsed from an _INDEX.md file
pub const IndexEntry = struct {
    skill_name: []const u8,
    skill_path: []const u8,
    description: []const u8,
    triggers: [][]const u8,
    keywords: [][]const u8,
    is_file_match: bool,

    pub fn deinit(self: *IndexEntry, allocator: Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.skill_path);
        allocator.free(self.description);
        for (self.triggers) |t| allocator.free(t);
        allocator.free(self.triggers);
        for (self.keywords) |k| allocator.free(k);
        allocator.free(self.keywords);
    }
};

/// Hierarchical skill resolver: AGENTS.md → _INDEX.md → SKILL.md
pub const SkillResolver = struct {
    allocator: Allocator,
    search_paths: [][]const u8,
    agents_config: ?*agents_parser.AgentsConfig,
    loaded_indices: std.StringHashMap([]IndexEntry),
    agents_config_owned: bool,

    pub fn init(allocator: Allocator, search_paths: []const []const u8) SkillResolver {
        // Deep-copy search paths
        const paths_allocated = allocator.alloc([]const u8, search_paths.len) catch {
            const empty = allocator.alloc([]const u8, 0) catch unreachable; // zero-size alloc cannot fail
            return SkillResolver{
                .allocator = allocator,
                .search_paths = empty,
                .agents_config = null,
                .loaded_indices = std.StringHashMap([]IndexEntry).init(allocator),
                .agents_config_owned = false,
            };
        };
        for (search_paths, 0..) |sp, i| {
            paths_allocated[i] = allocator.dupe(u8, sp) catch "";
        }

        return SkillResolver{
            .allocator = allocator,
            .search_paths = paths_allocated,
            .agents_config = null,
            .loaded_indices = std.StringHashMap([]IndexEntry).init(allocator),
            .agents_config_owned = false,
        };
    }

    pub fn deinit(self: *SkillResolver) void {
        // Free search paths
        for (self.search_paths) |sp| self.allocator.free(sp);
        self.allocator.free(self.search_paths);

        // Free agents config if we own it
        if (self.agents_config_owned) {
            if (self.agents_config) |cfg| {
                cfg.deinit();
                self.allocator.destroy(cfg);
            }
        }

        // Free loaded indices
        var iter = self.loaded_indices.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |*idx| {
                idx.deinit(self.allocator);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.loaded_indices.deinit();
    }

    /// Find and parse AGENTS.md from standard locations
    pub fn loadAgentsConfig(self: *SkillResolver, project_dir: []const u8) !void {
        const candidates = [_][]const u8{
            "AGENTS.md",
            ".claude/AGENTS.md",
            ".crushcode/AGENTS.md",
        };

        // Also try home directory
        const home_agents = try std.fmt.allocPrint(self.allocator, "{s}/.crushcode/AGENTS.md", .{
            std.process.getEnvVarOwned(self.allocator, "HOME") catch "/tmp",
        });
        defer self.allocator.free(home_agents);

        for (&candidates) |rel_path| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_dir, rel_path });
            defer self.allocator.free(full_path);

            if (agents_parser.parseAgentsMd(self.allocator, full_path)) |maybe_config| {
                if (maybe_config) |config| {
                    const cfg_ptr = try self.allocator.create(agents_parser.AgentsConfig);
                    cfg_ptr.* = config;
                    self.agents_config = cfg_ptr;
                    self.agents_config_owned = true;
                    return;
                }
            } else |_| {}
        }

        // Try home directory
        if (agents_parser.parseAgentsMd(self.allocator, home_agents)) |maybe_config| {
            if (maybe_config) |config| {
                const cfg_ptr = try self.allocator.create(agents_parser.AgentsConfig);
                cfg_ptr.* = config;
                self.agents_config = cfg_ptr;
                self.agents_config_owned = true;
                return;
            }
        } else |_| {}
    }

    /// Scan search_paths for _INDEX.md files and parse them
    pub fn loadIndices(self: *SkillResolver) !void {
        for (self.search_paths) |search_path| {
            var dir = std.fs.cwd().openDir(search_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var walker = try dir.walk(self.allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.eql(u8, entry.basename, "_INDEX.md")) continue;

                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ search_path, entry.path });
                errdefer self.allocator.free(full_path);

                const indices = self.parseIndexFile(full_path) catch continue;
                const path_key = try self.allocator.dupe(u8, entry.path);

                try self.loaded_indices.put(path_key, indices);
            }
        }

        // Also load indices from AGENTS.md skill paths
        if (self.agents_config) |cfg| {
            for (cfg.skill_paths) |skill_path| {
                // skill_path might be relative like ./skills/typescript/
                const dir_path = std.mem.trimRight(u8, skill_path, "/");

                var dir = std.fs.cwd().openDir(dir_path, .{}) catch continue;
                defer dir.close();

                dir.access("_INDEX.md", .{}) catch continue;
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, "_INDEX.md" });

                const indices = self.parseIndexFile(full_path) catch continue;
                const path_key = try self.allocator.dupe(u8, skill_path);

                try self.loaded_indices.put(path_key, indices);
            }
        }
    }

    /// Find skills matching a file path
    pub fn resolveForFile(self: *SkillResolver, file_path: []const u8) ![]SkillResolution {
        var results = array_list_compat.ArrayList(SkillResolution).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        const basename = std.fs.path.basename(file_path);
        _ = std.fs.path.extension(basename); // ext available for future use

        // Check trigger rules from AGENTS.md
        if (self.agents_config) |cfg| {
            for (cfg.trigger_rules) |rule| {
                if (self.matchGlob(rule.pattern, basename) or self.matchGlob(rule.pattern, file_path)) {
                    try results.append(.{
                        .skill_name = try self.allocator.dupe(u8, rule.skill_name),
                        .skill_path = try self.findSkillPath(rule.skill_name),
                        .relevance = if (rule.auto_load) 0.9 else 0.7,
                        .source = .trigger_match,
                    });
                }
            }
        }

        // Check _INDEX.md file match entries
        var idx_iter = self.loaded_indices.iterator();
        while (idx_iter.next()) |entry| {
            for (entry.value_ptr.*) |idx| {
                if (!idx.is_file_match) continue;

                for (idx.triggers) |trigger| {
                    if (self.matchGlob(trigger, basename) or self.matchGlob(trigger, file_path)) {
                        // Check if already added (dedup by skill_name)
                        var already_exists = false;
                        for (results.items) |existing| {
                            if (std.mem.eql(u8, existing.skill_name, idx.skill_name)) {
                                already_exists = true;
                                break;
                            }
                        }
                        if (already_exists) continue;

                        try results.append(.{
                            .skill_name = try self.allocator.dupe(u8, idx.skill_name),
                            .skill_path = try self.allocator.dupe(u8, idx.skill_path),
                            .relevance = 0.85,
                            .source = .index_md,
                        });
                        break; // One match per entry is enough
                    }
                }
            }
        }

        return results.toOwnedSlice();
    }

    /// Find skills matching a text query
    pub fn resolveForQuery(self: *SkillResolver, query: []const u8) ![]SkillResolution {
        var results = array_list_compat.ArrayList(SkillResolution).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        const query_lower = try self.toLower(query);
        defer self.allocator.free(query_lower);

        // Check _INDEX.md keyword match entries
        var idx_iter = self.loaded_indices.iterator();
        while (idx_iter.next()) |entry| {
            for (entry.value_ptr.*) |idx| {
                if (idx.is_file_match) {
                    // File-match skills can also match by description
                    const desc_lower = try self.toLower(idx.description);
                    defer self.allocator.free(desc_lower);

                    if (self.containsKeyword(query_lower, desc_lower)) {
                        try self.addIfUnique(&results, idx, 0.5, .keyword_match);
                        continue;
                    }
                }

                // Keyword match entries
                for (idx.keywords) |kw| {
                    const kw_lower = try self.toLower(kw);
                    defer self.allocator.free(kw_lower);

                    if (self.containsKeyword(query_lower, kw_lower)) {
                        try self.addIfUnique(&results, idx, 0.8, .keyword_match);
                        break;
                    }
                }

                // Also match against skill name
                const name_lower = try self.toLower(idx.skill_name);
                defer self.allocator.free(name_lower);

                if (self.containsKeyword(query_lower, name_lower)) {
                    try self.addIfUnique(&results, idx, 0.6, .keyword_match);
                }
            }
        }

        // Check AGENTS.md enabled skills
        if (self.agents_config) |cfg| {
            for (cfg.enabled_skills) |skill_name| {
                const name_lower = try self.toLower(skill_name);
                defer self.allocator.free(name_lower);

                if (self.containsKeyword(query_lower, name_lower)) {
                    var already_exists = false;
                    for (results.items) |existing| {
                        if (std.mem.eql(u8, existing.skill_name, skill_name)) {
                            already_exists = true;
                            break;
                        }
                    }
                    if (!already_exists) {
                        try results.append(.{
                            .skill_name = try self.allocator.dupe(u8, skill_name),
                            .skill_path = try self.findSkillPath(skill_name),
                            .relevance = 0.75,
                            .source = .agents_md,
                        });
                    }
                }
            }
        }

        return results.toOwnedSlice();
    }

    /// Combined resolution: merge file-based and query-based results
    pub fn resolveForContext(self: *SkillResolver, file_path: []const u8, query: []const u8) ![]SkillResolution {
        var results = array_list_compat.ArrayList(SkillResolution).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        // Get file-based resolutions
        const file_results = try self.resolveForFile(file_path);
        defer self.allocator.free(file_results);

        for (file_results) |res| {
            try results.append(res);
        }

        // Get query-based resolutions
        const query_results = try self.resolveForQuery(query);
        defer self.allocator.free(query_results);

        for (query_results) |res| {
            // Deduplicate: if skill_name already in results, bump relevance
            var found = false;
            for (results.items) |*existing| {
                if (std.mem.eql(u8, existing.skill_name, res.skill_name)) {
                    existing.relevance = @max(existing.relevance, res.relevance) + 0.1;
                    found = true;
                    // Free the duplicate
                    var dup = res;
                    dup.deinit(self.allocator);
                    break;
                }
            }
            if (!found) {
                try results.append(res);
            }
        }

        // Sort by relevance descending
        std.sort.insertion(SkillResolution, results.items, {}, struct {
            fn cmp(_: void, a: SkillResolution, b: SkillResolution) bool {
                return a.relevance > b.relevance;
            }
        }.cmp);

        return results.toOwnedSlice();
    }

    /// Print all loaded indices summary
    pub fn printSummary(self: *SkillResolver) void {
        out("Skill Resolver Summary:\n", .{});
        out("  Search paths: {d}\n", .{self.search_paths.len});
        for (self.search_paths) |sp| {
            out("    - {s}\n", .{sp});
        }

        if (self.agents_config) |cfg| {
            out("  AGENTS.md loaded: {d} skill paths, {d} triggers\n", .{
                cfg.skill_paths.len,
                cfg.trigger_rules.len,
            });
        } else {
            out("  AGENTS.md: not found\n", .{});
        }

        out("  Loaded indices: {d}\n", .{self.loaded_indices.count()});
        var iter = self.loaded_indices.iterator();
        while (iter.next()) |entry| {
            out("    - {s} ({d} entries)\n", .{ entry.key_ptr.*, entry.value_ptr.len });
        }
    }

    // --- Internal helpers ---

    /// Add a resolution if the skill_name is not already in the results
    fn addIfUnique(self: *SkillResolver, results: *array_list_compat.ArrayList(SkillResolution), idx: IndexEntry, relevance: f64, source: ResolutionSource) !void {
        for (results.items) |existing| {
            if (std.mem.eql(u8, existing.skill_name, idx.skill_name)) return;
        }
        try results.append(.{
            .skill_name = try self.allocator.dupe(u8, idx.skill_name),
            .skill_path = try self.allocator.dupe(u8, idx.skill_path),
            .relevance = relevance,
            .source = source,
        });
    }

    /// Simple glob matching: supports * wildcard only
    fn matchGlob(_: *SkillResolver, pattern: []const u8, text: []const u8) bool {
        if (std.mem.eql(u8, pattern, text)) return true;

        // Handle * wildcard
        const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse return false;

        // Pattern like *.zig → check extension
        if (star_pos == 0) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, text, suffix);
        }

        // Pattern like **/*.ts → check if text ends with suffix after **
        if (std.mem.startsWith(u8, pattern, "**/")) {
            const suffix = pattern[3..];
            return std.mem.endsWith(u8, text, suffix) or std.mem.endsWith(u8, std.fs.path.basename(text), suffix);
        }

        // Pattern like internal/adapter/** → check prefix
        if (std.mem.endsWith(u8, pattern, "/**")) {
            const prefix = pattern[0 .. pattern.len - 3];
            return std.mem.startsWith(u8, text, prefix) or std.mem.containsAtLeast(u8, text, 1, prefix);
        }

        // Simple * in middle: match prefix and suffix
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];
        if (suffix.len == 0) {
            return std.mem.startsWith(u8, text, prefix);
        }
        return std.mem.startsWith(u8, text, prefix) and std.mem.endsWith(u8, text, suffix);
    }

    /// Find the SKILL.md path for a given skill name
    fn findSkillPath(self: *SkillResolver, skill_name: []const u8) ![]const u8 {
        // Search in loaded indices first
        var idx_iter = self.loaded_indices.iterator();
        while (idx_iter.next()) |entry| {
            for (entry.value_ptr.*) |idx| {
                if (std.mem.eql(u8, idx.skill_name, skill_name)) {
                    return self.allocator.dupe(u8, idx.skill_path);
                }
            }
        }

        // Try search_paths/<skill_name>/SKILL.md
        for (self.search_paths) |sp| {
            const candidate = try std.fs.path.join(self.allocator, &[_][]const u8{ sp, skill_name, "SKILL.md" });
            std.fs.cwd().access(candidate, .{}) catch {
                self.allocator.free(candidate);
                continue;
            };
            return candidate;
        }

        return self.allocator.dupe(u8, "");
    }

    /// Parse an _INDEX.md file into IndexEntry slice
    fn parseIndexFile(self: *SkillResolver, file_path: []const u8) ![]IndexEntry {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024);
        defer self.allocator.free(content);

        return self.parseIndexContent(content, file_path);
    }

    /// Parse _INDEX.md content
    pub fn parseIndexContent(self: *SkillResolver, content: []const u8, index_path: []const u8) ![]IndexEntry {
        var entries = array_list_compat.ArrayList(IndexEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit();
        }

        var current_section: enum { none, file_match, keyword_match } = .none;
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        // Get the directory of the _INDEX.md for resolving relative paths
        const index_dir = std.fs.path.dirname(index_path) orelse ".";

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Detect section headers
            if (std.mem.containsAtLeast(u8, trimmed, 1, "File Match")) {
                current_section = .file_match;
                continue;
            } else if (std.mem.containsAtLeast(u8, trimmed, 1, "Keyword Match")) {
                current_section = .keyword_match;
                continue;
            }

            // Skip table header rows and separators
            if (std.mem.startsWith(u8, trimmed, "|") and std.mem.containsAtLeast(u8, trimmed, 1, "-----")) continue;
            if (std.mem.startsWith(u8, trimmed, "|") and std.mem.containsAtLeast(u8, trimmed, 1, "Skill")) continue;
            if (std.mem.startsWith(u8, trimmed, ">")) continue;
            if (!std.mem.startsWith(u8, trimmed, "|")) continue;

            // Parse table row: | **skill-name** | `pattern` | keywords |
            const cols = self.splitTableRow(trimmed);
            if (cols.len < 2) continue;

            const skill_name_raw = std.mem.trim(u8, cols[0], " \t|*");
            if (skill_name_raw.len == 0) continue;

            // Skip header-like rows
            if (std.mem.eql(u8, skill_name_raw, "Skill")) continue;
            if (std.mem.eql(u8, skill_name_raw, "Match when user mentions")) continue;

            const skill_name = try self.allocator.dupe(u8, skill_name_raw);

            // Extract triggers from the File pattern column (col index 1)
            var triggers = array_list_compat.ArrayList([]const u8).init(self.allocator);
            errdefer {
                for (triggers.items) |t| self.allocator.free(t);
                triggers.deinit();
            }

            var keywords = array_list_compat.ArrayList([]const u8).init(self.allocator);
            errdefer {
                for (keywords.items) |k| self.allocator.free(k);
                keywords.deinit();
            }

            if (cols.len >= 2) {
                const patterns_raw = std.mem.trim(u8, cols[1], " \t|`");
                var p_iter = std.mem.splitScalar(u8, patterns_raw, ',');
                while (p_iter.next()) |p| {
                    const pt = std.mem.trim(u8, p, " \t`");
                    if (pt.len > 0) {
                        try triggers.append(try self.allocator.dupe(u8, pt));
                    }
                }
            }

            if (cols.len >= 3) {
                const keywords_raw = std.mem.trim(u8, cols[2], " \t|");
                var k_iter = std.mem.splitScalar(u8, keywords_raw, ',');
                while (k_iter.next()) |k| {
                    const kt = std.mem.trim(u8, k, " \t");
                    if (kt.len > 0) {
                        try keywords.append(try self.allocator.dupe(u8, kt));
                    }
                }
            }

            // Build skill path: <index_dir>/<skill_name>/SKILL.md
            const skill_path = try std.fs.path.join(self.allocator, &[_][]const u8{ index_dir, skill_name_raw, "SKILL.md" });

            // Description from last column or empty
            const description = if (cols.len >= 3)
                try self.allocator.dupe(u8, std.mem.trim(u8, cols[@min(cols.len - 1, 3)], " \t|"))
            else
                try self.allocator.dupe(u8, "");

            try entries.append(.{
                .skill_name = skill_name,
                .skill_path = skill_path,
                .description = description,
                .triggers = try triggers.toOwnedSlice(),
                .keywords = try keywords.toOwnedSlice(),
                .is_file_match = current_section == .file_match,
            });
        }

        return entries.toOwnedSlice();
    }

    /// Split a markdown table row into columns
    fn splitTableRow(self: *SkillResolver, row: []const u8) [][]const u8 {
        var cols = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer cols.deinit();

        var iter = std.mem.splitScalar(u8, row, '|');
        while (iter.next()) |col| {
            const trimmed = std.mem.trim(u8, col, " \t");
            if (trimmed.len > 0) {
                cols.append(trimmed) catch break;
            }
        }

        return cols.toOwnedSlice() catch &[_][]const u8{};
    }

    /// Convert string to lowercase (ASCII only)
    fn toLower(self: *SkillResolver, s: []const u8) ![]const u8 {
        const result = try self.allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    /// Check if query contains the keyword as a substring or word
    fn containsKeyword(_: *SkillResolver, query: []const u8, keyword: []const u8) bool {
        if (keyword.len == 0) return false;
        if (keyword.len > query.len) return false;
        return std.mem.containsAtLeast(u8, query, 1, keyword);
    }
};

// --- Tests ---

test "SkillResolver - matchGlob with wildcards" {
    const allocator = std.testing.allocator;
    var resolver = SkillResolver.init(allocator, &.{});
    defer resolver.deinit();

    // *.zig pattern
    try std.testing.expect(resolver.matchGlob("*.zig", "main.zig"));
    try std.testing.expect(!resolver.matchGlob("*.zig", "main.go"));

    // **/*.ts pattern
    try std.testing.expect(resolver.matchGlob("**/*.ts", "src/main.ts"));
    try std.testing.expect(resolver.matchGlob("**/*.ts", "main.ts"));
    try std.testing.expect(!resolver.matchGlob("**/*.ts", "main.go"));

    // internal/** pattern
    try std.testing.expect(resolver.matchGlob("internal/**", "internal/adapter/handler.go"));
    try std.testing.expect(!resolver.matchGlob("internal/**", "pkg/main.go"));
}

test "SkillResolver - parseIndexContent with _INDEX.md format" {
    const allocator = std.testing.allocator;
    var resolver = SkillResolver.init(allocator, &.{});
    defer resolver.deinit();

    const content =
        \\# golang Skills Index
        \\
        \\## File Match (auto-check against the file you are editing)
        \\
        \\| Skill | File pattern | Keywords |
        \\| ----- | ------------ | -------- |
        \\| **golang-language** | `go.mod` | golang, go code, idiomatic |
        \\| golang-testing | `**/*_test.go` | testing, unit tests |
        \\
        \\## Keyword Match (only when user's request mentions these)
        \\
        \\| Skill | Match when user mentions |
        \\| ----- | ----------------------- |
        \\| **golang-concurrency** | goroutine, channel, mutex |
    ;

    const entries = try resolver.parseIndexContent(content, "skills/golang/_INDEX.md");
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);

    // File match entries
    try std.testing.expect(std.mem.eql(u8, entries[0].skill_name, "golang-language"));
    try std.testing.expect(entries[0].is_file_match);
    try std.testing.expectEqual(@as(usize, 1), entries[0].triggers.len);
    try std.testing.expect(std.mem.eql(u8, entries[0].triggers[0], "go.mod"));

    try std.testing.expect(std.mem.eql(u8, entries[1].skill_name, "golang-testing"));
    try std.testing.expect(entries[1].is_file_match);

    // Keyword match entry
    try std.testing.expect(std.mem.eql(u8, entries[2].skill_name, "golang-concurrency"));
    try std.testing.expect(!entries[2].is_file_match);
    try std.testing.expectEqual(@as(usize, 3), entries[2].keywords.len);
}

test "SkillResolver - resolveForFile matches .zig files" {
    const allocator = std.testing.allocator;
    const test_paths = [_][]const u8{"./skills"};
    var resolver = SkillResolver.init(allocator, &test_paths);
    defer resolver.deinit();

    // Manually load agents config with a trigger
    const config = try allocator.create(agents_parser.AgentsConfig);
    const trigger_rules = try allocator.alloc(agents_parser.TriggerRule, 1);
    trigger_rules[0] = .{
        .pattern = try allocator.dupe(u8, "*.zig"),
        .skill_name = try allocator.dupe(u8, "zig-skills"),
        .auto_load = true,
    };
    const empty_sp = try allocator.alloc([]const u8, 0);
    const empty_es = try allocator.alloc([]const u8, 0);
    config.* = agents_parser.AgentsConfig{
        .allocator = allocator,
        .skill_paths = empty_sp,
        .enabled_skills = empty_es,
        .trigger_rules = trigger_rules,
    };
    resolver.agents_config = config;
    resolver.agents_config_owned = true;

    const results = try resolver.resolveForFile("src/main.zig");
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(std.mem.eql(u8, results[0].skill_name, "zig-skills"));
    try std.testing.expect(results[0].source == .trigger_match);
}

test "SkillResolver - resolveForQuery finds skills by keyword" {
    const allocator = std.testing.allocator;
    var resolver = SkillResolver.init(allocator, &.{});
    defer resolver.deinit();

    // Manually populate loaded_indices
    const entries = try allocator.alloc(IndexEntry, 1);
    const kw_slice = try allocator.alloc([]const u8, 3);
    kw_slice[0] = try allocator.dupe(u8, "goroutine");
    kw_slice[1] = try allocator.dupe(u8, "channel");
    kw_slice[2] = try allocator.dupe(u8, "mutex");
    const empty_triggers = try allocator.alloc([]const u8, 0);
    entries[0] = .{
        .skill_name = try allocator.dupe(u8, "golang-concurrency"),
        .skill_path = try allocator.dupe(u8, "skills/golang/golang-concurrency/SKILL.md"),
        .description = try allocator.dupe(u8, "Concurrency patterns"),
        .triggers = empty_triggers,
        .keywords = kw_slice,
        .is_file_match = false,
    };

    try resolver.loaded_indices.put(try allocator.dupe(u8, "skills/golang/_INDEX.md"), entries);

    const results = try resolver.resolveForQuery("goroutine safety");
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    var found = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.skill_name, "golang-concurrency")) {
            found = true;
            try std.testing.expect(r.source == .keyword_match);
        }
    }
    try std.testing.expect(found);
}

test "SkillResolver - resolveForContext combines file and query results" {
    const allocator = std.testing.allocator;
    var resolver = SkillResolver.init(allocator, &.{});
    defer resolver.deinit();

    // Add trigger rule for file matching
    const config = try allocator.create(agents_parser.AgentsConfig);
    const trigger_rules = try allocator.alloc(agents_parser.TriggerRule, 1);
    trigger_rules[0] = .{
        .pattern = try allocator.dupe(u8, "*.go"),
        .skill_name = try allocator.dupe(u8, "golang-language"),
        .auto_load = true,
    };
    const empty_sp = try allocator.alloc([]const u8, 0);
    const empty_es = try allocator.alloc([]const u8, 0);
    config.* = agents_parser.AgentsConfig{
        .allocator = allocator,
        .skill_paths = empty_sp,
        .enabled_skills = empty_es,
        .trigger_rules = trigger_rules,
    };
    resolver.agents_config = config;
    resolver.agents_config_owned = true;

    // Add keyword-matching index entry
    const entries = try allocator.alloc(IndexEntry, 1);
    const kw_slice2 = try allocator.alloc([]const u8, 1);
    kw_slice2[0] = try allocator.dupe(u8, "goroutine");
    const empty_triggers2 = try allocator.alloc([]const u8, 0);
    entries[0] = .{
        .skill_name = try allocator.dupe(u8, "golang-concurrency"),
        .skill_path = try allocator.dupe(u8, "skills/golang/golang-concurrency/SKILL.md"),
        .description = try allocator.dupe(u8, "Concurrency patterns"),
        .triggers = empty_triggers2,
        .keywords = kw_slice2,
        .is_file_match = false,
    };
    try resolver.loaded_indices.put(try allocator.dupe(u8, "skills/golang/_INDEX.md"), entries);

    const results = try resolver.resolveForContext("cmd/server/main.go", "goroutine safety");
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    // Should have at least the file-triggered golang-language and keyword-matched golang-concurrency
    try std.testing.expect(results.len >= 2);

    // Results should be sorted by relevance descending
    if (results.len >= 2) {
        try std.testing.expect(results[0].relevance >= results[1].relevance);
    }
}
