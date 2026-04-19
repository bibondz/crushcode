const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Remote skill registry entry
pub const RemoteSkill = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    version: []const u8,
    author: []const u8,
};

/// Skill import result
pub const ImportResult = struct {
    name: []const u8,
    success: bool,
    files_downloaded: u32,
    install_path: []const u8,
    error_message: []const u8,
};

/// JSON response shape from skill registry APIs (clawhub, skills.sh)
const SkillApiResponse = struct {
    content: ?[]const u8 = null,
};

/// JSON response shape from GitHub Contents API
const GitHubContentResponse = struct {
    download_url: ?[]const u8 = null,
};

/// Fetch content from a URL via HTTP GET.
/// Returns an allocator-owned copy of the response body.
/// Caller must free the returned slice.
fn fetchUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Prevent gzip encoding — Zig's Allocating writer cannot handle compressed responses
    var header_list = array_list_compat.ArrayList(std.http.Header).init(allocator);
    defer header_list.deinit();
    try header_list.append(.{ .name = "Accept-Encoding", .value = "identity" });
    try header_list.append(.{ .name = "User-Agent", .value = "crushcode/1.0" });

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .extra_headers = header_list.items,
        .response_writer = &response_writer.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.ServerError;

    return try allocator.dupe(u8, response_writer.written());
}

/// Ensure the full directory tree for `dir_path` exists, then write `content`
/// to `dir_path/filename`. Intermediate directories are created as needed.
fn ensureDirAndWrite(allocator: Allocator, dir_path: []const u8, filename: []const u8, content: []const u8) !void {
    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename });
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Extract owner and repository name from a GitHub HTTPS URL.
/// Supports: https://github.com/owner/repo, https://github.com/owner/repo.git,
/// https://github.com/owner/repo/tree/main, etc.
fn extractGitHubOwnerRepo(repo_url: []const u8) ?struct { owner: []const u8, repo: []const u8 } {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, repo_url, prefix)) return null;
    const rest = repo_url[prefix.len..];

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const owner = rest[0..slash_idx];
    var repo = rest[slash_idx + 1 ..];

    // Strip .git suffix
    if (std.mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - 4];
    }
    // Strip trailing slash
    if (repo.len > 0 and repo[repo.len - 1] == '/') {
        repo = repo[0 .. repo.len - 1];
    }
    // Strip any deeper path segments (tree/main, blob/main/path, issues, etc.)
    if (std.mem.indexOfScalar(u8, repo, '/')) |idx| {
        repo = repo[0..idx];
    }

    if (owner.len == 0 or repo.len == 0) return null;
    return .{ .owner = owner, .repo = repo };
}

/// Skill importer — fetches skills from remote registries
///
/// Supports importing from:
/// - clawhub.ai (skill registry)
/// - skills.sh (skill marketplace)
/// - Direct GitHub URLs
/// - Raw file URLs
///
/// Reference: multica skill import system
pub const SkillImporter = struct {
    allocator: Allocator,
    skills_dir: []const u8,
    registry_cache: std.StringHashMap(RemoteSkill),

    pub fn init(allocator: Allocator, skills_dir: []const u8) SkillImporter {
        return SkillImporter{
            .allocator = allocator,
            .skills_dir = skills_dir,
            .registry_cache = std.StringHashMap(RemoteSkill).init(allocator),
        };
    }

    /// Import a skill from a URL or registry name
    /// Supports formats:
    ///   "clawhub:user/skill-name"
    ///   "skills.sh:skill-name"
    ///   "https://github.com/user/skill-repo"
    ///   "https://raw.githubusercontent.com/..."
    pub fn importSkill(self: *SkillImporter, source: []const u8) !ImportResult {
        // Determine source type
        if (std.mem.startsWith(u8, source, "clawhub:")) {
            return self.importFromClawhub(source["clawhub:".len..]);
        }
        if (std.mem.startsWith(u8, source, "skills.sh:")) {
            return self.importFromSkillsDotSh(source["skills.sh:".len..]);
        }
        if (std.mem.startsWith(u8, source, "https://github.com/")) {
            return self.importFromGitHub(source);
        }
        if (std.mem.startsWith(u8, source, "https://")) {
            return self.importFromUrl(source);
        }

        return ImportResult{
            .name = source,
            .success = false,
            .files_downloaded = 0,
            .install_path = "",
            .error_message = "Unknown source format",
        };
    }

    /// Import from clawhub.ai registry
    fn importFromClawhub(self: *SkillImporter, skill_id: []const u8) !ImportResult {
        const name = try self.allocator.dupe(u8, skill_id);
        const install_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.skills_dir, skill_id });

        const url = try std.fmt.allocPrint(self.allocator, "https://clawhub.ai/api/skills/{s}", .{skill_id});
        defer self.allocator.free(url);

        const body = fetchUrl(self.allocator, url) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to fetch: {s}", .{@errorName(err)}),
            };
        };
        defer self.allocator.free(body);

        // Try to parse JSON and extract a content field; fall back to raw body
        const content = content: {
            var parsed = std.json.parseFromSlice(SkillApiResponse, self.allocator, body, .{
                .ignore_unknown_fields = true,
            }) catch break :content try self.allocator.dupe(u8, body);
            defer parsed.deinit();

            if (parsed.value.content) |c| {
                break :content try self.allocator.dupe(u8, c);
            }
            break :content try self.allocator.dupe(u8, body);
        };
        defer self.allocator.free(content);

        ensureDirAndWrite(self.allocator, install_path, "SKILL.md", content) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to write: {s}", .{@errorName(err)}),
            };
        };

        return ImportResult{
            .name = name,
            .success = true,
            .files_downloaded = 1,
            .install_path = install_path,
            .error_message = "",
        };
    }

    /// Import from skills.sh
    fn importFromSkillsDotSh(self: *SkillImporter, skill_id: []const u8) !ImportResult {
        const name = try self.allocator.dupe(u8, skill_id);
        const install_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.skills_dir, skill_id });

        const url = try std.fmt.allocPrint(self.allocator, "https://skills.sh/api/skills/{s}", .{skill_id});
        defer self.allocator.free(url);

        const body = fetchUrl(self.allocator, url) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to fetch: {s}", .{@errorName(err)}),
            };
        };
        defer self.allocator.free(body);

        // Try to parse JSON and extract a content field; fall back to raw body
        const content = content: {
            var parsed = std.json.parseFromSlice(SkillApiResponse, self.allocator, body, .{
                .ignore_unknown_fields = true,
            }) catch break :content try self.allocator.dupe(u8, body);
            defer parsed.deinit();

            if (parsed.value.content) |c| {
                break :content try self.allocator.dupe(u8, c);
            }
            break :content try self.allocator.dupe(u8, body);
        };
        defer self.allocator.free(content);

        ensureDirAndWrite(self.allocator, install_path, "SKILL.md", content) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to write: {s}", .{@errorName(err)}),
            };
        };

        return ImportResult{
            .name = name,
            .success = true,
            .files_downloaded = 1,
            .install_path = install_path,
            .error_message = "",
        };
    }

    /// Import from a GitHub repository
    fn importFromGitHub(self: *SkillImporter, repo_url: []const u8) !ImportResult {
        const owner_repo = extractGitHubOwnerRepo(repo_url) orelse {
            return ImportResult{
                .name = "unknown",
                .success = false,
                .files_downloaded = 0,
                .install_path = "",
                .error_message = "Invalid GitHub URL format",
            };
        };
        const name = try self.allocator.dupe(u8, owner_repo.repo);
        const install_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.skills_dir, name });

        // Fetch GitHub Contents API
        const api_url = try std.fmt.allocPrint(self.allocator,
            "https://api.github.com/repos/{s}/{s}/contents/SKILL.md",
            .{ owner_repo.owner, owner_repo.repo });
        defer self.allocator.free(api_url);

        const api_body = fetchUrl(self.allocator, api_url) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to fetch GitHub API: {s}", .{@errorName(err)}),
            };
        };
        defer self.allocator.free(api_body);

        // Parse the Contents API response to extract download_url
        var parsed = std.json.parseFromSlice(GitHubContentResponse, self.allocator, api_body, .{
            .ignore_unknown_fields = true,
        }) catch {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = "Invalid JSON response from GitHub API",
            };
        };
        defer parsed.deinit();

        const raw_url = parsed.value.download_url orelse {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = "No download URL in GitHub response",
            };
        };

        // Fetch raw SKILL.md content via the download URL
        const content = fetchUrl(self.allocator, raw_url) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to download SKILL.md: {s}", .{@errorName(err)}),
            };
        };
        defer self.allocator.free(content);

        ensureDirAndWrite(self.allocator, install_path, "SKILL.md", content) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to write: {s}", .{@errorName(err)}),
            };
        };

        return ImportResult{
            .name = name,
            .success = true,
            .files_downloaded = 1,
            .install_path = install_path,
            .error_message = "",
        };
    }

    /// Import from a direct URL (raw SKILL.md file)
    fn importFromUrl(self: *SkillImporter, raw_url: []const u8) !ImportResult {
        const name = try self.allocator.dupe(u8, "imported-skill");
        const install_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.skills_dir, "imported-skill" });

        const content = fetchUrl(self.allocator, raw_url) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to fetch URL: {s}", .{@errorName(err)}),
            };
        };
        defer self.allocator.free(content);

        ensureDirAndWrite(self.allocator, install_path, "SKILL.md", content) catch |err| {
            return ImportResult{
                .name = name,
                .success = false,
                .files_downloaded = 0,
                .install_path = install_path,
                .error_message = try std.fmt.allocPrint(self.allocator, "Failed to write: {s}", .{@errorName(err)}),
            };
        };

        return ImportResult{
            .name = name,
            .success = true,
            .files_downloaded = 1,
            .install_path = install_path,
            .error_message = "",
        };
    }

    /// List available skills from remote registries
    pub fn listAvailable(self: *SkillImporter, _: []const u8) ![]RemoteSkill {
        var skills = array_list_compat.ArrayList(RemoteSkill).init(self.allocator);
        return skills.toOwnedSlice();
    }

    /// Extract repository name from GitHub URL
    fn extractRepoName(_: *SkillImporter, url: []const u8) ?[]const u8 {
        // Find last path segment
        const last_slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
        var name = url[last_slash + 1 ..];
        // Strip .git suffix
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        return name;
    }

    /// Print import result
    pub fn printResult(result: *const ImportResult) void {
        const stdout = file_compat.File.stdout().writer();
        if (result.success) {
            stdout.print("✅ Imported skill '{s}' ({d} files)\n", .{ result.name, result.files_downloaded }) catch {};
            stdout.print("   Installed to: {s}\n", .{result.install_path}) catch {};
        } else {
            stdout.print("❌ Failed to import '{s}': {s}\n", .{ result.name, result.error_message }) catch {};
        }
    }

    pub fn deinit(self: *SkillImporter) void {
        var iter = self.registry_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.description);
            self.allocator.free(entry.value_ptr.url);
            self.allocator.free(entry.value_ptr.version);
            self.allocator.free(entry.value_ptr.author);
        }
        self.registry_cache.deinit();
    }
};
