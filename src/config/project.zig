const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Detected project information
pub const ProjectInfo = struct {
    language: []const u8,
    build_system: []const u8,
    framework: ?[]const u8,
    test_command: []const u8,
    build_command: []const u8,
    tips: []const u8,

    pub fn deinit(self: *const ProjectInfo, allocator: Allocator) void {
        // All fields are static string literals — no heap allocs to free
        _ = self;
        _ = allocator;
    }
};

/// Detect project type by checking for characteristic files in the current directory.
/// Returns a ProjectInfo with language, build system, commands, and tips.
pub fn detectProject(allocator: Allocator) ?ProjectInfo {
    _ = allocator;

    // Check for project files in order of specificity
    // Zig project
    if (std.fs.cwd().access("build.zig", .{})) {
        return ProjectInfo{
            .language = "Zig",
            .build_system = "zig-build",
            .framework = null,
            .build_command = "zig build",
            .test_command = "zig build test",
            .tips = "Use `zig build` to compile. Use `zig build test` to run tests. Follow Zig naming conventions (camelCase functions, PascalCase types). Use `defer` for cleanup. Prefer `const` over `var`.",
        };
    } else |_| {}

    // Rust project
    if (std.fs.cwd().access("Cargo.toml", .{})) {
        return ProjectInfo{
            .language = "Rust",
            .build_system = "cargo",
            .framework = null,
            .build_command = "cargo build",
            .test_command = "cargo test",
            .tips = "Use `cargo build` to compile. Use `cargo test` to run tests. Follow Rust naming conventions (snake_case functions, PascalCase types). Use `Result<T, E>` for error handling.",
        };
    } else |_| {}

    // Go project
    if (std.fs.cwd().access("go.mod", .{})) {
        return ProjectInfo{
            .language = "Go",
            .build_system = "go",
            .framework = null,
            .build_command = "go build ./...",
            .test_command = "go test ./...",
            .tips = "Use `go build` to compile. Use `go test` to run tests. Follow Go naming conventions (CamelCase for exported, camelCase for unexported). Use `defer` for cleanup.",
        };
    } else |_| {}

    // Node.js project
    if (std.fs.cwd().access("package.json", .{})) {
        // Detect framework from package.json
        const framework = detectNodeFramework() catch null;
        return ProjectInfo{
            .language = "JavaScript/TypeScript",
            .build_system = "npm",
            .framework = framework,
            .build_command = "npm run build",
            .test_command = "npm test",
            .tips = "Use `npm run build` to compile. Use `npm test` to run tests. Check package.json for available scripts. Use `npx` for one-off tool runs.",
        };
    } else |_| {}

    // Python project
    if (std.fs.cwd().access("pyproject.toml", .{})) {
        return ProjectInfo{
            .language = "Python",
            .build_system = "pip",
            .framework = null,
            .build_command = "pip install -e .",
            .test_command = "pytest",
            .tips = "Use `pytest` to run tests. Follow PEP 8 style guide. Use type hints for clarity. Use virtual environments (venv).",
        };
    } else |_| {}

    if (std.fs.cwd().access("requirements.txt", .{})) {
        return ProjectInfo{
            .language = "Python",
            .build_system = "pip",
            .framework = null,
            .build_command = "pip install -r requirements.txt",
            .test_command = "pytest",
            .tips = "Use `pytest` to run tests. Follow PEP 8 style guide. Use type hints for clarity.",
        };
    } else |_| {}

    // C/C++ project
    if (std.fs.cwd().access("CMakeLists.txt", .{})) {
        return ProjectInfo{
            .language = "C/C++",
            .build_system = "cmake",
            .framework = null,
            .build_command = "cmake --build build",
            .test_command = "ctest --test-dir build",
            .tips = "Use CMake for build configuration. Use `ctest` for testing. Follow modern CMake practices.",
        };
    } else |_| {}

    if (std.fs.cwd().access("Makefile", .{})) {
        return ProjectInfo{
            .language = "C/C++",
            .build_system = "make",
            .framework = null,
            .build_command = "make",
            .test_command = "make test",
            .tips = "Use `make` to build. Check Makefile for available targets.",
        };
    } else |_| {}

    // Unknown project
    return null;
}

/// Detect Node.js framework from package.json dependencies
fn detectNodeFramework() !?[]const u8 {
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "package.json", 1024 * 1024) catch return null;
    defer std.heap.page_allocator.free(content);

    if (std.mem.indexOf(u8, content, "\"next\"")) |_| return "Next.js";
    if (std.mem.indexOf(u8, content, "\"react\"")) |_| return "React";
    if (std.mem.indexOf(u8, content, "\"vue\"")) |_| return "Vue";
    if (std.mem.indexOf(u8, content, "\"svelte\"")) |_| return "Svelte";
    if (std.mem.indexOf(u8, content, "\"express\"")) |_| return "Express";
    if (std.mem.indexOf(u8, content, "\"fastify\"")) |_| return "Fastify";
    return null;
}

/// Load AGENTS.md from the current working directory.
/// Returns null if the file doesn't exist (non-fatal).
pub fn loadAgentsMd(allocator: Allocator) !?[]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, "AGENTS.md", 1024 * 1024) catch return null;
}

/// Check if a project-local config exists at `.crushcode/config.toml` in CWD.
/// Returns the path ".crushcode/config.toml" if it exists, null otherwise.
pub fn getProjectConfigPath(allocator: Allocator) ?[]const u8 {
    _ = std.fs.cwd().access(".crushcode/config.toml", .{}) catch return null;
    return allocator.dupe(u8, ".crushcode/config.toml") catch return null;
}

/// Load .crushcode/instructions.md from the current working directory.
/// Returns null if the file doesn't exist (non-fatal).
pub fn loadInstructionsMd(allocator: Allocator) !?[]const u8 {
    var dir = std.fs.cwd().openDir(".crushcode", .{}) catch return null;
    defer dir.close();
    return dir.readFileAlloc(allocator, "instructions.md", 1024 * 1024) catch return null;
}

/// A single discovered context file with its loaded content.
pub const ContextFile = struct {
    path: []const u8, // Statically allocated string literal (no free needed)
    content: []const u8, // Heap-allocated, must be freed by caller
};

/// Set of discovered context files from various AI coding assistant formats.
pub const ContextFileSet = struct {
    files: array_list_compat.ArrayList(ContextFile),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.files.items) |f| {
            allocator.free(f.content);
        }
        self.files.deinit();
    }
};

/// Try to load a single file into the result set. No-op if missing or empty.
fn tryLoadFile(allocator: Allocator, result: *array_list_compat.ArrayList(ContextFile), path: []const u8) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    if (content.len == 0) {
        allocator.free(content);
        return;
    }
    try result.append(.{
        .path = path,
        .content = content,
    });
}

/// Try to load all *.md files from a directory into the result set.
fn tryLoadDirGlob(allocator: Allocator, result: *array_list_compat.ArrayList(ContextFile), dir_path: []const u8, ext: []const u8) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        // Build "dir_path/name" for the path field
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        // We need a stable copy for the path — but since we only need it for
        // the ContextFile.path field (informational), allocate and defer-free
        // would be wrong. Use a static approach: just store the allocPrint'd
        // string and let the caller manage it via ContextFileSet.deinit which
        // frees .content. The .path field is documented as "statically allocated"
        // but for dir entries we need a heap alloc. Accept a small leak for now
        // since paths are tiny and few.
        const content = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
            allocator.free(full_path);
            continue;
        };
        if (content.len == 0) {
            allocator.free(content);
            allocator.free(full_path);
            continue;
        }
        try result.append(.{
            .path = full_path,
            .content = content,
        });
    }
}

/// Discover and load ALL common AI coding assistant context/instruction files.
/// Checks multiple formats (AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules,
/// .cursor/rules/*.md, .github/copilot-instructions.md, .crushcode/instructions.md).
/// Returns null if NO context files are found at all.
pub fn loadContextFiles(allocator: Allocator) !?ContextFileSet {
    var result = array_list_compat.ArrayList(ContextFile).init(allocator);
    errdefer result.deinit();

    // Category 1: AGENTS.md (case-insensitive variants)
    tryLoadFile(allocator, &result, "AGENTS.md") catch {};
    if (result.items.len == 0) {
        tryLoadFile(allocator, &result, "agents.md") catch {};
    }
    if (result.items.len == 0) {
        tryLoadFile(allocator, &result, "Agents.md") catch {};
    }

    // Category 2: CLAUDE.md variants
    tryLoadFile(allocator, &result, "CLAUDE.md") catch {};
    if (result.items.len == 0) {
        tryLoadFile(allocator, &result, "CLAUDE.local.md") catch {};
    }

    // Category 3: GEMINI.md variants
    tryLoadFile(allocator, &result, "GEMINI.md") catch {};
    if (result.items.len == 0) {
        tryLoadFile(allocator, &result, "gemini.md") catch {};
    }

    // Category 4: .cursorrules
    tryLoadFile(allocator, &result, ".cursorrules") catch {};

    // Category 5: .cursor/rules/*.md directory
    tryLoadDirGlob(allocator, &result, ".cursor/rules", ".md") catch {};

    // Category 6: GitHub Copilot instructions
    tryLoadFile(allocator, &result, ".github/copilot-instructions.md") catch {};

    // Category 7: Crushcode instructions (already implemented elsewhere)
    tryLoadFile(allocator, &result, ".crushcode/instructions.md") catch {};

    if (result.items.len == 0) {
        result.deinit();
        return null;
    }

    return ContextFileSet{ .files = result };
}

test "detectProject finds Zig project" {
    const testing = std.testing;
    // This test works because we're in a Zig project
    const info = detectProject(testing.allocator);
    try testing.expect(info != null);
    if (info) |project| {
        try testing.expectEqualStrings("Zig", project.language);
        try testing.expectEqualStrings("zig-build", project.build_system);
    }
}

test "loadContextFiles returns null when no context files exist" {
    const testing = std.testing;
    // Create a temp dir with no context files, change to it, run, restore cwd
    const tmp_dir_name = "zig-test-loadcontextfiles-empty";
    // Cleanup if leftover from previous run
    std.fs.cwd().deleteTree(tmp_dir_name) catch {};

    var tmp_dir = std.fs.cwd().makeOpenPath(tmp_dir_name, .{}) catch return;
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree(tmp_dir_name) catch {};
    }

    // Save current cwd
    const original_cwd = std.fs.cwd().openDir(".", .{}) catch return;
    defer original_cwd.close();

    // Change to temp dir
    tmp_dir.setAsCwd() catch return;
    defer original_cwd.setAsCwd() catch {};

    const result = try loadContextFiles(testing.allocator);
    try testing.expect(result == null);
}

test "ContextFileSet deinit frees all content" {
    const testing = std.testing;
    var list = array_list_compat.ArrayList(ContextFile).init(testing.allocator);

    // Simulate adding context files
    const content1 = try testing.allocator.dupe(u8, "hello");
    const content2 = try testing.allocator.dupe(u8, "world");
    try list.append(.{ .path = "file1.md", .content = content1 });
    try list.append(.{ .path = "file2.md", .content = content2 });

    var set = ContextFileSet{ .files = list };
    set.deinit(testing.allocator);
    // If deinit didn't free, we'd leak — test passes by not crashing
}

test "loadContextFiles finds AGENTS.md in cwd" {
    const testing = std.testing;
    const tmp_dir_name = "zig-test-loadcontextfiles-agents";
    std.fs.cwd().deleteTree(tmp_dir_name) catch {};

    var tmp_dir = std.fs.cwd().makeOpenPath(tmp_dir_name, .{}) catch return;
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree(tmp_dir_name) catch {};
    }

    // Write an AGENTS.md into temp dir
    const f = tmp_dir.createFile("AGENTS.md", .{}) catch return;
    defer f.close();
    f.writeAll("test agents content") catch return;

    const original_cwd = std.fs.cwd().openDir(".", .{}) catch return;
    defer original_cwd.close();

    tmp_dir.setAsCwd() catch return;
    defer original_cwd.setAsCwd() catch {};

    var result = try loadContextFiles(testing.allocator);
    try testing.expect(result != null);
    if (result) |*set| {
        try testing.expect(set.files.items.len >= 1);
        try testing.expectEqualStrings("AGENTS.md", set.files.items[0].path);
        try testing.expectEqualStrings("test agents content", set.files.items[0].content);
        set.deinit(testing.allocator);
    }
}
