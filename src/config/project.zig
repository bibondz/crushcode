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
