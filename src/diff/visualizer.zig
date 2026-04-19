const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const myers = @import("myers");

const Allocator = std.mem.Allocator;

/// Diff visualization using the Myers O(ND) diff algorithm.
/// Shows git-style unified diffs with colored output.
pub const DiffVisualizer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) DiffVisualizer {
        return DiffVisualizer{
            .allocator = allocator,
        };
    }

    /// Show an inline diff with colored output using Myers algorithm.
    pub fn showInlineDiff(self: *DiffVisualizer, old_text: []const u8, new_text: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();

        const edit_lines = myers.diffToEditScript(self.allocator, old_text, new_text) catch {
            stdout.print("Error computing diff\n", .{}) catch {};
            return;
        };
        defer self.allocator.free(edit_lines);

        var diff_count: usize = 0;

        stdout.print("Changes detected:\n", .{}) catch {};

        for (edit_lines) |line| {
            switch (line.kind) {
                .equal => {},
                .delete => {
                    diff_count += 1;
                    if (line.old_line_num) |n| {
                        stdout.print("  Line {d}:\n", .{n}) catch {};
                    }
                    stdout.print("    - {s}\n", .{line.content}) catch {};
                },
                .insert => {
                    stdout.print("    + {s}\n", .{line.content}) catch {};
                },
            }
        }

        if (diff_count > 0) {
            stdout.print("\n{d} line(s) changed\n", .{diff_count}) catch {};
        } else {
            stdout.print("No changes detected\n", .{}) catch {};
        }
    }

    /// Show unified diff format using Myers algorithm.
    pub fn showUnifiedDiff(self: *DiffVisualizer, old_path: []const u8, old_text: []const u8, new_text: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();

        var result = myers.MyersDiff.diff(self.allocator, old_text, new_text) catch {
            stdout.print("Error computing diff\n", .{}) catch {};
            return;
        };
        defer result.deinit();

        if (result.hunks.len == 0) {
            stdout.print("--- {s}\nNo changes\n", .{old_path}) catch {};
            return;
        }

        const formatted = myers.formatUnifiedDiff(self.allocator, &result, old_path, old_path) catch {
            stdout.print("Error formatting diff\n", .{}) catch {};
            return;
        };
        defer self.allocator.free(formatted);

        stdout.print("{s}", .{formatted}) catch {};
    }

    /// Compare two files and show diff.
    pub fn compareFiles(self: *DiffVisualizer, old_path: []const u8, new_path: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();
        const old_content = std.fs.cwd().readFileAlloc(self.allocator, old_path, 10 * 1024 * 1024) catch {
            stdout.print("Error reading old file '{s}'\n", .{old_path}) catch {};
            return;
        };
        defer self.allocator.free(old_content);

        const new_content = std.fs.cwd().readFileAlloc(self.allocator, new_path, 10 * 1024 * 1024) catch {
            stdout.print("Error reading new file '{s}'\n", .{new_path}) catch {};
            return;
        };
        defer self.allocator.free(new_content);

        try self.showUnifiedDiff(old_path, old_content, new_content);
    }
};
