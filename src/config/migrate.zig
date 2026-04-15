const std = @import("std");
const env = @import("env");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// Check if migration from legacy ~/.crushcode/ is needed.
/// Returns true if ~/.crushcode/config.toml exists AND ~/.config/crushcode/ does NOT exist (or is empty).
pub fn needsMigration(allocator: Allocator) bool {
    const home = env.getHomeDir(allocator) catch return false;
    defer allocator.free(home);

    const old_config = std.fs.path.join(allocator, &.{ home, ".crushcode", "config.toml" }) catch return false;
    defer allocator.free(old_config);

    // Check old config exists
    std.fs.cwd().access(old_config, .{}) catch return false;

    // Check if marker exists (already migrated)
    const marker = std.fs.path.join(allocator, &.{ home, ".crushcode", ".migrated" }) catch return false;
    defer allocator.free(marker);
    if (std.fs.cwd().access(marker, .{})) |_| return false else |_| {}

    // Check if new config already exists
    const new_config = env.getConfigDir(allocator) catch return false;
    defer allocator.free(new_config);
    const new_config_file = std.fs.path.join(allocator, &.{ new_config, "config.toml" }) catch return false;
    defer allocator.free(new_config_file);

    // If new config already exists, don't migrate
    if (std.fs.cwd().access(new_config_file, .{})) |_| return false else |_| {}

    return true;
}

/// Run the migration from ~/.crushcode/ to XDG paths.
/// Moves files to their new locations:
///   config.toml, providers.toml, profile.toml → ~/.config/crushcode/
///   sessions/  → ~/.local/share/crushcode/sessions/
///   plugins/   → ~/.local/share/crushcode/plugins/
///   auth/      → ~/.config/crushcode/auth/
///   *.log      → ~/.local/state/crushcode/logs/
pub fn runMigration(allocator: Allocator) !void {
    const stdout = file_compat.File.stdout().writer();

    const home = try env.getHomeDir(allocator);
    defer allocator.free(home);

    const old_dir = try std.fs.path.join(allocator, &.{ home, ".crushcode" });
    defer allocator.free(old_dir);

    const config_dir = try env.getConfigDir(allocator);
    defer allocator.free(config_dir);

    const data_dir = try env.getDataDir(allocator);
    defer allocator.free(data_dir);

    const state_dir = try env.getStateDir(allocator);
    defer allocator.free(state_dir);

    // Ensure target directories exist
    try env.ensureDir(config_dir);
    try env.ensureDir(data_dir);
    try env.ensureDir(state_dir);

    try stdout.print("Migrating ~/.crushcode/ to XDG directories...\n", .{});

    // Config files → ~/.config/crushcode/
    const config_files = [_][]const u8{ "config.toml", "providers.toml", "profile.toml" };
    for (config_files) |filename| {
        try moveFile(allocator, old_dir, config_dir, filename);
    }

    // sessions/ → ~/.local/share/crushcode/sessions/
    try moveDir(allocator, old_dir, data_dir, "sessions");

    // plugins/ → ~/.local/share/crushcode/plugins/
    try moveDir(allocator, old_dir, data_dir, "plugins");

    // mcp-servers/ → ~/.local/share/crushcode/mcp-servers/ (if exists)
    moveDir(allocator, old_dir, data_dir, "mcp-servers") catch {};

    // auth/ → ~/.config/crushcode/auth/
    try moveDir(allocator, old_dir, config_dir, "auth");

    // Write migration marker
    const marker_path = try std.fs.path.join(allocator, &.{ old_dir, ".migrated" });
    defer allocator.free(marker_path);
    const marker_file = std.fs.cwd().createFile(marker_path, .{}) catch return;
    marker_file.close();

    try stdout.print("Migration complete!\n", .{});
    try stdout.print("  Config: {s}\n", .{config_dir});
    try stdout.print("  Data:   {s}\n", .{data_dir});
    try stdout.print("  State:  {s}\n", .{state_dir});
}

/// Move a single file from src_dir/filename to dst_dir/filename
fn moveFile(allocator: Allocator, src_dir: []const u8, dst_dir: []const u8, filename: []const u8) !void {
    const src_path = try std.fs.path.join(allocator, &.{ src_dir, filename });
    defer allocator.free(src_path);

    const dst_path = try std.fs.path.join(allocator, &.{ dst_dir, filename });
    defer allocator.free(dst_path);

    // Check source exists
    std.fs.cwd().access(src_path, .{}) catch return;

    // Read source file
    const src_file = try std.fs.cwd().openFile(src_path, .{});
    defer src_file.close();
    const contents = try src_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    // Write to destination
    const dst_file = try std.fs.cwd().createFile(dst_path, .{});
    defer dst_file.close();
    try dst_file.writeAll(contents);

    // Delete source
    std.fs.cwd().deleteFile(src_path) catch {};
}

/// Move a directory from src_dir/dirname to dst_dir/dirname
fn moveDir(allocator: Allocator, src_dir: []const u8, dst_dir: []const u8, dirname: []const u8) !void {
    const src_path = try std.fs.path.join(allocator, &.{ src_dir, dirname });
    defer allocator.free(src_path);

    const dst_path = try std.fs.path.join(allocator, &.{ dst_dir, dirname });
    defer allocator.free(dst_path);

    // Check source exists and is a directory
    var src_dir_handle = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch return;
    defer src_dir_handle.close();

    // Create destination directory
    std.fs.cwd().makePath(dst_path) catch {};

    // Copy all files
    var walker = src_dir_handle.walk(allocator) catch return;
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const src_file_path = try std.fs.path.join(allocator, &.{ src_path, entry.path });
            defer allocator.free(src_file_path);
            const dst_file_path = try std.fs.path.join(allocator, &.{ dst_path, entry.path });
            defer allocator.free(dst_file_path);

            // Ensure parent dir exists
            if (std.fs.path.dirname(dst_file_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }

            // Read and write
            const sf = std.fs.cwd().openFile(src_file_path, .{}) catch continue;
            defer sf.close();
            const data = sf.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
            defer allocator.free(data);

            const df = std.fs.cwd().createFile(dst_file_path, .{}) catch continue;
            defer df.close();
            df.writeAll(data) catch {};
        }
    }

    // Delete source directory
    std.fs.cwd().deleteTree(src_path) catch {};
}
