const std = @import("std");
const core = @import("core_api");
const session_mod = @import("session");

pub const app_version = "1.2.0";

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
    tool_tier: []const u8 = "unknown",
    diff_refresh_count: u32 = 0,
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
    .{
        .name = "list_directory",
        .description = "List directory contents",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}
        ,
    },
    .{
        .name = "create_file",
        .description = "Create a new file with content",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "move_file",
        .description = "Move/rename a file",
        .parameters =
        \\{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}
        ,
    },
    .{
        .name = "copy_file",
        .description = "Copy a file",
        .parameters =
        \\{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}
        ,
    },
    .{
        .name = "delete_file",
        .description = "Delete a file",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "file_info",
        .description = "Get file metadata (size, modified time, permissions)",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "git_status",
        .description = "Show git working tree status",
        .parameters =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "git_diff",
        .description = "Show git diff of changes",
        .parameters =
        \\{"type":"object","properties":{"cached":{"type":"boolean"},"file":{"type":"string"}},"required":[]}
        ,
    },
    .{
        .name = "git_log",
        .description = "Show git commit history",
        .parameters =
        \\{"type":"object","properties":{"count":{"type":"integer"},"oneline":{"type":"boolean"}},"required":[]}
        ,
    },
    .{
        .name = "search_files",
        .description = "Search files by name pattern",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "web_fetch",
        .description = "Fetch content from a URL. Returns text extracted from web pages.",
        .parameters =
        \\{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch"},"path":{"type":"string","description":"Alternative name for url parameter"}},"required":["url"]}
        ,
    },
    .{
        .name = "web_search",
        .description = "Search the web using DuckDuckGo. Returns search results with titles, URLs, and snippets.",
        .parameters =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","description":"Max results to return (1-10, default 5)"}},"required":["query"]}
        ,
    },
    .{
        .name = "image_display",
        .description = "Display an image file in the terminal. Returns image metadata (dimensions, format, size).",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string","description":"Path to the image file to display"}},"required":["file_path"]}
        ,
    },
    .{
        .name = "edit_batch",
        .description = "Apply multiple file edits atomically. All succeed or all are rolled back.",
        .parameters =
        \\{"type":"object","properties":{"edits":{"type":"array","items":{"type":"object","properties":{"file_path":{"type":"string"},"operation":{"type":"string","enum":["create","replace","append","delete_content"]},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["file_path","operation"]}}},"required":["edits"]}
        ,
    },
    .{
        .name = "lsp_definition",
        .description = "Find the definition of a symbol at a specific position.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["file_path","line","character"]}
        ,
    },
    .{
        .name = "lsp_references",
        .description = "Find all references to a symbol at a position.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["file_path","line","character"]}
        ,
    },
    .{
        .name = "lsp_diagnostics",
        .description = "Check for issues in a file.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}
        ,
    },
    .{
        .name = "lsp_hover",
        .description = "Get type info and docs for a symbol at a position.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["file_path","line","character"]}
        ,
    },
    .{
        .name = "lsp_symbols",
        .description = "List all symbols defined in a file.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}
        ,
    },
    .{
        .name = "lsp_rename",
        .description = "Preview renaming a symbol across the workspace.",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"},"new_name":{"type":"string"}},"required":["file_path","line","character","new_name"]}
        ,
    },
    .{
        .name = "todo_write",
        .description = "Manage a todo list. Create, update, or list todo items with status tracking.",
        .parameters =
        \\{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed","cancelled"]},"priority":{"type":"string","enum":["high","medium","low"]}},"required":["content"]}}},"required":["todos"]}
        ,
    },
    .{
        .name = "apply_patch",
        .description = "Apply a unified patch with multiple file operations (add, update, delete, move).",
        .parameters =
        \\{"type":"object","properties":{"patch":{"type":"array","items":{"type":"object","properties":{"operation":{"type":"string","enum":["add","update","delete","move"]},"path":{"type":"string"},"content":{"type":"string"},"old_content":{"type":"string"},"new_content":{"type":"string"},"destination":{"type":"string"}},"required":["operation","path"]}}},"required":["patch"]}
        ,
    },
    .{
        .name = "question",
        .description = "Ask the user a question with predefined options. Returns the user's selection.",
        .parameters =
        \\{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"header":{"type":"string"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label","description"]}},"multiple":{"type":"boolean"}},"required":["question","header","options"]}}},"required":["questions"]}
        ,
    },
    .{
        .name = "subagent",
        .description = "Spawn a focused sub-agent to handle a specific task. Returns the sub-agent's output.",
        .parameters =
        \\{"type":"object","properties":{"description":{"type":"string","description":"Short description of the task"},"prompt":{"type":"string","description":"Detailed instructions for the sub-agent"},"category":{"type":"string","enum":["visual_engineering","deep","quick","general","review","research"],"description":"Agent category"},"tools_allowed":{"type":"array","items":{"type":"string"},"description":"Restrict which tools the sub-agent can use"}},"required":["description","prompt"]}
        ,
    },
};
