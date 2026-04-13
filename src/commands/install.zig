const std = @import("std");
const file_compat = @import("file_compat");
const env = @import("env");
const http_client = @import("http_client");
const json_extract = @import("json_extract");

const Allocator = std.mem.Allocator;

/// Install command — downloads crushcode binary from GitHub releases or builds from source
pub const Installer = struct {
    const version = "0.2.1";
    const github_repo = "crushcode/crushcode";
    const releases_base = "https://github.com/crushcode/crushcode/releases";

    /// Detect the current OS
    pub fn detectOS() []const u8 {
        const target = @import("builtin").target;
        return switch (target.os.tag) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            else => "unknown",
        };
    }

    /// Detect the current architecture
    pub fn detectArch() []const u8 {
        const target = @import("builtin").target;
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
        const target = @import("builtin").target;
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

        // Extract "tag_name":"vX.Y.Z" from JSON response
        const tag = json_extract.extractString(data, "tag_name") orelse return error.ParseError;

        // Strip the 'v' prefix if present
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

        // Open destination file
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

        // Make executable (Unix only)
        if (!std.mem.eql(u8, detectOS(), "windows")) {
            dest_file.chmod(0o755) catch {};
        }

        try stdout.print("Downloaded {d} bytes to {s}\n", .{ data.len, dest_path });
    }

    /// Run the install process
    pub fn runInstall(allocator: Allocator, ver: ?[]const u8) !void {
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

        // Resolve version
        const version_to_use = ver orelse ver: {
            try stdout.print("Fetching latest version...\n", .{});
            const latest = getLatestVersion(allocator) catch {
                try stdout.print("Warning: Could not fetch latest version, using {s}\n", .{version});
                break :ver version;
            };
            try stdout.print("Latest version: {s}\n", .{latest});
            break :ver latest;
        };

        // Build download URL
        const url = try downloadURL(allocator, version_to_use, os, arch);
        defer allocator.free(url);

        // Determine install path
        const install_dir = try getInstallDir(allocator);
        defer allocator.free(install_dir);

        // Ensure directory exists
        std.fs.cwd().makePath(install_dir) catch |err| {
            try stdout.print("Error: Cannot create directory {s}: {}\n", .{ install_dir, err });
            return err;
        };

        const bin_name = binaryName();
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, bin_name });
        defer allocator.free(dest_path);

        // Download
        try downloadFile(allocator, url, dest_path);

        // Verify
        try stdout.print("\nVerifying installation...\n", .{});
        const installed_file = std.fs.cwd().openFile(dest_path, .{}) catch {
            try stdout.print("Error: Downloaded file not found\n", .{});
            return error.InstallFailed;
        };
        installed_file.close();

        try stdout.print("{s} installed to {s}\n\n", .{ bin_name, dest_path });

        // PATH hint
        try printPathHint(allocator, install_dir);

        try stdout.print("Run 'crushcode --help' to get started.\n\n", .{});
    }

    /// Get the install directory (prefers ~/.local/bin)
    pub fn getInstallDir(allocator: Allocator) ![]const u8 {
        // Check CRUSHCODE_INSTALL_DIR env
        if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_INSTALL_DIR")) |dir| {
            return dir;
        } else |_| {}

        // Default to ~/.local/bin
        const home = try env.getHomeDir(allocator);
        defer allocator.free(home);

        return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "bin" });
    }

    /// Print PATH configuration hint
    fn printPathHint(allocator: Allocator, install_dir: []const u8) !void {
        const stdout = file_compat.File.stdout().writer();

        // Check if install_dir is already in PATH
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch null;
        defer if (path_env) |value| allocator.free(value);

        if (std.mem.indexOf(u8, path_env orelse "", install_dir) != null) {
            try stdout.print("{s} is already in PATH.\n", .{install_dir});
            return;
        }

        try stdout.print("Add to your shell config:\n", .{});
        try stdout.print("  export PATH=\"{s}:$PATH\"\n\n", .{install_dir});

        // Detect which rc file to suggest
        const home = env.getHomeDir(allocator) catch return;
        defer allocator.free(home);

        const zshrc = try std.fs.path.join(allocator, &[_][]const u8{ home, ".zshrc" });
        defer allocator.free(zshrc);
        const bashrc = try std.fs.path.join(allocator, &[_][]const u8{ home, ".bashrc" });
        defer allocator.free(bashrc);

        const has_zshrc = if (std.fs.cwd().access(zshrc, .{})) true else |_| false;
        const has_bashrc = if (std.fs.cwd().access(bashrc, .{})) true else |_| false;

        if (has_zshrc) {
            try stdout.print("  echo 'export PATH=\"{s}:$PATH\"' >> ~/.zshrc\n", .{install_dir});
        } else if (has_bashrc) {
            try stdout.print("  echo 'export PATH=\"{s}:$PATH\"' >> ~/.bashrc\n", .{install_dir});
        }
    }

    /// Run the uninstall process
    pub fn runUninstall(allocator: Allocator) !void {
        const stdout = file_compat.File.stdout().writer();

        try stdout.print("\n=== Crushcode Uninstaller ===\n\n", .{});

        const install_dir = try getInstallDir(allocator);
        defer allocator.free(install_dir);

        const bin_name = binaryName();
        const bin_path = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, bin_name });
        defer allocator.free(bin_path);

        // Remove binary
        std.fs.cwd().deleteFile(bin_path) catch |err| {
            if (err == error.FileNotFound) {
                try stdout.print("Crushcode is not installed (file not found: {s})\n", .{bin_path});
                return;
            }
            try stdout.print("Error removing {s}: {}\n", .{ bin_path, err });
            return err;
        };

        try stdout.print("Removed {s}\n", .{bin_path});
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
            \\Install specific version:
            \\  crushcode install --version 0.2.0
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

/// Handle install command from CLI
pub fn handleInstall(args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--uninstall")) {
        try Installer.runUninstall(allocator);
    } else if (args.len > 0 and std.mem.eql(u8, args[0], "--version")) {
        if (args.len > 1) {
            try Installer.runInstall(allocator, args[1]);
        } else {
            const stdout = file_compat.File.stdout().writer();
            stdout.print("Usage: crushcode install --version <version>\n", .{}) catch {};
        }
    } else if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        Installer.printInstallInstructions();
    } else if (args.len > 0 and std.mem.eql(u8, args[0], "--print")) {
        // Print install script for piping
        const stdout = file_compat.File.stdout().writer();
        stdout.print(
            \\#!/bin/sh
            \\set -e
            \\echo "Installing Crushcode..."
            \\mkdir -p ~/.local/bin
            \\curl -sL https://github.com/crushcode/crushcode/releases/latest/download/crushcode-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) -o ~/.local/bin/crushcode
            \\chmod +x ~/.local/bin/crushcode
            \\echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc 2>/dev/null || true
            \\echo "Done! Run: crushcode --help"
            \\
        , .{}) catch {};
    } else {
        // Default: run actual install
        try Installer.runInstall(allocator, null);
    }
}
