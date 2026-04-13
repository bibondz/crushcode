const std = @import("std");
const array_list_compat = @import("array_list_compat");
const env = @import("env");

/// Profile - a named configuration set
/// Profiles allow users to switch between different AI provider configurations
pub const Profile = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    default_provider: []const u8,
    default_model: []const u8,
    system_prompt: []const u8,
    api_keys: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Profile {
        return Profile{
            .allocator = allocator,
            .name = name,
            .default_provider = "",
            .default_model = "",
            .system_prompt = "",
            .api_keys = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Profile) void {
        self.allocator.free(self.name);
        if (self.default_provider.len > 0) self.allocator.free(self.default_provider);
        if (self.default_model.len > 0) self.allocator.free(self.default_model);
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        var iter = self.api_keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.api_keys.deinit();
    }

    /// Get API key for a provider
    pub fn getApiKey(self: *Profile, provider: []const u8) ?[]const u8 {
        return self.api_keys.get(provider);
    }

    /// Set API key for a provider
    pub fn setApiKey(self: *Profile, provider: []const u8, key: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(value_copy);
        try self.api_keys.put(key_copy, value_copy);
    }

    /// Get profile file path
    pub fn getProfilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        const base = try getProfilesDir(allocator);
        const result = std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ base, name });
        allocator.free(base);
        return result;
    }

    /// Load profile from file
    pub fn load(self: *Profile) !void {
        const path = try Profile.getProfilePath(self.allocator, self.name);
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.ProfileNotFound;
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);
        _ = try file.readAll(buffer);

        try self.parseToml(buffer);
    }

    /// Parse TOML content
    fn parseToml(self: *Profile, content: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"\"");

                if (std.mem.eql(u8, key, "default_provider")) {
                    self.default_provider = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "default_model")) {
                    self.default_model = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "system_prompt")) {
                    self.system_prompt = try self.allocator.dupe(u8, value);
                } else {
                    // API key or other key-value
                    try self.setApiKey(key, value);
                }
            }
        }
    }

    /// Save profile to file
    pub fn save(self: *Profile) !void {
        const path = try Profile.getProfilePath(self.allocator, self.name);
        defer self.allocator.free(path);

        // Ensure directory exists
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dir);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var content = array_list_compat.ArrayList(u8).init(self.allocator);
        defer content.deinit();

        try content.appendSlice("# Crushcode Profile: ");
        try content.appendSlice(self.name);
        try content.appendSlice("\n\n");

        if (self.default_provider.len > 0) {
            try content.appendSlice("default_provider = \"");
            try content.appendSlice(self.default_provider);
            try content.appendSlice("\"\n");
        }

        if (self.default_model.len > 0) {
            try content.appendSlice("default_model = \"");
            try content.appendSlice(self.default_model);
            try content.appendSlice("\"\n");
        }

        if (self.system_prompt.len > 0) {
            try content.appendSlice("system_prompt = \"");
            try content.appendSlice(self.system_prompt);
            try content.appendSlice("\"\n");
        }

        if (self.api_keys.count() > 0) {
            try content.appendSlice("\n[api_keys]\n");
            var iter = self.api_keys.iterator();
            while (iter.next()) |entry| {
                try content.appendSlice(entry.key_ptr.*);
                try content.appendSlice(" = \"");
                try content.appendSlice(entry.value_ptr.*);
                try content.appendSlice("\"\n");
            }
        }

        _ = try file.writeAll(content.items);
    }

    /// Get the profiles directory
    pub fn getProfilesDir(allocator: std.mem.Allocator) ![]const u8 {
        const base = try getCrushcodeDir(allocator);
        const result = std.fmt.allocPrint(allocator, "{s}/profiles", .{base});
        allocator.free(base);
        return result;
    }

    /// Get the current profile name file path
    pub fn getCurrentProfilePath(allocator: std.mem.Allocator) ![]const u8 {
        const base = try getCrushcodeDir(allocator);
        const result = std.fmt.allocPrint(allocator, "{s}/current_profile", .{base});
        allocator.free(base);
        return result;
    }

    /// Get the current profile name
    pub fn getCurrentProfileName(allocator: std.mem.Allocator) ![]const u8 {
        const path = try getCurrentProfilePath(allocator);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            allocator.free(path);
            if (err == error.FileNotFound) {
                // Default profile name
                return allocator.dupe(u8, "default");
            }
            return err;
        };
        defer file.close();
        defer allocator.free(path);

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        _ = try file.readAll(buffer);

        const trimmed = std.mem.trimRight(u8, buffer, " \t\n\r");
        const result = try allocator.dupe(u8, trimmed);
        allocator.free(buffer);
        return result;
    }

    /// Set the current profile name
    pub fn setCurrentProfileName(allocator: std.mem.Allocator, name: []const u8) !void {
        const path = try getCurrentProfilePath(allocator);
        defer allocator.free(path);

        // Ensure directory exists
        const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dir);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        _ = try file.writeAll(name);
    }

    /// List all available profiles
    pub fn listProfiles(allocator: std.mem.Allocator) ![][]const u8 {
        const profiles_dir = try getProfilesDir(allocator);
        defer allocator.free(profiles_dir);

        var dir = std.fs.cwd().openDir(profiles_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return @as([][]const u8, &.{});
            }
            return err;
        };
        defer dir.close();

        var names = array_list_compat.ArrayList([]const u8).init(allocator);

        var iter = dir.iterate();
        while (true) {
            const entry = (try iter.next()) orelse break;
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".toml")) continue;
            const profile_name = name[0 .. name.len - 5]; // Remove .toml
            if (std.mem.eql(u8, profile_name, "default")) continue; // Skip default template
            try names.append(try allocator.dupe(u8, profile_name));
        }

        return names.toOwnedSlice();
    }

    /// Create a new profile with defaults
    pub fn createDefault(name: []const u8, allocator: std.mem.Allocator) !Profile {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        var profile = Profile.init(allocator, name_copy);
        profile.default_provider = try allocator.dupe(u8, "openrouter");
        profile.default_model = try allocator.dupe(u8, "openai/gpt-4o-mini");
        return profile;
    }
};

/// Get crushcode base directory
fn getCrushcodeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_DIR")) |path| {
        return path;
    } else |_| {}

    return env.getConfigDir(allocator);
}

/// Load the current active profile
pub fn loadCurrentProfile(allocator: std.mem.Allocator) !Profile {
    const name = try Profile.getCurrentProfileName(allocator);
    // Note: Profile.init takes ownership of name, so we don't free it here.
    // The caller is responsible for calling profile.deinit() which frees name.

    var profile = Profile.init(allocator, name);
    profile.load() catch |err| {
        if (err == error.ProfileNotFound) {
            // Free the old empty profile before creating a new one
            profile.deinit();
            // Create default profile if none exists
            profile = try Profile.createDefault(name, allocator);
            try profile.save();
        } else return err;
    };

    return profile;
}

/// Load a specific profile by name (does not change current profile)
pub fn loadProfileByName(allocator: std.mem.Allocator, name: []const u8) !Profile {
    const name_copy = try allocator.dupe(u8, name);
    var profile = Profile.init(allocator, name_copy);
    profile.load() catch |err| {
        profile.deinit();
        if (err == error.ProfileNotFound) {
            return error.ProfileNotFound;
        }
        return err;
    };
    return profile;
}

/// Handle profile command
pub fn handleProfile(args: []const []const u8) !void {
    const allocator = std.heap.page_allocator;

    if (args.len == 0) {
        try printProfileHelp();
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        try listProfilesCmd(allocator);
    } else if (std.mem.eql(u8, subcmd, "current") or std.mem.eql(u8, subcmd, "show")) {
        try showCurrentProfile(allocator);
    } else if (std.mem.eql(u8, subcmd, "create") or std.mem.eql(u8, subcmd, "new")) {
        if (args.len < 2) {
            std.debug.print("Error: profile name required\n\n", .{});
            try printProfileHelp();
            return;
        }
        try createProfileCmd(allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "switch") or std.mem.eql(u8, subcmd, "use")) {
        if (args.len < 2) {
            std.debug.print("Error: profile name required\n\n", .{});
            try printProfileHelp();
            return;
        }
        try switchProfileCmd(allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm")) {
        if (args.len < 2) {
            std.debug.print("Error: profile name required\n\n", .{});
            try printProfileHelp();
            return;
        }
        try deleteProfileCmd(allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "set")) {
        if (args.len < 3) {
            std.debug.print("Error: usage: profile set <key> <value>\n\n", .{});
            try printProfileHelp();
            return;
        }
        try setProfileValue(allocator, args[1], args[2]);
    } else if (std.mem.eql(u8, subcmd, "help")) {
        try printProfileHelp();
    } else {
        std.debug.print("Unknown subcommand: {s}\n\n", .{subcmd});
        try printProfileHelp();
    }
}

fn listProfilesCmd(allocator: std.mem.Allocator) !void {
    const current = Profile.getCurrentProfileName(allocator);
    const current_name = current catch "default";
    if (@TypeOf(current) == []const u8) allocator.free(current);

    const profiles = Profile.listProfiles(allocator) catch &.{};
    defer {
        for (profiles) |p| allocator.free(p);
        allocator.free(profiles);
    }

    std.debug.print("\nAvailable Profiles:\n\n", .{});

    if (profiles.len == 0) {
        std.debug.print("  (no profiles found, create one with 'crushcode profile create <name>')\n", .{});
    }

    for (profiles) |name| {
        const marker = if (std.mem.eql(u8, name, current_name)) " (active)" else "";
        std.debug.print("  {s}{s}\n", .{ name, marker });
    }

    std.debug.print("\nCurrent profile: {s}\n", .{current_name});
    std.debug.print("\nUse 'crushcode profile switch <name>' to change profiles\n", .{});
}

fn showCurrentProfile(allocator: std.mem.Allocator) !void {
    var profile = try loadCurrentProfile(allocator);
    defer profile.deinit();

    std.debug.print("\nCurrent Profile: {s}\n\n", .{profile.name});
    std.debug.print("  default_provider = \"{s}\"\n", .{profile.default_provider});
    std.debug.print("  default_model = \"{s}\"\n", .{profile.default_model});

    if (profile.system_prompt.len > 0) {
        const preview = if (profile.system_prompt.len > 50)
            profile.system_prompt[0..50]
        else
            profile.system_prompt;
        std.debug.print("  system_prompt = \"{s}...\"\n", .{preview});
    }

    if (profile.api_keys.count() > 0) {
        std.debug.print("\n  API keys configured: {d}\n", .{profile.api_keys.count()});
    }

    std.debug.print("\n", .{});
}

fn createProfileCmd(allocator: std.mem.Allocator, name: []const u8) !void {
    // Duplicate name so Profile owns its copy
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    // Check if profile already exists
    var profile = Profile.init(allocator, name_copy);
    profile.load() catch {
        // Profile doesn't exist, create it
        profile.deinit(); // Free the init's empty profile
        profile = try Profile.createDefault(name, allocator);
        try profile.save();
        std.debug.print("Created profile: {s}\n", .{name});
        std.debug.print("  default_provider = \"{s}\"\n", .{profile.default_provider});
        std.debug.print("  default_model = \"{s}\"\n", .{profile.default_model});
        profile.deinit();
        return;
    };
    profile.deinit();

    std.debug.print("Profile '{s}' already exists\n", .{name});
}

fn switchProfileCmd(allocator: std.mem.Allocator, name: []const u8) !void {
    // Duplicate name so Profile owns its copy
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    // Verify profile exists
    var profile = Profile.init(allocator, name_copy);
    profile.load() catch {
        std.debug.print("Profile '{s}' not found\n", .{name});
        profile.deinit();
        return;
    };
    profile.deinit();

    // Set as current
    try Profile.setCurrentProfileName(allocator, name);
    std.debug.print("Switched to profile: {s}\n", .{name});
}

fn deleteProfileCmd(allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, name, "default")) {
        std.debug.print("Cannot delete 'default' profile\n", .{});
        return;
    }

    const path = try Profile.getProfilePath(allocator, name);
    defer allocator.free(path);

    std.fs.cwd().deleteFile(path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Profile '{s}' not found\n", .{name});
        } else {
            std.debug.print("Error deleting profile: {}\n", .{err});
        }
        return;
    };

    // If this was the current profile, reset to default
    const current = Profile.getCurrentProfileName(allocator) catch "default";
    defer if (@TypeOf(current) == []const u8) allocator.free(current);

    if (std.mem.eql(u8, current, name)) {
        try Profile.setCurrentProfileName(allocator, "default");
    }

    std.debug.print("Deleted profile: {s}\n", .{name});
}

fn setProfileValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    var profile = try loadCurrentProfile(allocator);
    defer profile.deinit();

    if (std.mem.eql(u8, key, "provider") or std.mem.eql(u8, key, "default_provider")) {
        if (profile.default_provider.len > 0) allocator.free(profile.default_provider);
        profile.default_provider = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "default_model")) {
        if (profile.default_model.len > 0) allocator.free(profile.default_model);
        profile.default_model = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "system_prompt")) {
        if (profile.system_prompt.len > 0) allocator.free(profile.system_prompt);
        profile.system_prompt = try allocator.dupe(u8, value);
    } else {
        // Treat as API key
        try profile.setApiKey(key, value);
    }

    try profile.save();
    std.debug.print("Set {s} = \"{s}\" in profile '{s}'\n", .{ key, value, profile.name });
}

fn printProfileHelp() !void {
    std.debug.print(
        \\
        \\Usage: crushcode profile <subcommand>
        \\
        \\Subcommands:
        \\  list, ls          List all profiles
        \\  current, show     Show current profile details
        \\  create <name>     Create a new profile
        \\  switch <name>     Switch to a different profile
        \\  delete <name>     Delete a profile
        \\  set <key> <value> Set a profile value (provider, model, api_key)
        \\
        \\Examples:
        \\  crushcode profile list
        \\  crushcode profile create work
        \\  crushcode profile switch work
        \\  crushcode profile set provider openai
        \\  crushcode profile set model gpt-4o
        \\
        \\Profile files are stored in ~/.crushcode/profiles/
        \\
    , .{});
}
