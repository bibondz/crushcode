const std = @import("std");
const shell_mod = @import("shell");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Diagnostic category for grouping related checks
pub const DiagnosticCategory = enum {
    installation,
    configuration,
    environment,
    tools,
    permissions,
    updates,
};

/// Status of an individual diagnostic check
pub const CheckStatus = enum {
    pass,
    warning,
    fail,
    skip,
};

/// A single diagnostic check result
pub const DiagnosticCheck = struct {
    category: DiagnosticCategory,
    name: []const u8,
    status: CheckStatus,
    message: []const u8,
    details: ?[]const u8 = null,
};

/// Aggregated report of all diagnostic checks
pub const DoctorReport = struct {
    allocator: Allocator,
    checks: array_list_compat.ArrayList(DiagnosticCheck),
    timestamp: i64,

    pub fn init(allocator: Allocator) DoctorReport {
        return DoctorReport{
            .allocator = allocator,
            .checks = array_list_compat.ArrayList(DiagnosticCheck).init(allocator),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *DoctorReport) void {
        self.checks.deinit();
    }

    pub fn addCheck(self: *DoctorReport, check: DiagnosticCheck) !void {
        try self.checks.append(check);
    }

    /// Format the report as readable text. Caller owns the returned slice.
    pub fn formatReport(self: *DoctorReport) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("\xF0\x9F\xA9\xBA Crushcode Doctor Report\n"); // 🩺
        try writer.writeAll("========================\n\n");

        // Group by category
        const categories = [_]DiagnosticCategory{
            .installation,
            .configuration,
            .environment,
            .tools,
            .permissions,
            .updates,
        };

        var total_pass: usize = 0;
        var total_warn: usize = 0;
        var total_fail: usize = 0;
        var total_skip: usize = 0;

        for (&categories) |cat| {
            var cat_has_items = false;
            for (self.checks.items) |check| {
                if (check.category == cat) {
                    if (!cat_has_items) {
                        const cat_label = switch (cat) {
                            .installation => "Installation",
                            .configuration => "Configuration",
                            .environment => "Environment",
                            .tools => "External Tools",
                            .permissions => "Permissions",
                            .updates => "Updates",
                        };
                        try writer.writeAll(" ");
                        try writer.writeAll(statusIcon(.pass)); // category header always shows check
                        try writer.writeAll(" ");
                        try writer.writeAll(cat_label);
                        try writer.writeAll("\n");
                        cat_has_items = true;
                    }

                    const icon = statusIcon(check.status);
                    try writer.print("    {s} {s}: {s}\n", .{ icon, check.name, check.message });
                    if (check.details) |d| {
                        try writer.print("       {s}\n", .{d});
                    }

                    switch (check.status) {
                        .pass => total_pass += 1,
                        .warning => total_warn += 1,
                        .fail => total_fail += 1,
                        .skip => total_skip += 1,
                    }
                }
            }
            if (cat_has_items) {
                try writer.writeAll("\n");
            }
        }

        try writer.print("Summary: {d} passed, {d} warnings, {d} failures", .{ total_pass, total_warn, total_fail });
        if (total_skip > 0) {
            try writer.print(", {d} skipped", .{total_skip});
        }
        try writer.writeAll("\n");

        return buf.toOwnedSlice();
    }
};

fn statusIcon(status: CheckStatus) []const u8 {
    return switch (status) {
        .pass => "\xE2\x9C\x85", // ✅
        .warning => "\xE2\x9A\xA0\xEF\xB8\x8F", // ⚠️
        .fail => "\xE2\x9D\x8C", // ❌
        .skip => "\xE2\x84\xB9\xEF\xB8\x8F", // ℹ️
    };
}

/// Run a shell command and return trimmed stdout. Returns null on failure.
fn runCommand(allocator: Allocator, command: []const u8) ?[]const u8 {
    const result = shell_mod.executeShellCommand(command, null) catch return null;
    if (result.exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// Run a shell command, check only if it succeeds (exit code 0).
fn commandSucceeds(command: []const u8) bool {
    const result = shell_mod.executeShellCommand(command, null) catch return false;
    return result.exit_code == 0;
}

/// Check zig compiler installation
fn checkInstallation(allocator: Allocator) !DiagnosticCheck {
    if (runCommand(allocator, "zig version")) |ver| {
        return DiagnosticCheck{
            .category = .installation,
            .name = "Zig compiler",
            .status = .pass,
            .message = ver,
        };
    } else {
        return DiagnosticCheck{
            .category = .installation,
            .name = "Zig compiler",
            .status = .fail,
            .message = "not found in PATH",
        };
    }
}

fn checkCrushcodeBinary(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    if (commandSucceeds("which crushcode 2>/dev/null")) {
        return DiagnosticCheck{
            .category = .installation,
            .name = "Crushcode binary",
            .status = .pass,
            .message = "found in PATH",
        };
    } else {
        return DiagnosticCheck{
            .category = .installation,
            .name = "Crushcode binary",
            .status = .warning,
            .message = "not found in PATH (may be running from build directory)",
        };
    }
}

fn checkConfiguration(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    const home = std.posix.getenv("HOME") orelse {
        return DiagnosticCheck{
            .category = .configuration,
            .name = "Config directory",
            .status = .fail,
            .message = "HOME not set, cannot locate config",
        };
    };

    const config_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.config/crushcode/", .{home}) catch
        return DiagnosticCheck{
        .category = .configuration,
        .name = "Config directory",
        .status = .fail,
        .message = "memory error constructing path",
    };
    defer std.heap.page_allocator.free(config_path);

    // Check if directory exists
    var dir = std.fs.cwd().openDir(config_path, .{}) catch {
        return DiagnosticCheck{
            .category = .configuration,
            .name = "Config directory",
            .status = .warning,
            .message = "not found",
            .details = config_path,
        };
    };
    dir.close();

    return DiagnosticCheck{
        .category = .configuration,
        .name = "Config directory",
        .status = .pass,
        .message = config_path,
    };
}

fn checkProviders(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    // Check if any provider API keys are set in environment
    var key_count: usize = 0;
    const provider_envs = [_][]const u8{
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "GOOGLE_API_KEY",
        "MISTRAL_API_KEY",
        "GROQ_API_KEY",
        "DEEPSEEK_API_KEY",
    };
    for (&provider_envs) |env_name| {
        if (std.posix.getenv(env_name)) |val| {
            if (val.len > 0) key_count += 1;
        }
    }

    if (key_count > 0) {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "{d} provider(s) configured", .{key_count}) catch "configured";
        return DiagnosticCheck{
            .category = .configuration,
            .name = "API keys",
            .status = .pass,
            .message = msg,
        };
    } else {
        return DiagnosticCheck{
            .category = .configuration,
            .name = "API keys",
            .status = .warning,
            .message = "no provider API keys found in environment",
        };
    }
}

fn checkEnvironment(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    const home = std.posix.getenv("HOME") orelse {
        return DiagnosticCheck{
            .category = .environment,
            .name = "HOME",
            .status = .fail,
            .message = "HOME environment variable not set",
        };
    };

    return DiagnosticCheck{
        .category = .environment,
        .name = "HOME",
        .status = .pass,
        .message = home,
    };
}

fn checkTerminal(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    const term = std.posix.getenv("TERM") orelse {
        return DiagnosticCheck{
            .category = .environment,
            .name = "Terminal",
            .status = .warning,
            .message = "TERM not set (color support unknown)",
        };
    };

    return DiagnosticCheck{
        .category = .environment,
        .name = "Terminal",
        .status = .pass,
        .message = term,
    };
}

fn checkGit(allocator: Allocator) !DiagnosticCheck {
    if (runCommand(allocator, "git --version")) |ver| {
        // Extract version number from "git version 2.43.0"
        const version = if (std.mem.indexOf(u8, ver, "git version ")) |idx|
            ver[idx + "git version ".len ..]
        else
            ver;
        return DiagnosticCheck{
            .category = .tools,
            .name = "git",
            .status = .pass,
            .message = version,
        };
    } else {
        return DiagnosticCheck{
            .category = .tools,
            .name = "git",
            .status = .warning,
            .message = "not found (recommended for version control)",
        };
    }
}

fn checkRipgrep(allocator: Allocator) !DiagnosticCheck {
    if (runCommand(allocator, "rg --version 2>/dev/null")) |ver| {
        // Take just the first line
        const first_line = if (std.mem.indexOfScalar(u8, ver, '\n')) |idx| ver[0..idx] else ver;
        return DiagnosticCheck{
            .category = .tools,
            .name = "ripgrep",
            .status = .pass,
            .message = first_line,
        };
    } else {
        return DiagnosticCheck{
            .category = .tools,
            .name = "ripgrep",
            .status = .warning,
            .message = "not found (optional, improves search)",
        };
    }
}

fn checkNode(allocator: Allocator) !DiagnosticCheck {
    if (runCommand(allocator, "node --version 2>/dev/null")) |ver| {
        return DiagnosticCheck{
            .category = .tools,
            .name = "node",
            .status = .pass,
            .message = ver,
        };
    } else {
        return DiagnosticCheck{
            .category = .tools,
            .name = "node",
            .status = .warning,
            .message = "not found (optional)",
        };
    }
}

fn checkPython(allocator: Allocator) !DiagnosticCheck {
    if (runCommand(allocator, "python3 --version 2>/dev/null")) |ver| {
        return DiagnosticCheck{
            .category = .tools,
            .name = "python",
            .status = .pass,
            .message = ver,
        };
    } else {
        return DiagnosticCheck{
            .category = .tools,
            .name = "python",
            .status = .warning,
            .message = "not found (optional)",
        };
    }
}

fn checkConfigPermissions(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    const home = std.posix.getenv("HOME") orelse {
        return DiagnosticCheck{
            .category = .permissions,
            .name = "Config dir",
            .status = .fail,
            .message = "cannot check (HOME not set)",
        };
    };

    const config_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.config/crushcode/", .{home}) catch
        return DiagnosticCheck{
        .category = .permissions,
        .name = "Config dir",
        .status = .fail,
        .message = "memory error",
    };
    defer std.heap.page_allocator.free(config_path);

    // Try to open and create a temp file to verify read/write
    var dir = std.fs.cwd().openDir(config_path, .{}) catch {
        return DiagnosticCheck{
            .category = .permissions,
            .name = "Config dir",
            .status = .warning,
            .message = "directory does not exist",
        };
    };
    defer dir.close();

    const test_file = dir.createFile(".doctor_test", .{ .truncate = true }) catch {
        return DiagnosticCheck{
            .category = .permissions,
            .name = "Config dir",
            .status = .fail,
            .message = "not writable",
        };
    };
    test_file.close();
    dir.deleteFile(".doctor_test") catch {};

    return DiagnosticCheck{
        .category = .permissions,
        .name = "Config dir",
        .status = .pass,
        .message = "read/write OK",
    };
}

fn checkProjectPermissions(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    // Check current working directory
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch {
        return DiagnosticCheck{
            .category = .permissions,
            .name = "Project dir",
            .status = .fail,
            .message = "cannot determine current directory",
        };
    };

    // Try to create and delete a test file in cwd
    const test_file = std.fs.cwd().createFile(".doctor_test", .{ .truncate = true }) catch {
        return DiagnosticCheck{
            .category = .permissions,
            .name = "Project dir",
            .status = .fail,
            .message = "not writable",
            .details = cwd,
        };
    };
    test_file.close();
    std.fs.cwd().deleteFile(".doctor_test") catch {};

    return DiagnosticCheck{
        .category = .permissions,
        .name = "Project dir",
        .status = .pass,
        .message = "read/write OK",
        .details = cwd,
    };
}

fn checkUpdates(allocator: Allocator) !DiagnosticCheck {
    _ = allocator;
    return DiagnosticCheck{
        .category = .updates,
        .name = "Updates",
        .status = .skip,
        .message = "Use 'git pull' to check for updates",
    };
}

/// Run all diagnostic checks and return a formatted report.
/// Caller owns the returned string.
pub fn runDoctorChecks(allocator: Allocator) ![]const u8 {
    var report = DoctorReport.init(allocator);
    defer report.deinit();

    // Installation checks
    try report.addCheck(try checkInstallation(allocator));
    try report.addCheck(try checkCrushcodeBinary(allocator));

    // Configuration checks
    try report.addCheck(try checkConfiguration(allocator));
    try report.addCheck(try checkProviders(allocator));

    // Environment checks
    try report.addCheck(try checkEnvironment(allocator));
    try report.addCheck(try checkTerminal(allocator));

    // Tool checks
    try report.addCheck(try checkGit(allocator));
    try report.addCheck(try checkRipgrep(allocator));
    try report.addCheck(try checkNode(allocator));
    try report.addCheck(try checkPython(allocator));

    // Permission checks
    try report.addCheck(try checkConfigPermissions(allocator));
    try report.addCheck(try checkProjectPermissions(allocator));

    // Update checks
    try report.addCheck(try checkUpdates(allocator));

    return report.formatReport();
}
