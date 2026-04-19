const std = @import("std");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// Project memory system — loads CLAUDE.md files from user and project locations
/// and injects them into the system prompt for AI context.
pub const ProjectMemory = struct {
    allocator: Allocator,
    user_memory: []const u8,
    project_memory: []const u8,
    combined: []const u8,
    user_path: []const u8,
    project_path: []const u8,

    pub fn init(allocator: Allocator) ProjectMemory {
        return ProjectMemory{
            .allocator = allocator,
            .user_memory = "",
            .project_memory = "",
            .combined = "",
            .user_path = "",
            .project_path = "",
        };
    }

    /// Load CLAUDE.md files from disk
    pub fn load(self: *ProjectMemory) !void {
        // Free any previous content
        self.clear();

        // 1. User global: ~/.crushcode/CLAUDE.md
        const home = std.posix.getenv("HOME") orelse "";
        if (home.len > 0) {
            const user_path = std.fs.path.join(self.allocator, &.{ home, ".crushcode", "CLAUDE.md" }) catch return;
            if (std.fs.cwd().readFileAlloc(self.allocator, user_path, 1024 * 1024)) |content| {
                self.user_memory = content;
                self.user_path = user_path;
            } else |_| {
                self.allocator.free(user_path);
            }
        }

        // 2. Project-specific: ./.crushcode/CLAUDE.md
        if (std.fs.cwd().readFileAlloc(self.allocator, ".crushcode/CLAUDE.md", 1024 * 1024)) |content| {
            self.project_memory = content;
            self.project_path = self.allocator.dupe(u8, ".crushcode/CLAUDE.md") catch "";
        } else |_| {
            // 3. Project root: ./CLAUDE.md
            if (std.fs.cwd().readFileAlloc(self.allocator, "CLAUDE.md", 1024 * 1024)) |content| {
                self.project_memory = content;
                self.project_path = self.allocator.dupe(u8, "CLAUDE.md") catch "";
            } else |_| {}
        }

        // Build combined
        if (self.user_memory.len > 0 and self.project_memory.len > 0) {
            self.combined = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ self.user_memory, self.project_memory });
        } else if (self.user_memory.len > 0) {
            self.combined = self.user_memory;
        } else if (self.project_memory.len > 0) {
            self.combined = self.project_memory;
        }
    }

    /// Inject loaded memory into a system prompt, returning a new allocated string.
    /// Caller must free the returned string.
    pub fn injectIntoSystemPrompt(self: *ProjectMemory, base_prompt: []const u8) ![]const u8 {
        if (!self.hasMemory()) {
            if (base_prompt.len > 0) {
                return try self.allocator.dupe(u8, base_prompt);
            }
            return "";
        }

        if (base_prompt.len > 0) {
            return try std.fmt.allocPrint(self.allocator, "[Project Context]\n{s}\n\n{s}", .{ self.combined, base_prompt });
        } else {
            return try std.fmt.allocPrint(self.allocator, "[Project Context]\n{s}", .{self.combined});
        }
    }

    /// Reload from disk
    pub fn reload(self: *ProjectMemory) !void {
        try self.load();
    }

    /// Clear loaded memory
    pub fn clear(self: *ProjectMemory) void {
        if (self.combined.len > 0 and self.combined.ptr != self.user_memory.ptr and self.combined.ptr != self.project_memory.ptr) {
            self.allocator.free(self.combined);
        }
        self.combined = "";

        if (self.user_memory.len > 0) self.allocator.free(self.user_memory);
        self.user_memory = "";
        if (self.user_path.len > 0) self.allocator.free(self.user_path);
        self.user_path = "";

        if (self.project_memory.len > 0) self.allocator.free(self.project_memory);
        self.project_memory = "";
        if (self.project_path.len > 0) self.allocator.free(self.project_path);
        self.project_path = "";
    }

    pub fn hasMemory(self: *const ProjectMemory) bool {
        return self.combined.len > 0;
    }

    pub fn totalSize(self: *const ProjectMemory) usize {
        return self.combined.len;
    }

    pub fn deinit(self: *ProjectMemory) void {
        self.clear();
    }
};

const testing = std.testing;

test "ProjectMemory - init has no memory" {
    var pm = ProjectMemory.init(testing.allocator);
    defer pm.deinit();
    try testing.expect(!pm.hasMemory());
    try testing.expectEqual(@as(usize, 0), pm.totalSize());
}

test "ProjectMemory - injectIntoSystemPrompt with no memory returns base" {
    var pm = ProjectMemory.init(testing.allocator);
    defer pm.deinit();
    const result = try pm.injectIntoSystemPrompt("hello");
    defer if (result.len > 0) testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "ProjectMemory - clear on empty is safe" {
    var pm = ProjectMemory.init(testing.allocator);
    pm.clear();
    pm.clear();
    try testing.expect(!pm.hasMemory());
    pm.deinit();
}
