const builtin = @import("builtin");
const std = @import("std");
const file_compat = @import("file_compat");
const env = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");

const Allocator = std.mem.Allocator;

const InstallTarget = enum {
    user,
    global,
};

const InstallOptions = struct {
    target: InstallTarget = .user,
    version: ?[]const u8 = null,
    uninstall: bool = false,
    help: bool = false,
    print: bool = false,
};

/// Install command — downloads crushcode binary from GitHub releases or builds from source
pub const Installer = struct {
    const version = "0.31.0";
    const releases_base = "https://github.com/crushcode/crushcode/releases";

    /// Detect the current OS
    pub fn detectOS() []const u8 {
        const target = builtin.target;
        return switch (target.os.tag) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            else => "unknown",
        };
    }

    /// Detect the current architecture
    pub fn detectArch() []const u8 {
        const target = builtin.target;
        return switch (target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            .riscv64 => "riscv64",
            else => "unknown",
        };
    }

    /// Get the binary file name for the current platform
    pub fn binaryName() []const u8 {
        const target = builtin.target;
        if (target.os.tag == .windows) {
            return "crushcode.exe";
        }
        return "crushcode";
    }

    /// Get the download URL for a specific version, OS, and arch
    pub fn downloadURL(allocator: Allocator, ver: []const u8, os: []const u8, arch: []const u8) ![]const u8 {
        const ext = if (std.mem.eql(u8, os, "windows")) ".exe" else "";
        return std.fmt.allocPrint(allocator, "{s}/download/v{s}/crushcode-{s}-{s}{s}", .{ releases_base, ver, os, arch, ext });
    }

    /// Get the latest version tag from GitHub API
    pub fn getLatestVersion(allocator: Allocator) ![]const u8 {
        const api_url = "https://api.github.com/repos/crushcode/crushcode/releases/latest";

        const headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = "crushcode-installer" },
            .{ .name = "Accept", .value = "application/json" },
        };

        const response = http_client.httpGet(allocator, api_url, &headers) catch return error.NetworkError;
        defer allocator.free(response.body);

        if (response.status != .ok) return error.NetworkError;

        const data = response.body;
        if (data.len == 0) return error.NetworkError;

        const tag = json_extract.extractString(data, "tag_name") orelse return error.ParseError;
        if (tag.len > 0 and tag[0] == 'v') {
            return try allocator.dupe(u8, tag[1..]);
        }
        return try allocator.dupe(u8, tag);
    }

    /// Download a file from URL to a local path
    pub fn downloadFile(allocator: Allocator, url: []const u8, dest_path: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();

        const headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = "crushcode-installer" },
            .{ .name = "Accept", .value = "application/octet-stream" },
        };

        const dest_file = std.fs.cwd().createFile(dest_path, .{ .truncate = true }) catch |err| {
            try stdout.print("Error: Cannot create file {s}: {}\n", .{ dest_path, err });
            return err;
        };
        defer dest_file.close();

        try stdout.print("Downloading {s}...\n", .{url});

        const response = http_client.httpGet(allocator, url, &headers) catch |err| {
            try stdout.print("Error: Download failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(response.body);

        if (response.status != .ok) {
            try stdout.print("Error: Server returned status {d}\n", .{response.status});
            return error.DownloadFailed;
        }

        const data = response.body;
        try dest_file.writeAll(data);

        if (!std.mem.eql(u8, detectOS(), "windows")) {
            dest_file.chmod(0o755) catch {};
        }

        try stdout.print("Downloaded {d} bytes to {s}\n", .{ data.len, dest_path });
    }

    /// Run the install process
    pub fn runInstall(allocator: Allocator, ver: ?[]const u8, target: InstallTarget) !void {
        const stdout = file_compat.File.stdout().writer();
        const os = detectOS();
        const arch = detectArch();

        try stdout.print("\n=== Crushcode Installer ===\n", .{});
        try stdout.print("Platform: {s}-{s}\n\n", .{ os, arch });

        if (std.mem.eql(u8, os, "unknown") or std.mem.eql(u8, arch, "unknown")) {
            try stdout.print("Error: Unsupported platform. Please build from source:\n", .{});
            try stdout.print("  git clone https://github.com/crushcode/crushcode.git\n", .{});
            try stdout.print("  cd crushcode && zig build\n\n", .{});
            return error.UnsupportedPlatform;
        }

        if (target == .global and !canInstallGlobally()) {
            try stdout.print("Permission denied. Run with sudo or use --user\n", .{});
            return error.AccessDenied;
        }

        const version_to_use = ver orelse version_value: {
            try stdout.print("Fetching latest version...\n", .{});
            const latest = getLatestVersion(allocator) catch {
                try stdout.print("Warning: Could not fetch latest version, using {s}\n", .{version});
                break :version_value version;
            };
            try stdout.print("Latest version: {s}\n", .{latest});
            break :version_value latest;
        };

        const url = try downloadURL(allocator, version_to_use, os, arch);
        defer allocator.free(url);

        const install_dir = try getInstallDir(allocator, target);
        defer allocator.free(install_dir);

        std.fs.cwd().makePath(install_dir) catch |err| {
            try stdout.print("Error: Cannot create directory {s}: {}\n", .{ install_dir, err });
            return err;
        };

        const bin_name = binaryName();
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, bin_name });
        defer allocator.free(dest_path);

        try downloadFile(allocator, url, dest_path);

        try stdout.print("\nVerifying installation...\n", .{});
        const installed_file = std.fs.cwd().openFile(dest_path, .{}) catch {
            try stdout.print("Error: Downloaded file not found\n", .{});
            return error.InstallFailed;
        };
        installed_file.close();

        try stdout.print("{s} installed to {s}\n\n", .{ bin_name, dest_path });

        if (target == .user) {
            try ensureUserPathInBashrc(allocator, install_dir);
        }
        try printPathHint(allocator, install_dir);

        try stdout.print("Run 'crushcode --help' to get started.\n\n", .{});
    }

    /// Get the install directory for the selected target
    pub fn getInstallDir(allocator: Allocator, target: InstallTarget) ![]const u8 {
        if (target == .global) {
            return try allocator.dupe(u8, "/usr/local/bin");
        }

        const home = try env.getHomeDir(allocator);
        defer allocator.free(home);

        return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "bin" });
    }

    fn canInstallGlobally() bool {
        if (builtin.target.os.tag == .windows) return false;
        return std.posix.geteuid() == 0;
    }

    fn ensureUserPathInBashrc(allocator: Allocator, install_dir: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();
        const home = try env.getHomeDir(allocator);
        defer allocator.free(home);

        const bashrc_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".bashrc" });
        defer allocator.free(bashrc_path);

        const export_line = "export PATH=\"$HOME/.local/bin:$PATH\"";
        const bashrc_contents = std.fs.cwd().readFileAlloc(allocator, bashrc_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        defer allocator.free(bashrc_contents);

        if (std.mem.indexOf(u8, bashrc_contents, export_line) != null or std.mem.indexOf(u8, bashrc_contents, install_dir) != null) {
            try stdout.print("~/.local/bin is already configured in ~/.bashrc.\n", .{});
            return;
        }

        const bashrc_exists = if (std.fs.cwd().access(bashrc_path, .{})) true else |_| false;
        const bashrc_file = if (bashrc_exists)
            try std.fs.cwd().openFile(bashrc_path, .{ .mode = .read_write })
        else
            try std.fs.cwd().createFile(bashrc_path, .{ .truncate = false, .read = true });
        defer bashrc_file.close();

        try bashrc_file.seekFromEnd(0);
        if (bashrc_contents.len > 0 and bashrc_contents[bashrc_contents.len - 1] != '\n') {
            try bashrc_file.writeAll("\n");
        }
        try bashrc_file.writeAll(export_line ++ "\n");

        try stdout.print("Added ~/.local/bin to ~/.bashrc.\n", .{});
    }

    /// Print PATH configuration hint
    fn printPathHint(allocator: Allocator, install_dir: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch null;
        defer if (path_env) |value| allocator.free(value);

        if (std.mem.indexOf(u8, path_env orelse "", install_dir) != null) {
            try stdout.print("{s} is already in PATH.\n", .{install_dir});
            return;
        }

        try stdout.print("Restart your shell or run:\n", .{});
        try stdout.print("  export PATH=\"{s}:$PATH\"\n\n", .{install_dir});
    }

    /// Run the uninstall process
    pub fn runUninstall(allocator: Allocator) !void {
        const stdout = file_compat.File.stdout().writer();
        const bin_name = binaryName();
        const targets = [_]InstallTarget{ .user, .global };
        var removed_any = false;

        try stdout.print("\n=== Crushcode Uninstaller ===\n\n", .{});

        for (targets) |target| {
            const install_dir = try getInstallDir(allocator, target);
            defer allocator.free(install_dir);

            const bin_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, bin_name });
            defer allocator.free(bin_path);

            std.fs.cwd().deleteFile(bin_path) catch |err| {
                if (err == error.FileNotFound) continue;
                if (err == error.AccessDenied and target == .global) {
                    try stdout.print("Permission denied. Run with sudo or use --user\n", .{});
                    return error.AccessDenied;
                }
                try stdout.print("Error removing {s}: {}\n", .{ bin_path, err });
                return err;
            };

            removed_any = true;
            try stdout.print("Removed {s}\n", .{bin_path});
        }

        if (!removed_any) {
            try stdout.print("Crushcode is not installed in ~/.local/bin or /usr/local/bin\n", .{});
            return;
        }

        try stdout.print("Uninstallation complete.\n", .{});
        try stdout.print("Note: You may want to remove the PATH entry from your shell config.\n\n", .{});
    }

    /// Print install instructions
    pub fn printInstallInstructions() void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print(
            \\Crushcode Installation
            \\
            \\Quick Install:
            \\  crushcode install
            \\
            \\User install (default):
            \\  crushcode install --user
            \\
            \\Global install:
            \\  crushcode install --global
            \\
            \\Install specific version:
            \\  crushcode install --version 0.2.0
            \\  crushcode install --global --version 0.2.0
            \\
            \\Uninstall:
            \\  crushcode install --uninstall
            \\
            \\Build from source:
            \\  git clone https://github.com/crushcode/crushcode.git
            \\  cd crushcode && zig build
            \\  sudo cp zig-out/bin/crushcode /usr/local/bin/
            \\
            \\Verify: crushcode --version
            \\
        , .{}) catch {};
    }
};

fn printInstallUsage() void {
    const stdout = file_compat.File.stdout().writer();
    stdout.print(
        \\Usage: crushcode install [--user|--global] [--version <version>] [--uninstall] [--help] [--print]
        \\
    , .{}) catch {};
}

fn parseInstallArgs(args: [][]const u8) !InstallOptions {
    var options = InstallOptions{};
    var seen_target = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--global")) {
            if (seen_target and options.target != .global) return error.InvalidArguments;
            options.target = .global;
            seen_target = true;
        } else if (std.mem.eql(u8, arg, "--user")) {
            if (seen_target and options.target != .user) return error.InvalidArguments;
            options.target = .user;
            seen_target = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            options.version = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--uninstall")) {
            options.uninstall = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--print")) {
            options.print = true;
        } else {
            return error.InvalidArguments;
        }
    }

    if (options.uninstall and options.version != null) return error.InvalidArguments;
    return options;
}

/// Handle install command from CLI
pub fn handleInstall(args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    const options = parseInstallArgs(args) catch {
        printInstallUsage();
        return;
    };

    if (options.help) {
        Installer.printInstallInstructions();
    } else if (options.uninstall) {
        try Installer.runUninstall(allocator);
    } else if (options.print) {
        const stdout = file_compat.File.stdout().writer();
        stdout.print(
            \\#!/bin/sh
            \\set -e
            \\echo "Installing Crushcode..."
            \\mkdir -p ~/.local/bin
            \\curl -sL https://github.com/crushcode/crushcode/releases/latest/download/crushcode-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) -o ~/.local/bin/crushcode
            \\chmod +x ~/.local/bin/crushcode
            \\grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            \\echo "Done! Run: crushcode --help"
            \\
        , .{}) catch {};
    } else {
        try Installer.runInstall(allocator, options.version, options.target);
    }
}
