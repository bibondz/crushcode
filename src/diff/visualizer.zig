const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Simple diff visualization
/// Shows git-style diffs with colored output
pub const DiffVisualizer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) DiffVisualizer {
        return DiffVisualizer{
            .allocator = allocator,
        };
    }

    /// Show a simple inline diff
    pub fn showInlineDiff(self: *DiffVisualizer, old_text: []const u8, new_text: []const u8) !void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();

        // Simple word-based diff visualization
        stdout.print("Changes detected:\n", .{}) catch {};

        var old_iter = std.mem.splitScalar(u8, old_text, '\n').iterator();
        var new_iter = std.mem.splitScalar(u8, new_text, '\n').iterator();

        var line_num: usize = 1;
        var diff_count: usize = 0;

        while (true) {
            const old_line_opt = old_iter.next();
            const new_line_opt = new_iter.next();

            if (old_line_opt == null and new_line_opt == null) break;

            const old_line = old_line_opt orelse "";
            const new_line = new_line_opt orelse "";

            if (!std.mem.eql(u8, old_line, new_line)) {
                diff_count += 1;

                stdout.print("  Line {d}:\n", .{line_num}) catch {};
                stdout.print("    - {s}\n", .{old_line}) catch {};
                stdout.print("    + {s}\n", .{new_line}) catch {};
                line_num += 1;
            } else {
                line_num += 1;
            }
        }

        if (diff_count > 0) {
            stdout.print("\n{d} line(s) changed\n", .{diff_count}) catch {};
        } else {
            stdout.print("No changes detected\n", .{}) catch {};
        }
    }

    /// Show unified diff format
    pub fn showUnifiedDiff(self: *DiffVisualizer, file_path: []const u8, old_text: []const u8, new_text: []const u8) !void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();

        stdout.print("Diff for {s}:\n", .{file_path}) catch {};

        var old_iter = std.mem.splitScalar(u8, old_text, '\n').iterator();
        var new_iter = std.mem.splitScalar(u8, new_text, '\n').iterator();

        var line_num: usize = 1;
        var in_old_block = false;
        var in_new_block = false;
        var diff_count: usize = 0;

        while (true) {
            const old_line_opt = old_iter.next();
            const new_line_opt = new_iter.next();

            if (old_line_opt == null and new_line_opt == null) break;

            const old_line = old_line_opt orelse "";
            const new_line = new_line_opt orelse "";

            if (std.mem.eql(u8, old_line, new_line)) {
                // Same line
                if (in_old_block) {
                    stdout.print("  {s}\n", .{old_line}) catch {};
                } else if (in_new_block) {
                    stdout.print("  {s}\n", .{new_line}) catch {};
                } else {
                    stdout.print("    {s}\n", .{old_line}) catch {};
                }
                line_num += 1;
            } else {
                // Different lines - show as diff
                in_old_block = true;
                in_new_block = true;

                stdout.print("-{d}\n", .{line_num}) catch {};
                stdout.print("-{s}\n", .{old_line}) catch {};
                diff_count += 1;
                line_num += 1;

                const next_old = old_iter.next() orelse "";
                const next_new = new_iter.next() orelse "";
                if (!std.mem.eql(u8, next_old, next_new)) {
                    // Different - new block
                    in_old_block = false;
                    in_new_block = false;

                    stdout.print("+{d}\n", .{line_num}) catch {};
                    stdout.print("+{s}\n", .{next_new}) catch {};
                    line_num += 1;
                } else {
                    // Same again - end both blocks
                    in_old_block = false;
                    in_new_block = false;
                }
            }
        }

        if (diff_count > 0) {
            stdout.print("\n{d} change(s)\n", .{diff_count}) catch {};
        } else {
            stdout.print("No changes\n", .{}) catch {};
        }
    }

    /// Compare two files and show diff
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
