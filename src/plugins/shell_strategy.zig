const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

pub const ShellStrategyPlugin = struct {
    allocator: Allocator,
    non_interactive_only: bool,
    banned_commands: std.StringHashMap(void),

    pub fn init(allocator: Allocator) ShellStrategyPlugin {
        var banned_commands = std.StringHashMap(void).init(allocator);

        // Initialize with commonly banned interactive commands
        banned_commands.put("vim", {}) catch {};
        banned_commands.put("nano", {}) catch {};
        banned_commands.put("vi", {}) catch {};
        banned_commands.put("emacs", {}) catch {};
        banned_commands.put("less", {}) catch {};
        banned_commands.put("more", {}) catch {};
        banned_commands.put("man", {}) catch {};
        banned_commands.put("top", {}) catch {};
        banned_commands.put("htop", {}) catch {};
        banned_commands.put("vim.tiny", {}) catch {};
        banned_commands.put("neovim", {}) catch {};

        return ShellStrategyPlugin{
            .allocator = allocator,
            .non_interactive_only = true,
            .banned_commands = banned_commands,
        };
    }

    pub fn deinit(self: *ShellStrategyPlugin) void {
        self.banned_commands.deinit();
    }

    pub fn processCommand(self: *ShellStrategyPlugin, command: []const u8, args: []const []const u8) !ProcessedCommand {
        if (self.banned_commands.contains(command)) {
            return ProcessedCommand{
                .allowed = false,
                .reason = try std.fmt.allocPrint(self.allocator, "Command '{s}' is not allowed in non-interactive mode", .{command}),
                .suggestion = try self.getSuggestion(command),
                .original_command = command,
                .processed_args = null,
            };
        }

        const processed_args = try self.processArguments(args);

        return ProcessedCommand{
            .allowed = true,
            .reason = null,
            .suggestion = null,
            .original_command = command,
            .processed_args = processed_args,
        };
    }

    pub fn processArguments(self: *ShellStrategyPlugin, args: []const []const u8) ![][]const u8 {
        var processed_args = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer processed_args.deinit();

        for (args) |arg| {
            const processed = try self.processSingleArgument(arg);
            try processed_args.append(processed);
        }

        return try processed_args.toOwnedSlice();
    }

    fn processSingleArgument(self: *ShellStrategyPlugin, arg: []const u8) ![]const u8 {
        // Add non-interactive flags to common commands
        if (self.isPackageInstaller(arg)) {
            return try self.addNonInteractiveFlags(arg);
        }

        if (self.isGitCommand(arg)) {
            return try self.addGitNonInteractiveFlags(arg);
        }

        if (self.isConfigCommand(arg)) {
            return try self.addConfigAcceptFlags(arg);
        }

        return arg;
    }

    fn isPackageInstaller(self: *ShellStrategyPlugin, command: []const u8) bool {
        _ = self;

        const installers = [_][]const u8{
            "npm",    "yarn",    "pnpm",
            "pip",    "pip3",    "conda",
            "apt",    "apt-get", "yum",
            "dnf",    "pacman",  "zypper",
            "brew",   "port",    "pkg",
            "pkgin",  "cargo",   "go",
            "nimble",
        };

        for (installers) |installer| {
            if (std.mem.eql(u8, command, installer)) {
                return true;
            }
        }

        return false;
    }

    fn isGitCommand(self: *ShellStrategyPlugin, command: []const u8) bool {
        _ = self;

        const git_commands = [_][]const u8{
            "git",        "git-add",   "git-commit",   "git-push",   "git-pull",   "git-fetch",
            "git-rebase", "git-merge", "git-checkout", "git-branch", "git-status", "git-diff",
            "git-log",    "git-stash", "git-pop",      "git-reset",
        };

        for (git_commands) |git_cmd| {
            if (std.mem.startsWith(u8, command, git_cmd)) {
                return true;
            }
        }

        return false;
    }

    fn isConfigCommand(self: *ShellStrategyPlugin, command: []const u8) bool {
        _ = self;

        const config_commands = [_][]const u8{
            "docker",  "docker-compose", "kubectl", "terraform",
            "ansible", "puppet",         "chef",    "aws",
            "gcloud",  "az",             "doctl",
        };

        for (config_commands) |config_cmd| {
            if (std.mem.startsWith(u8, command, config_cmd)) {
                return true;
            }
        }

        return false;
    }

    fn addNonInteractiveFlags(self: *ShellStrategyPlugin, command: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, command, "npm")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --yes", .{command});
        }

        if (std.mem.startsWith(u8, command, "yarn")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --yes", .{command});
        }

        if (std.mem.startsWith(u8, command, "pip")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --yes", .{command});
        }

        if (std.mem.startsWith(u8, command, "apt")) {
            return try std.fmt.allocPrint(self.allocator, "{s} -y", .{command});
        }

        if (std.mem.startsWith(u8, command, "yum")) {
            return try std.fmt.allocPrint(self.allocator, "{s} -y", .{command});
        }

        if (std.mem.startsWith(u8, command, "brew")) {
            return try std.fmt.allocPrint(self.allocator, "{s}", .{command});
        }

        if (std.mem.startsWith(u8, command, "cargo")) {
            return try std.fmt.allocPrint(self.allocator, "{s}", .{command});
        }

        return command;
    }

    fn addGitNonInteractiveFlags(self: *ShellStrategyPlugin, command: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, command, "git")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --no-pager", .{command});
        }

        if (std.mem.startsWith(u8, command, "git-add")) {
            return command;
        }

        if (std.mem.startsWith(u8, command, "git-commit")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --no-edit", .{command});
        }

        if (std.mem.startsWith(u8, command, "git-rebase")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --interactive=false", .{command});
        }

        if (std.mem.startsWith(u8, command, "git-merge")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --no-edit", .{command});
        }

        return command;
    }

    fn addConfigAcceptFlags(self: *ShellStrategyPlugin, command: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, command, "docker")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --accept", .{command});
        }

        if (std.mem.startsWith(u8, command, "terraform")) {
            return try std.fmt.allocPrint(self.allocator, "{s} --auto-approve", .{command});
        }

        if (std.mem.startsWith(u8, command, "kubectl")) {
            return try std.fmt.allocPrint(self.allocator, "{s}", .{command});
        }

        return command;
    }

    fn getSuggestion(self: *ShellStrategyPlugin, banned_command: []const u8) ![]const u8 {
        if (std.mem.eql(u8, banned_command, "vim")) {
            return "Use 'crushcode edit <file>' instead of vim";
        }

        if (std.mem.eql(u8, banned_command, "nano")) {
            return "Use 'crushcode edit <file>' instead of nano";
        }

        if (std.mem.eql(u8, banned_command, "less")) {
            return "Use 'crushcode read <file>' instead of less";
        }

        if (std.mem.eql(u8, banned_command, "man")) {
            return "Use '--help' flag or online documentation instead of man";
        }

        if (std.mem.eql(u8, banned_command, "top")) {
            return "Use 'crushcode pty list' to monitor sessions";
        }

        return try std.fmt.allocPrint(self.allocator, "Command '{s}' is not available in non-interactive mode", .{banned_command});
    }

    pub fn validateCommand(self: *ShellStrategyPlugin, command: []const u8) !ValidationResult {
        if (self.banned_commands.contains(command)) {
            return ValidationResult{
                .valid = false,
                .error_type = .banned_command,
                .message = try std.fmt.allocPrint(self.allocator, "Command '{s}' is banned in non-interactive mode", .{command}),
            };
        }

        if (self.isInteractiveCommand(command)) {
            return ValidationResult{
                .valid = false,
                .error_type = .interactive_command,
                .message = try std.fmt.allocPrint(self.allocator, "Command '{s}' requires interactive mode", .{command}),
            };
        }

        return ValidationResult{
            .valid = true,
            .error_type = null,
            .message = null,
        };
    }

    fn isInteractiveCommand(self: *ShellStrategyPlugin, command: []const u8) bool {
        _ = self;

        const interactive_patterns = [_][]const u8{
            "vim",  "vi",    "emacs",  "nano", "neovim", "vim.tiny",
            "less", "more",  "most",   "man",  "info",   "top",
            "htop", "iotop", "python", "node", "irb",    "pry",
            "ghci",
        };

        for (interactive_patterns) |pattern| {
            if (std.mem.startsWith(u8, command, pattern)) {
                return true;
            }
        }

        return false;
    }

    pub fn getInstructions(self: *ShellStrategyPlugin) ![]const u8 {
        const instructions =
            \\# Non-Interactive Shell Strategy
            \\
            \\When executing shell commands in Crushcode:
            \\
            \\## 1. ALWAYS use non-interactive flags:
            \\- Package managers: -y, --yes, --no-confirm
            \\- Git: --no-edit, --no-pager, --interactive=false  
            \\- Config tools: --accept, --auto-approve
            \\
            \\## 2. AVOID interactive tools:
            \\- Editors: vim, nano, vi, emacs, neovim
            \\- Pagers: less, more, most, man
            \\- REPLs: python, node, irb (use -c instead)
            \\
            \\## 3. USE Crushcode tools instead:
            \\- File editing: crushcode read/write/edit
            \\- Terminal management: crushcode pty
            \\- Process monitoring: crushcode pty list
            \\
            \\## 4. Package Manager Examples:
            \\- npm init -y (not npm init)
            \\- apt install -y package (not apt install package)
            \\- pip install --yes package (not pip install package)
            \\
            \\## 5. Git Examples:
            \\- git commit --no-edit -m "message" (not git commit)
            \\- git rebase --interactive=false (not git rebase -i)
            \\- git add --all (not git add -p)
            \\
            \\This ensures commands work reliably in automation contexts.
        ;

        const result = try self.allocator.alloc(u8, instructions.len);
        @memcpy(result, instructions);
        return result;
    }
};

pub const ProcessedCommand = struct {
    allowed: bool,
    reason: ?[]const u8,
    suggestion: ?[]const u8,
    original_command: []const u8,
    processed_args: ?[][]const u8,
};

pub const ValidationResult = struct {
    valid: bool,
    error_type: ?ValidationErrorType,
    message: ?[]const u8,
};

pub const ValidationErrorType = enum {
    banned_command,
    interactive_command,
    dangerous_option,
};
