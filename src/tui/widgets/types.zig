const std = @import("std");
const core = @import("core_api");
const session_mod = @import("session");

pub const app_version = "0.30.0";

pub const WorkerStatus = enum {
    pending,
    running,
    done,
    @"error",
    cancelled,
};

pub const WorkerItem = struct {
    id: u32,
    task: []const u8,
    status: WorkerStatus,
    result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const Options = struct {
    provider_name: []const u8,
    model_name: []const u8,
    api_key: []const u8,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 4096,
    temperature: f32 = 0.7,
    override_url: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const core.client.ToolCallInfo = null,
};

pub const ToolCallStatus = enum {
    pending,
    success,
    failed,
};

pub const PermissionMode = enum {
    default,
    auto,
    plan,
};

pub const PermissionDecision = enum {
    yes,
    no,
    always,
};

pub const ToolPermission = struct {
    tool_name: []const u8,
    arguments: []const u8,
    preview_diff: ?[]const u8 = null,
};

pub const FallbackProvider = struct {
    provider_name: []const u8,
    api_key: []const u8,
    model_name: []const u8,
    override_url: ?[]const u8,
};

pub const InterruptedSessionCandidate = struct {
    session: session_mod.Session,
    path: []const u8,
};

// --- Constants ---

pub const setup_provider_data = [_][]const u8{
    "openrouter",
    "openai",
    "anthropic",
    "groq",
    "together",
    "gemini",
    "xai",
    "mistral",
    "ollama",
    "zai",
};

pub const recent_files_max: usize = 5;
pub const recent_files_display_max: usize = 3;
pub const tool_diff_max_lines: usize = 80;
pub const session_row_display_max: usize = 8;

pub const recent_file_tool_names = [_][]const u8{ "read_file", "write_file", "edit", "glob" };

pub const context_source_files = [_][]const u8{
    "build.zig",
    "src/main.zig",
    "src/cli/args.zig",
    "src/commands/chat.zig",
    "src/config/config.zig",
    "src/ai/client.zig",
    "src/ai/registry.zig",
    "src/tui/chat_tui_app.zig",
};

/// Discover all .zig source files in src/ directory dynamically
pub fn discoverSourceFiles(allocator: std.mem.Allocator) ![]const []const u8 {
    var files = std.ArrayList([]const u8).initCapacity(allocator, 32) catch
        return fallbackSourceFiles(allocator);
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch
        return fallbackSourceFiles(allocator);
    defer src_dir.close();

    var walker = src_dir.walk(allocator) catch
        return fallbackSourceFiles(allocator);
    defer walker.deinit();

    while (walker.next() catch return fallbackSourceFiles(allocator)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.indexOf(u8, entry.path, "test_") != null) continue;
        if (std.mem.indexOf(u8, entry.basename, "_test.") != null) continue;

        const full_path = std.fmt.allocPrint(allocator, "src/{s}", .{entry.path}) catch continue;
        files.append(allocator, full_path) catch continue;
    }

    files.append(allocator, allocator.dupe(u8, "build.zig") catch "") catch {};

    if (files.items.len == 0) return fallbackSourceFiles(allocator);
    return files.toOwnedSlice(allocator) catch fallbackSourceFiles(allocator);
}

fn fallbackSourceFiles(allocator: std.mem.Allocator) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, context_source_files.len);
    for (context_source_files, 0..) |src, i| {
        result[i] = try allocator.dupe(u8, src);
    }
    return result;
}

pub const builtin_tool_schemas = [_]core.ToolSchema{
    .{
        .name = "read_file",
        .description = "Read a file from disk",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "shell",
        .description = "Run a shell command",
        .parameters =
        \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Write full content to a file",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "glob",
        .description = "Find files matching a glob pattern",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Search file contents for text",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"include":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "edit",
        .description = "Replace one exact string in a file",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["file_path","old_string","new_string"]}
        ,
    },
};
