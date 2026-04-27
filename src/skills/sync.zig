//! Skill synchronization system — manages skill discovery, importing,
//! exporting, and syncing between directories.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

pub const ArrayList = array_list_compat.ArrayList;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Where a skill originates from.
pub const SyncSource = enum {
    local,
    project,
    user,
    builtin,
    external,
};

/// How to resolve a sync conflict between two skills with the same name.
pub const ConflictResolution = enum {
    keep_local,
    overwrite,
    rename,
    unresolved,
};

// ---------------------------------------------------------------------------
// SkillSyncEntry
// ---------------------------------------------------------------------------

/// One discovered skill file.
pub const SkillSyncEntry = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    source: SyncSource,
    file_path: []const u8,
    version: []const u8,
    description: []const u8,
    is_valid: bool,
    validation_errors: ArrayList([]const u8),
    last_modified: ?i64,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        source: SyncSource,
        file_path: []const u8,
    ) !*SkillSyncEntry {
        const entry = try allocator.create(SkillSyncEntry);
        entry.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .source = source,
            .file_path = try allocator.dupe(u8, file_path),
            .version = try allocator.dupe(u8, "unknown"),
            .description = try allocator.dupe(u8, ""),
            .is_valid = false,
            .validation_errors = ArrayList([]const u8).init(allocator),
            .last_modified = null,
        };
        return entry;
    }

    pub fn deinit(self: *SkillSyncEntry) void {
        const alloc = self.allocator;
        for (self.validation_errors.items) |err_msg| {
            alloc.free(err_msg);
        }
        self.validation_errors.deinit();
        alloc.free(self.name);
        alloc.free(self.file_path);
        alloc.free(self.version);
        alloc.free(self.description);
        alloc.destroy(self);
    }

    /// Parse YAML frontmatter and first paragraph from SKILL.md content.
    pub fn parseMetadata(self: *SkillSyncEntry, content: []const u8) void {
        const alloc = self.allocator;

        // Parse version from YAML frontmatter
        if (parseFrontmatterField(content, "version")) |ver| {
            alloc.free(self.version);
            self.version = alloc.dupe(u8, ver) catch ver;
        }

        // Parse name from frontmatter
        if (parseFrontmatterField(content, "name")) |skill_name| {
            alloc.free(self.name);
            self.name = alloc.dupe(u8, skill_name) catch skill_name;
        }

        // Extract description: first non-empty, non-frontmatter line
        if (extractDescription(content)) |desc| {
            alloc.free(self.description);
            self.description = alloc.dupe(u8, desc) catch desc;
        }
    }
};

// ---------------------------------------------------------------------------
// SyncConflict
// ---------------------------------------------------------------------------

/// Records a conflict between two skills that share the same name.
pub const SyncConflict = struct {
    skill_name: []const u8,
    local_version: []const u8,
    external_version: []const u8,
    resolution: ConflictResolution,

    pub fn deinit(self: SyncConflict, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.local_version);
        allocator.free(self.external_version);
    }
};

// ---------------------------------------------------------------------------
// SkillSyncManager
// ---------------------------------------------------------------------------

pub const SkillSyncManager = struct {
    allocator: std.mem.Allocator,
    entries: ArrayList(*SkillSyncEntry),
    conflicts: ArrayList(SyncConflict),
    project_skills_dir: []const u8,
    user_skills_dir: []const u8,
    builtin_skills_dir: []const u8,
    cache_skills_dir: []const u8,
    skill_file_name: []const u8,
    remote_urls: [][]const u8,

    pub fn init(allocator: std.mem.Allocator) !*SkillSyncManager {
        const mgr = try allocator.create(SkillSyncManager);

        // Detect user home directory
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";

        const user_dir = try std.fmt.allocPrint(allocator, "{s}/.crushcode/skills", .{home});
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.crushcode/cache/skills", .{home});

        mgr.* = .{
            .allocator = allocator,
            .entries = ArrayList(*SkillSyncEntry).init(allocator),
            .conflicts = ArrayList(SyncConflict).init(allocator),
            .project_skills_dir = try allocator.dupe(u8, ".crushcode/skills"),
            .user_skills_dir = user_dir,
            .builtin_skills_dir = try allocator.dupe(u8, "skills"),
            .cache_skills_dir = cache_dir,
            .skill_file_name = try allocator.dupe(u8, "SKILL.md"),
            .remote_urls = &[_][]const u8{},
        };
        return mgr;
    }

    pub fn deinit(self: *SkillSyncManager) void {
        const alloc = self.allocator;
        // Free entries
        for (self.entries.items) |entry| {
            entry.deinit();
        }
        self.entries.deinit();
        // Free conflicts
        for (self.conflicts.items) |conflict| {
            conflict.deinit(alloc);
        }
        self.conflicts.deinit();
        alloc.free(self.project_skills_dir);
        alloc.free(self.user_skills_dir);
        alloc.free(self.builtin_skills_dir);
        alloc.free(self.cache_skills_dir);
        alloc.free(self.skill_file_name);
        for (self.remote_urls) |u| alloc.free(u);
        alloc.free(self.remote_urls);
        alloc.destroy(self);
    }

    /// Scan all skill sources, return count of discovered skills.
    pub fn discoverAll(self: *SkillSyncManager) usize {
        const before = self.entries.items.len;

        _ = self.discoverFromDir(self.builtin_skills_dir, .builtin);
        _ = self.discoverFromDir(self.project_skills_dir, .project);
        _ = self.discoverFromDir(self.user_skills_dir, .user);
        _ = self.discoverFromDir(self.cache_skills_dir, .external);

        return self.entries.items.len - before;
    }

    /// Set remote URLs to pull from. Called before discoverAll if config has skill URLs.
    pub fn setRemoteUrls(self: *SkillSyncManager, urls: [][]const u8) void {
        // Free previous
        for (self.remote_urls) |u| self.allocator.free(u);
        self.allocator.free(self.remote_urls);

        var owned = ArrayList([]const u8).init(self.allocator);
        for (urls) |url| {
            owned.append(self.allocator.dupe(u8, url) catch continue) catch continue;
        }
        self.remote_urls = owned.toOwnedSlice() catch &[_][]const u8{};
    }

    /// Scan a specific directory for SKILL.md files.
    pub fn discoverFromDir(self: *SkillSyncManager, dir_path: []const u8, source: SyncSource) usize {
        const alloc = self.allocator;
        var count: usize = 0;

        // Open the directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var walker = dir.walk(alloc) catch return 0;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.basename, self.skill_file_name)) continue;

            // entry.path is the relative path from walk root, e.g. "my-skill/SKILL.md"
            // Derive the skill name as the parent directory name
            const parent = std.fs.path.dirname(entry.path) orelse "";
            const effective_name = if (parent.len > 0) parent else std.mem.sliceTo(entry.basename, '.');

            // Build full path using cwd
            const full_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
            defer alloc.free(full_path);

            const sync_entry = SkillSyncEntry.init(alloc, effective_name, source, full_path) catch continue;
            errdefer sync_entry.deinit();

            // Try to read and parse the skill file
            if (std.fs.cwd().readFileAlloc(alloc, full_path, 1024 * 1024)) |content| {
                defer alloc.free(content);
                sync_entry.parseMetadata(content);

                // Get file modification time
                if (dir.statFile(entry.path)) |stat| {
                    sync_entry.last_modified = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
                } else |_| {}
            } else |_| {}

            self.entries.append(sync_entry) catch continue;
            count += 1;
        }

        return count;
    }

    /// Import a SKILL.md from source_path to the target source directory.
    pub fn importSkill(self: *SkillSyncManager, source_path: []const u8, target_source: SyncSource) !void {
        const alloc = self.allocator;

        // Read source file
        const content = try std.fs.cwd().readFileAlloc(alloc, source_path, 1024 * 1024);
        defer alloc.free(content);

        // Determine target directory
        const target_dir = switch (target_source) {
            .project => self.project_skills_dir,
            .user => self.user_skills_dir,
            .local => self.project_skills_dir,
            .builtin => self.builtin_skills_dir,
            .external => self.project_skills_dir,
        };

        // Create target directory if needed
        std.fs.cwd().makePath(target_dir) catch {};

        // Derive skill name from source path's parent directory name
        const skill_name = basename(std.fs.path.dirname(source_path) orelse "imported");
        const target_path = try std.fmt.allocPrint(alloc, "{s}/{s}/SKILL.md", .{ target_dir, skill_name });
        defer alloc.free(target_path);

        // Create the skill subdirectory
        const skill_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ target_dir, skill_name });
        defer alloc.free(skill_dir);
        std.fs.cwd().makePath(skill_dir) catch {};

        // Write the file
        const file = try std.fs.cwd().createFile(target_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Export a skill by name to an external directory.
    pub fn exportSkill(self: *SkillSyncManager, name: []const u8, target_dir: []const u8) !void {
        const alloc = self.allocator;

        const entry = self.findSkill(name) orelse return error.SkillNotFound;

        // Read the source file
        const content = try std.fs.cwd().readFileAlloc(alloc, entry.file_path, 1024 * 1024);
        defer alloc.free(content);

        // Create target directory
        std.fs.cwd().makePath(target_dir) catch {};

        // Create skill subdirectory
        const skill_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ target_dir, name });
        defer alloc.free(skill_dir);
        std.fs.cwd().makePath(skill_dir) catch {};

        // Write the file
        const target_path = try std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{skill_dir});
        defer alloc.free(target_path);

        const file = try std.fs.cwd().createFile(target_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Find a skill by name. Returns the first match.
    pub fn findSkill(self: *SkillSyncManager, name: []const u8) ?*SkillSyncEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Return all discovered skills.
    pub fn listSkills(self: *SkillSyncManager) []*SkillSyncEntry {
        return self.entries.items;
    }

    /// Return skills filtered by source.
    pub fn listBySource(self: *SkillSyncManager, source: SyncSource) []*SkillSyncEntry {
        const alloc = self.allocator;
        var result = ArrayList(*SkillSyncEntry).init(alloc);
        for (self.entries.items) |entry| {
            if (entry.source == source) {
                result.append(entry) catch continue;
            }
        }
        return result.items;
    }

    /// Validate a single skill by name.
    pub fn validate(self: *SkillSyncManager, name: []const u8) bool {
        const entry = self.findSkill(name) orelse return false;
        return validateEntry(entry);
    }

    /// Validate all skills. Returns count of valid ones.
    pub fn validateAll(self: *SkillSyncManager) usize {
        var valid_count: usize = 0;
        for (self.entries.items) |entry| {
            if (validateEntry(entry)) valid_count += 1;
        }
        return valid_count;
    }

    /// Detect conflicts: same-name skills from different sources.
    pub fn detectConflicts(self: *SkillSyncManager) []SyncConflict {
        const alloc = self.allocator;

        // Clear old conflicts
        for (self.conflicts.items) |conflict| {
            conflict.deinit(alloc);
        }
        self.conflicts.clearRetainingCapacity();

        // Compare all pairs
        for (self.entries.items, 0..) |a, i| {
            for (self.entries.items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name) and a.source != b.source) {
                    const conflict = SyncConflict{
                        .skill_name = alloc.dupe(u8, a.name) catch continue,
                        .local_version = alloc.dupe(u8, a.version) catch "unknown",
                        .external_version = alloc.dupe(u8, b.version) catch "unknown",
                        .resolution = .unresolved,
                    };
                    self.conflicts.append(conflict) catch continue;
                }
            }
        }

        return self.conflicts.items;
    }

    /// Build a formatted status string.
    pub fn getSyncStatus(self: *SkillSyncManager) ![]const u8 {
        const alloc = self.allocator;
        var buf = ArrayList(u8).init(alloc);
        const writer = buf.writer();

        try writer.print("=== Skill Sync Status ===\n\n", .{});
        try writer.print("Sources:\n", .{});
        try writer.print("  builtin:  {s} ({d} skills)\n", .{ self.builtin_skills_dir, countBySource(self, .builtin) });
        try writer.print("  project:  {s} ({d} skills)\n", .{ self.project_skills_dir, countBySource(self, .project) });
        try writer.print("  user:     {s} ({d} skills)\n", .{ self.user_skills_dir, countBySource(self, .user) });
        try writer.print("  remote:   {s} ({d} skills)\n", .{ self.cache_skills_dir, countBySource(self, .external) });
        try writer.print("\nTotal skills: {d}\n", .{self.entries.items.len});

        const conflicts = self.detectConflicts();
        if (conflicts.len > 0) {
            try writer.print("\nConflicts: {d}\n", .{conflicts.len});
            for (conflicts) |conflict| {
                try writer.print("  {s}: local={s} vs external={s} [{s}]\n", .{
                    conflict.skill_name,
                    conflict.local_version,
                    conflict.external_version,
                    @tagName(conflict.resolution),
                });
            }
        } else {
            try writer.print("\nNo conflicts detected.\n", .{});
        }

        return buf.items;
    }

    /// Print sync status to stdout.
    pub fn printStatus(self: *SkillSyncManager) void {
        const status = self.getSyncStatus() catch return;
        defer self.allocator.free(status);
        file_compat.File.stdout().writer().print("{s}", .{status}) catch {};
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Validate a single SkillSyncEntry for common issues.
fn validateEntry(entry: *SkillSyncEntry) bool {
    const alloc = entry.allocator;

    // Clear previous errors
    for (entry.validation_errors.items) |err_msg| {
        alloc.free(err_msg);
    }
    entry.validation_errors.clearRetainingCapacity();

    // Read the file
    const content = std.fs.cwd().readFileAlloc(alloc, entry.file_path, 1024 * 1024) catch {
        entry.is_valid = false;
        const msg = alloc.dupe(u8, "File does not exist or cannot be read") catch "read error";
        entry.validation_errors.append(msg) catch {};
        return false;
    };
    defer alloc.free(content);

    // Check non-empty
    if (content.len == 0) {
        entry.is_valid = false;
        const msg = alloc.dupe(u8, "File is empty") catch "empty";
        entry.validation_errors.append(msg) catch {};
    }

    // Check YAML frontmatter
    if (!std.mem.startsWith(u8, content, "---")) {
        entry.is_valid = false;
        const msg = alloc.dupe(u8, "Missing YAML frontmatter (should start with ---)") catch "no frontmatter";
        entry.validation_errors.append(msg) catch {};
    }

    // Check for name field in frontmatter
    if (parseFrontmatterField(content, "name") == null and !std.mem.startsWith(u8, content, "---")) {
        // Only warn if there IS frontmatter but no name
        const has_frontmatter = std.mem.startsWith(u8, content, "---");
        if (has_frontmatter) {
            const msg = alloc.dupe(u8, "Missing 'name' field in frontmatter") catch "no name";
            entry.validation_errors.append(msg) catch {};
        }
    }

    // Check for description (non-frontmatter content)
    const after_frontmatter = skipFrontmatter(content);
    if (after_frontmatter.len == 0) {
        entry.is_valid = false;
        const msg = alloc.dupe(u8, "Missing description (no content after frontmatter)") catch "no desc";
        entry.validation_errors.append(msg) catch {};
    }

    entry.is_valid = entry.validation_errors.items.len == 0;
    return entry.is_valid;
}

/// Count entries by source.
fn countBySource(self: *SkillSyncManager, source: SyncSource) usize {
    var count: usize = 0;
    for (self.entries.items) |entry| {
        if (entry.source == source) count += 1;
    }
    return count;
}

/// Parse a field from YAML frontmatter (between --- delimiters).
fn parseFrontmatterField(content: []const u8, field_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "---")) return null;

    // Find closing ---
    const after_first = content[3..];
    const close_idx = std.mem.indexOf(u8, after_first, "---") orelse return null;
    const frontmatter = after_first[0..close_idx];

    // Find "field_name:" line
    const search = std.fmt.allocPrint(std.heap.page_allocator, "{s}:", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(search);

    var lines = std.mem.splitSequence(u8, frontmatter, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, search)) {
            var value = trimmed[search.len..];
            value = std.mem.trim(u8, value, " \t\"'");
            if (value.len > 0) return value;
        }
    }
    return null;
}

/// Skip past the YAML frontmatter block, return remaining content.
fn skipFrontmatter(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "---")) return content;
    const after_first = content[3..];
    const close_idx = std.mem.indexOf(u8, after_first, "---") orelse return "";
    return std.mem.trim(u8, after_first[close_idx + 3 ..], " \t\n\r");
}

/// Extract the first paragraph of non-frontmatter content as description.
fn extractDescription(content: []const u8) ?[]const u8 {
    const body = skipFrontmatter(content);
    if (body.len == 0) return null;

    // First non-empty line
    var lines = std.mem.splitSequence(u8, body, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            // Return up to 200 chars
            return if (trimmed.len > 200) trimmed[0..200] else trimmed;
        }
    }
    return null;
}

/// Get the basename of a path (last component).
fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

// ===========================================================================
// CLI handler — called from experimental.zig
// ===========================================================================

pub fn handleSkillSync(remaining: [][]const u8) void {
    const allocator = std.heap.page_allocator;
    const stdout = file_compat.File.stdout().writer();

    if (remaining.len == 0) {
        stdout.print("Usage: crushcode skill-sync <subcommand> [args]\n\nSubcommands: status, import, export, list, validate, conflicts, pull, cached\n", .{}) catch {};
        return;
    }

    const subcommand = remaining[0];

    var mgr = SkillSyncManager.init(allocator) catch {
        stdout.print("Error: failed to initialize skill sync manager\n", .{}) catch {};
        return;
    };
    defer mgr.deinit();

    if (std.mem.eql(u8, subcommand, "status")) {
        _ = mgr.discoverAll();
        mgr.printStatus();
    } else if (std.mem.eql(u8, subcommand, "import")) {
        if (remaining.len < 2) {
            stdout.print("Usage: crushcode skill-sync import <path-to-SKILL.md>\n", .{}) catch {};
            return;
        }
        const source_path = remaining[1];
        mgr.importSkill(source_path, .project) catch |err| {
            stdout.print("Error importing skill: {}\n", .{err}) catch {};
            return;
        };
        stdout.print("Skill imported successfully from {s}\n", .{source_path}) catch {};
    } else if (std.mem.eql(u8, subcommand, "export")) {
        if (remaining.len < 3) {
            stdout.print("Usage: crushcode skill-sync export <skill-name> <target-dir>\n", .{}) catch {};
            return;
        }
        const skill_name = remaining[1];
        const target_dir = remaining[2];
        _ = mgr.discoverAll();
        mgr.exportSkill(skill_name, target_dir) catch |err| {
            stdout.print("Error exporting skill: {}\n", .{err}) catch {};
            return;
        };
        stdout.print("Skill '{s}' exported to {s}\n", .{ skill_name, target_dir }) catch {};
    } else if (std.mem.eql(u8, subcommand, "list")) {
        _ = mgr.discoverAll();

        // Check for --source filter
        var source_filter: ?SyncSource = null;
        var i: usize = 1;
        while (i < remaining.len) : (i += 1) {
            if (std.mem.eql(u8, remaining[i], "--source") and i + 1 < remaining.len) {
                i += 1;
                source_filter = std.meta.stringToEnum(SyncSource, remaining[i]);
            }
        }

        if (source_filter) |sf| {
            const filtered = mgr.listBySource(sf);
            stdout.print("Skills from {s} ({d}):\n", .{ @tagName(sf), filtered.len }) catch {};
            for (filtered) |entry| {
                const valid_str: []const u8 = if (entry.is_valid) "valid" else "invalid";
                stdout.print("  {s}  [{s}]  {s}\n", .{ entry.name, @tagName(entry.source), valid_str }) catch {};
            }
        } else {
            const skills = mgr.listSkills();
            stdout.print("All skills ({d}):\n", .{skills.len}) catch {};
            for (skills) |entry| {
                const valid_str: []const u8 = if (entry.is_valid) "valid" else "invalid";
                stdout.print("  {s}  [{s}]  {s}\n", .{ entry.name, @tagName(entry.source), valid_str }) catch {};
            }
        }
    } else if (std.mem.eql(u8, subcommand, "validate")) {
        _ = mgr.discoverAll();

        if (remaining.len > 1 and std.mem.eql(u8, remaining[1], "--all")) {
            const valid_count = mgr.validateAll();
            const total = mgr.entries.items.len;
            stdout.print("Validation: {d}/{d} skills valid\n\n", .{ valid_count, total }) catch {};
            for (mgr.entries.items) |entry| {
                const status_str: []const u8 = if (entry.is_valid) "PASS" else "FAIL";
                stdout.print("  [{s}] {s}\n", .{ status_str, entry.name }) catch {};
                for (entry.validation_errors.items) |err_msg| {
                    stdout.print("    - {s}\n", .{err_msg}) catch {};
                }
            }
        } else if (remaining.len > 1) {
            const name = remaining[1];
            if (mgr.validate(name)) {
                stdout.print("Skill '{s}' is valid.\n", .{name}) catch {};
            } else {
                stdout.print("Skill '{s}' has validation errors:\n", .{name}) catch {};
                if (mgr.findSkill(name)) |entry| {
                    for (entry.validation_errors.items) |err_msg| {
                        stdout.print("  - {s}\n", .{err_msg}) catch {};
                    }
                }
            }
        } else {
            stdout.print("Usage: crushcode skill-sync validate <name> OR crushcode skill-sync validate --all\n", .{}) catch {};
        }
    } else if (std.mem.eql(u8, subcommand, "conflicts")) {
        _ = mgr.discoverAll();
        const conflicts = mgr.detectConflicts();
        if (conflicts.len == 0) {
            stdout.print("No conflicts detected.\n", .{}) catch {};
        } else {
            stdout.print("Conflicts ({d}):\n", .{conflicts.len}) catch {};
            for (conflicts) |conflict| {
                stdout.print("  {s}: local={s} vs external={s} [{s}]\n", .{
                    conflict.skill_name,
                    conflict.local_version,
                    conflict.external_version,
                    @tagName(conflict.resolution),
                }) catch {};
            }
        }
    } else if (std.mem.eql(u8, subcommand, "pull")) {
        if (remaining.len < 2) {
            stdout.print("Usage: crushcode skill-sync pull <url>\n\nFetches index.json from a remote skill hub and downloads all skills to cache.\n", .{}) catch {};
            return;
        }
        const url = remaining[1];
        stdout.print("Pulling skills from {s}...\n", .{url}) catch {};

        const remote = @import("skill_remote");
        var discovery = remote.RemoteSkillDiscovery.init(allocator) catch {
            stdout.print("Error: failed to initialize remote discovery\n", .{}) catch {};
            return;
        };
        defer discovery.deinit();

        const result = discovery.pull(url) catch {
            stdout.print("Error: failed to pull skills from {s}\n", .{url}) catch {};
            return;
        };
        defer result.deinit();

        if (result.dirs.len > 0) {
            stdout.print("Downloaded {d} skill(s):\n", .{result.dirs.len}) catch {};
            for (result.dirs) |dir| {
                const name = basename(dir);
                stdout.print("  - {s} ({s})\n", .{ name, dir }) catch {};
            }
        } else {
            stdout.print("No skills found at {s}\n", .{url}) catch {};
        }

        if (result.errors.len > 0) {
            stdout.print("{d} error(s):\n", .{result.errors.len}) catch {};
            for (result.errors) |err_item| {
                stdout.print("  - {s}: {s}\n", .{ err_item.skill_name, err_item.message }) catch {};
            }
        }
    } else if (std.mem.eql(u8, subcommand, "cached")) {
        const remote = @import("skill_remote");
        var discovery = remote.RemoteSkillDiscovery.init(allocator) catch {
            stdout.print("Error: failed to initialize remote discovery\n", .{}) catch {};
            return;
        };
        defer discovery.deinit();

        const cached = discovery.getCachedSkills() catch {
            stdout.print("No cached remote skills found.\n", .{}) catch {};
            return;
        };
        defer {
            for (cached) |c| allocator.free(c);
            allocator.free(cached);
        }

        if (cached.len == 0) {
            stdout.print("No cached remote skills.\n", .{}) catch {};
        } else {
            stdout.print("Cached remote skills ({d}):\n", .{cached.len}) catch {};
            for (cached) |name| {
                stdout.print("  - {s}\n", .{name}) catch {};
            }
        }
    } else {
        stdout.print("Unknown subcommand: {s}\n\nSubcommands: status, import, export, list, validate, conflicts, pull, cached\n", .{subcommand}) catch {};
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SkillSyncEntry creation and deinit" {
    const allocator = testing.allocator;
    const entry = try SkillSyncEntry.init(allocator, "test-skill", .builtin, "skills/test-skill/SKILL.md");
    defer entry.deinit();

    try testing.expectEqualStrings("test-skill", entry.name);
    try testing.expectEqualStrings("unknown", entry.version);
    try testing.expectEqual(SyncSource.builtin, entry.source);
    try testing.expect(!entry.is_valid);
    try testing.expectEqual(@as(usize, 0), entry.validation_errors.items.len);
}

test "parseMetadata extracts frontmatter fields" {
    const allocator = testing.allocator;
    const entry = try SkillSyncEntry.init(allocator, "test-skill", .builtin, "skills/test-skill/SKILL.md");
    defer entry.deinit();

    const content =
        \\---
        \\name: my-awesome-skill
        \\version: "1.2.0"
        \\---
        \\This is the first paragraph of the skill description.
        \\More details here.
    ;
    entry.parseMetadata(content);

    try testing.expectEqualStrings("my-awesome-skill", entry.name);
    try testing.expectEqualStrings("1.2.0", entry.version);
    try testing.expectEqualStrings("This is the first paragraph of the skill description.", entry.description);
}

test "discover from a temporary directory with mock SKILL.md" {
    const allocator = testing.allocator;

    // Create temp dir structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = "zig-cache/tmp-sync-test-discover";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    // Create a mock SKILL.md
    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/my-skill", .{tmp_path});
    defer allocator.free(skill_dir);
    std.fs.cwd().makePath(skill_dir) catch {};

    const skill_file_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(skill_file_path);

    const file = try std.fs.cwd().createFile(skill_file_path, .{});
    defer file.close();
    try file.writeAll("---\nname: my-skill\nversion: \"0.1.0\"\n---\nA test skill.\n");

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    const count = mgr.discoverFromDir(tmp_path, .external);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(usize, 1), mgr.entries.items.len);
    try testing.expectEqualStrings("my-skill", mgr.entries.items[0].name);
}

test "import skill copies file correctly" {
    const allocator = testing.allocator;

    const tmp_src = "zig-cache/tmp-sync-test-import-src";
    const tmp_dst = "zig-cache/tmp-sync-test-import-dst";
    std.fs.cwd().makePath(tmp_src) catch {};
    defer std.fs.cwd().deleteTree(tmp_src) catch {};
    std.fs.cwd().makePath(tmp_dst) catch {};
    defer std.fs.cwd().deleteTree(tmp_dst) catch {};

    // Create source SKILL.md
    const src_skill_dir = try std.fmt.allocPrint(allocator, "{s}/src-skill", .{tmp_src});
    defer allocator.free(src_skill_dir);
    std.fs.cwd().makePath(src_skill_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{src_skill_dir});
    defer allocator.free(src_path);

    const content = "---\nname: imported-skill\nversion: \"2.0.0\"\n---\nImported description.\n";
    const src_file = try std.fs.cwd().createFile(src_path, .{});
    defer src_file.close();
    try src_file.writeAll(content);

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    // Override project dir to our temp dest
    allocator.free(mgr.project_skills_dir);
    mgr.project_skills_dir = try allocator.dupe(u8, tmp_dst);

    try mgr.importSkill(src_path, .project);

    // Verify the file was copied
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/src-skill/SKILL.md", .{tmp_dst});
    defer allocator.free(dst_path);

    const read_content = try std.fs.cwd().readFileAlloc(allocator, dst_path, 1024 * 1024);
    defer allocator.free(read_content);
    try testing.expectEqualStrings(content, read_content);
}

test "export skill writes to target" {
    const allocator = testing.allocator;

    const tmp_src = "zig-cache/tmp-sync-test-export-src";
    const tmp_dst = "zig-cache/tmp-sync-test-export-dst";
    std.fs.cwd().makePath(tmp_src) catch {};
    defer std.fs.cwd().deleteTree(tmp_src) catch {};
    std.fs.cwd().makePath(tmp_dst) catch {};
    defer std.fs.cwd().deleteTree(tmp_dst) catch {};

    // Create a source skill
    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/exp-skill", .{tmp_src});
    defer allocator.free(skill_dir);
    std.fs.cwd().makePath(skill_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(src_path);

    const content = "---\nname: exp-skill\n---\nExport test.\n";
    const src_file = try std.fs.cwd().createFile(src_path, .{});
    defer src_file.close();
    try src_file.writeAll(content);

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    // Override builtin dir
    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_src);

    _ = mgr.discoverFromDir(tmp_src, .builtin);

    try mgr.exportSkill("exp-skill", tmp_dst);

    const dst_path = try std.fmt.allocPrint(allocator, "{s}/exp-skill/SKILL.md", .{tmp_dst});
    defer allocator.free(dst_path);

    const read_content = try std.fs.cwd().readFileAlloc(allocator, dst_path, 1024 * 1024);
    defer allocator.free(read_content);
    try testing.expectEqualStrings(content, read_content);
}

test "validate detects missing frontmatter" {
    const allocator = testing.allocator;

    const tmp_dir = "zig-cache/tmp-sync-test-nofm";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/no-fm-skill", .{tmp_dir});
    defer allocator.free(skill_dir);
    std.fs.cwd().makePath(skill_dir) catch {};

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(skill_path);

    const file = try std.fs.cwd().createFile(skill_path, .{});
    defer file.close();
    try file.writeAll("Just some text without frontmatter.");

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_dir);

    _ = mgr.discoverFromDir(tmp_dir, .builtin);

    const valid = mgr.validate("no-fm-skill");
    try testing.expect(!valid);

    if (mgr.findSkill("no-fm-skill")) |entry| {
        try testing.expect(entry.validation_errors.items.len > 0);
    }
}

test "validate detects empty file" {
    const allocator = testing.allocator;

    const tmp_dir = "zig-cache/tmp-sync-test-empty";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/empty-skill", .{tmp_dir});
    defer allocator.free(skill_dir);
    std.fs.cwd().makePath(skill_dir) catch {};

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(skill_path);

    const file = try std.fs.cwd().createFile(skill_path, .{});
    defer file.close();
    try file.writeAll("");

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_dir);

    _ = mgr.discoverFromDir(tmp_dir, .builtin);

    const valid = mgr.validate("empty-skill");
    try testing.expect(!valid);
}

test "validate passes for well-formed skill" {
    const allocator = testing.allocator;

    const tmp_dir = "zig-cache/tmp-sync-test-valid";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/good-skill", .{tmp_dir});
    defer allocator.free(skill_dir);
    std.fs.cwd().makePath(skill_dir) catch {};

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
    defer allocator.free(skill_path);

    const content = "---\nname: good-skill\nversion: \"1.0.0\"\n---\nA well-formed skill for testing.\n";
    const file = try std.fs.cwd().createFile(skill_path, .{});
    defer file.close();
    try file.writeAll(content);

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_dir);

    _ = mgr.discoverFromDir(tmp_dir, .builtin);

    const valid = mgr.validate("good-skill");
    try testing.expect(valid);

    if (mgr.findSkill("good-skill")) |entry| {
        try testing.expect(entry.validation_errors.items.len == 0);
    }
}

test "detect conflicts between same-name skills" {
    const allocator = testing.allocator;

    const tmp_a = "zig-cache/tmp-sync-test-conflict-a";
    const tmp_b = "zig-cache/tmp-sync-test-conflict-b";
    std.fs.cwd().makePath(tmp_a) catch {};
    defer std.fs.cwd().deleteTree(tmp_a) catch {};
    std.fs.cwd().makePath(tmp_b) catch {};
    defer std.fs.cwd().deleteTree(tmp_b) catch {};

    // Create same-name skill in both dirs
    inline for (&[_][]const u8{ tmp_a, tmp_b }) |dir| {
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/shared-skill", .{dir});
        defer allocator.free(skill_dir);
        std.fs.cwd().makePath(skill_dir) catch {};

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        defer allocator.free(skill_path);

        const file = try std.fs.cwd().createFile(skill_path, .{});
        defer file.close();
        try file.writeAll("---\nname: shared-skill\nversion: \"1.0.0\"\n---\nA shared skill.\n");
    }

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_a);
    allocator.free(mgr.user_skills_dir);
    mgr.user_skills_dir = try allocator.dupe(u8, tmp_b);

    _ = mgr.discoverFromDir(tmp_a, .builtin);
    _ = mgr.discoverFromDir(tmp_b, .user);

    const conflicts = mgr.detectConflicts();
    try testing.expectEqual(@as(usize, 1), conflicts.len);
    try testing.expectEqualStrings("shared-skill", conflicts[0].skill_name);
    try testing.expectEqual(ConflictResolution.unresolved, conflicts[0].resolution);
}

test "list by source filtering" {
    const allocator = testing.allocator;

    const tmp_a = "zig-cache/tmp-sync-test-list-a";
    const tmp_b = "zig-cache/tmp-sync-test-list-b";
    std.fs.cwd().makePath(tmp_a) catch {};
    defer std.fs.cwd().deleteTree(tmp_a) catch {};
    std.fs.cwd().makePath(tmp_b) catch {};
    defer std.fs.cwd().deleteTree(tmp_b) catch {};

    // Create skills in dir A
    {
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/skill-alpha", .{tmp_a});
        defer allocator.free(skill_dir);
        std.fs.cwd().makePath(skill_dir) catch {};
        const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        defer allocator.free(skill_path);
        const file = try std.fs.cwd().createFile(skill_path, .{});
        defer file.close();
        try file.writeAll("---\nname: skill-alpha\n---\nAlpha.\n");
    }

    // Create skills in dir B
    {
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/skill-beta", .{tmp_b});
        defer allocator.free(skill_dir);
        std.fs.cwd().makePath(skill_dir) catch {};
        const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        defer allocator.free(skill_path);
        const file = try std.fs.cwd().createFile(skill_path, .{});
        defer file.close();
        try file.writeAll("---\nname: skill-beta\n---\nBeta.\n");
    }

    var mgr = try SkillSyncManager.init(allocator);
    defer mgr.deinit();

    allocator.free(mgr.builtin_skills_dir);
    mgr.builtin_skills_dir = try allocator.dupe(u8, tmp_a);
    allocator.free(mgr.user_skills_dir);
    mgr.user_skills_dir = try allocator.dupe(u8, tmp_b);

    _ = mgr.discoverFromDir(tmp_a, .builtin);
    _ = mgr.discoverFromDir(tmp_b, .user);

    const builtin_skills = mgr.listBySource(.builtin);
    try testing.expectEqual(@as(usize, 1), builtin_skills.len);
    try testing.expectEqualStrings("skill-alpha", builtin_skills[0].name);

    const user_skills = mgr.listBySource(.user);
    try testing.expectEqual(@as(usize, 1), user_skills.len);
    try testing.expectEqualStrings("skill-beta", user_skills[0].name);

    const all_skills = mgr.listSkills();
    try testing.expectEqual(@as(usize, 2), all_skills.len);
}
