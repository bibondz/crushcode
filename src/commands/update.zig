const builtin = @import("builtin");
const std = @import("std");
const file_compat = @import("file_compat");
const env = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");

const Allocator = std.mem.Allocator;

const current_version = "0.35.0";
const releases_base = "https://github.com/crushcode/crushcode/releases";
const api_base = "https://api.github.com/repos/crushcode/crushcode/releases/latest";

pub const UpdateOptions = struct {
    check_only: bool = false,
    version: ?[]const u8 = null,
    rollback: bool = false,
    help: bool = false,
};

pub const Updater = struct {
    /// Check if a newer version is available on GitHub.
    /// Returns the latest version tag (e.g., "0.26.0") or null if current is latest.
    pub fn checkForUpdate(allocator: Allocator) !?[]const u8 {
        const headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = "crushcode-update-checker" },
            .{ .name = "Accept", .value = "application/json" },
        };

        const response = http_client.httpGet(allocator, api_base, &headers) catch return error.NetworkError;
        defer allocator.free(response.body);

        if (response.status != .ok) return null;

        const tag = json_extract.extractString(response.body, "tag_name") orelse return null;
        const version = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

        // Compare versions — simple string comparison for now
        if (std.mem.eql(u8, version, current_version)) return null;
        if (std.mem.lessThan(u8, version, current_version)) return null;

        return try allocator.dupe(u8, version);
    }

    /// Get the download URL for a specific version, OS, and arch
    fn downloadURL(allocator: Allocator, ver: []const u8) ![]const u8 {
        const target = builtin.target;
        const os = switch (target.os.tag) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            else => "unknown",
        };
        const arch = switch (target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => "unknown",
        };
        const ext = if (target.os.tag == .windows) ".exe" else "";
        return std.fmt.allocPrint(allocator, "{s}/download/v{s}/crushcode-{s}-{s}{s}", .{ releases_base, ver, os, arch, ext });
    }

    /// Get the path where the current binary is installed.
    fn getCurrentBinaryPath(allocator: Allocator) ![]const u8 {
        const self_exe = try std.fs.selfExePathAlloc(allocator);
        return self_exe;
    }

    /// Run the update process.
    pub fn runUpdate(allocator: Allocator, options: UpdateOptions) !void {
        const stdout = file_compat.File.stdout().writer();

        if (options.help) {
            printUpdateHelp();
            return;
        }

        if (options.rollback) {
            try runRollback(allocator);
            return;
        }

        // Determine version to install
        const version_to_install = options.version orelse ver_block: {
            try stdout.print("Checking for updates...\n", .{});
            const latest = checkForUpdate(allocator) catch |err| {
                try stdout.print("Failed to check for updates: {}\n", .{err});
                return err;
            };
            if (latest) |v| {
                try stdout.print("Update available: v{s} -> v{s}\n", .{ current_version, v });
                break :ver_block v;
            } else {
                try stdout.print("Already on latest version (v{s})\n", .{current_version});
                return;
            }
        };
        defer if (options.version == null) allocator.free(version_to_install);

        if (options.check_only) {
            try stdout.print("Update available: v{s} -> v{s}\n", .{ current_version, version_to_install });
            try stdout.print("Run 'crushcode update' to install.\n", .{});
            return;
        }

        // Download
        const url = try downloadURL(allocator, version_to_install);
        defer allocator.free(url);

        try stdout.print("Downloading crushcode v{s}...\n", .{version_to_install});

        const headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = "crushcode-updater" },
            .{ .name = "Accept", .value = "application/octet-stream" },
        };

        const response = http_client.httpGet(allocator, url, &headers) catch |err| {
            try stdout.print("Download failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(response.body);

        if (response.status != .ok) {
            try stdout.print("Server returned status {d}\n", .{@intFromEnum(response.status)});
            return error.DownloadFailed;
        }

        // Get current binary path
        const current_path = try getCurrentBinaryPath(allocator);
        defer allocator.free(current_path);

        // Backup current binary for rollback
        const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{current_path});
        defer allocator.free(backup_path);

        // Try to rename current to backup
        std.fs.cwd().rename(current_path, backup_path) catch |err| {
            try stdout.print("Warning: Could not backup current binary: {}\n", .{err});
            // Continue anyway — may not have write permission to current location
        };

        // Write new binary to temp location first, then atomic rename
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.new", .{current_path});
        defer allocator.free(tmp_path);

        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer tmp_file.close();
        try tmp_file.writeAll(response.body);

        // Make executable (Unix)
        if (builtin.target.os.tag != .windows) {
            tmp_file.chmod(0o755) catch {};
        }

        // Atomic rename: temp → current
        std.fs.cwd().rename(tmp_path, current_path) catch |err| {
            try stdout.print("Failed to replace binary: {}\n", .{err});
            // Try to restore backup
            std.fs.cwd().rename(backup_path, current_path) catch {};
            return err;
        };

        // Clean up backup (successful update)
        std.fs.cwd().deleteFile(backup_path) catch {};

        try stdout.print("Updated to v{s}!\n", .{version_to_install});
        try stdout.print("   Binary: {s}\n", .{current_path});
    }

    /// Rollback to the previous version.
    fn runRollback(allocator: Allocator) !void {
        const stdout = file_compat.File.stdout().writer();

        const current_path = try getCurrentBinaryPath(allocator);
        defer allocator.free(current_path);

        const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{current_path});
        defer allocator.free(backup_path);

        // Check backup exists
        std.fs.cwd().access(backup_path, .{}) catch {
            try stdout.print("No backup found at {s}\n", .{backup_path});
            return;
        };

        // Restore backup
        std.fs.cwd().rename(backup_path, current_path) catch |err| {
            try stdout.print("Failed to restore backup: {}\n", .{err});
            return err;
        };

        try stdout.print("Rolled back to previous version.\n", .{});
    }

    fn printUpdateHelp() void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print(
            \\Crushcode Self-Update
            \\
            \\Usage:
            \\  crushcode update              Check and install latest version
            \\  crushcode update --check      Check only, don't install
            \\  crushcode update --version X  Install specific version
            \\  crushcode update --rollback   Restore previous version
            \\  crushcode update --help       Show this help
            \\
        , .{}) catch {};
    }
};

fn parseUpdateArgs(args: [][]const u8) !UpdateOptions {
    var options = UpdateOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            options.check_only = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            options.version = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--rollback")) {
            options.rollback = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

/// Handle update command from CLI.
pub fn handleUpdate(args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;
    const options = parseUpdateArgs(args) catch {
        Updater.printUpdateHelp();
        return;
    };
    try Updater.runUpdate(allocator, options);
}
