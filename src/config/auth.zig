const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Authentication credentials stored separately from config for security
/// Stored in ~/.crushcode/auth.json
pub const Auth = struct {
    allocator: std.mem.Allocator,
    keys: std.StringHashMap(Credential),

    pub const Credential = struct {
        key: []const u8,
        added: i64,

        pub fn deinit(self: *Credential, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Auth {
        return Auth{
            .allocator = allocator,
            .keys = std.StringHashMap(Credential).init(allocator),
        };
    }

    pub fn deinit(self: *Auth) void {
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.keys.deinit();
    }

    /// Get the auth file path
    pub fn getAuthPath(allocator: std.mem.Allocator) ![]const u8 {
        if (std.process.getEnvVarOwned(allocator, "CRUSHCODE_AUTH")) |path| {
            return path;
        } else |_| {}

        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |userprofile| {
                    return std.fmt.allocPrint(allocator, "{s}\\.crushcode\\auth.json", .{userprofile});
                } else |_| {
                    return error.HomeNotFound;
                }
            }
            return err;
        };

        return std.fmt.allocPrint(allocator, "{s}/.crushcode/auth.json", .{home});
    }

    /// Load auth data from file
    pub fn load(self: *Auth) !void {
        const auth_path = try Auth.getAuthPath(self.allocator);
        defer self.allocator.free(auth_path);

        const file = std.fs.cwd().openFile(auth_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        try self.parseJson(buffer);
    }

    /// Parse JSON auth data
    fn parseJson(self: *Auth, content: []const u8) !void {
        // Simple JSON parsing for {"provider": {"key": "...", "added": ...}}
        var i: usize = 0;

        // Find opening brace
        while (i < content.len and content[i] != '{') : (i += 1) {}
        if (i >= content.len) return;

        i += 1; // skip '{'
        while (i < content.len) {
            // Skip whitespace
            while (i < content.len and std.mem.indexOfScalar(u8, " \t\n\r", content[i]) != null) : (i += 1) {}
            if (i >= content.len) break;

            // Check for closing brace
            if (content[i] == '}') break;

            // Parse key (provider name)
            if (content[i] != '"') break;
            i += 1;
            const key_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const key_end = i;
            i += 1; // skip '"'

            // Skip to value
            while (i < content.len and content[i] != ':') : (i += 1) {}
            i += 1;

            // Skip whitespace
            while (i < content.len and std.mem.indexOfScalar(u8, " \t\n\r", content[i]) != null) : (i += 1) {}
            if (i >= content.len) break;

            // Parse value object
            if (content[i] != '{') break;
            i += 1;

            var cred_key: []const u8 = "";
            var cred_added: i64 = 0;

            while (i < content.len) {
                // Skip whitespace
                while (i < content.len and std.mem.indexOfScalar(u8, " \t\n\r", content[i]) != null) : (i += 1) {}
                if (i >= content.len) break;

                if (content[i] == '}') {
                    i += 1;
                    break;
                }

                // Parse field key
                if (content[i] != '"') break;
                i += 1;
                const field_start = i;
                while (i < content.len and content[i] != '"') : (i += 1) {}
                const field_end = i;
                i += 1;

                // Skip to value
                while (i < content.len and content[i] != ':') : (i += 1) {}
                i += 1;

                // Skip whitespace
                while (i < content.len and std.mem.indexOfScalar(u8, " \t\n\r", content[i]) != null) : (i += 1) {}

                if (std.mem.eql(u8, content[field_start..field_end], "key")) {
                    // Parse string value
                    if (content[i] == '"') {
                        i += 1;
                        const val_start = i;
                        while (i < content.len and content[i] != '"') : (i += 1) {}
                        cred_key = try self.allocator.dupe(u8, content[val_start..i]);
                        i += 1;
                    }
                } else if (std.mem.eql(u8, content[field_start..field_end], "added")) {
                    // Parse number value
                    const num_start = i;
                    while (i < content.len and std.mem.indexOfScalar(u8, "0123456789-", content[i]) != null) : (i += 1) {}
                    if (i > num_start) {
                        const num_str = content[num_start..i];
                        cred_added = std.fmt.parseInt(i64, num_str, 10) catch 0;
                    }
                }

                // Skip comma or whitespace
                while (i < content.len and std.mem.indexOfScalar(u8, " \t\n\r,", content[i]) != null) : (i += 1) {}
            }

            if (cred_key.len > 0) {
                try self.keys.put(try self.allocator.dupe(u8, content[key_start..key_end]), .{
                    .key = cred_key,
                    .added = cred_added,
                });
            }
        }
    }

    /// Save auth data to file
    pub fn save(self: *Auth) !void {
        const auth_path = try Auth.getAuthPath(self.allocator);
        defer self.allocator.free(auth_path);

        // Ensure directory exists
        const dir = std.fs.path.dirname(auth_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dir);

        const file = try std.fs.cwd().createFile(auth_path, .{});
        defer file.close();

        const json = try self.toJson();
        defer self.allocator.free(json);

        _ = try file.writeAll(json);
    }

    /// Convert to JSON string
    fn toJson(self: *Auth) ![]const u8 {
        var result = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        try result.append('{');

        var iter = self.keys.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try result.append(',');
            first = false;

            try result.append('"');
            try result.appendSlice(entry.key_ptr.*);
            try result.appendSlice("\":{\"key\":\"");
            try result.appendSlice(entry.value_ptr.*.key);
            try result.appendSlice("\",\"added\":");
            const added_str = try std.fmt.allocPrint(self.allocator, "{d}", .{entry.value_ptr.*.added});
            defer self.allocator.free(added_str);
            try result.appendSlice(added_str);
            try result.append('}');
        }

        try result.append('}');

        return result.toOwnedSlice();
    }

    /// Get API key for a provider
    pub fn getKey(self: *Auth, provider: []const u8) ?[]const u8 {
        if (self.keys.get(provider)) |cred| {
            return cred.key;
        }
        return null;
    }

    /// Set API key for a provider
    pub fn setKey(self: *Auth, provider: []const u8, key: []const u8) !void {
        const provider_copy = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(provider_copy);

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        try self.keys.put(provider_copy, .{
            .key = key_copy,
            .added = std.time.timestamp(),
        });
    }

    /// Remove API key for a provider
    pub fn removeKey(self: *Auth, provider: []const u8) void {
        self.keys.remove(provider);
    }

    /// List all providers with credentials
    pub fn listProviders(self: *Auth) []const []const u8 {
        var names = self.allocator.alloc([]const u8, self.keys.count()) catch return &.{};
        var i: usize = 0;
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            names[i] = entry.key_ptr.*;
            i += 1;
        }
        return names;
    }
};

test "auth basic" {
    var auth = Auth.init(std.testing.allocator);
    defer auth.deinit();

    try auth.setKey("openai", "sk-test123");
    try auth.setKey("anthropic", "sk-ant-test456");

    try std.testing.expect(std.mem.eql(u8, auth.getKey("openai").?, "sk-test123"));
    try std.testing.expect(std.mem.eql(u8, auth.getKey("anthropic").?, "sk-ant-test456"));
    try std.testing.expect(auth.getKey("unknown") == null);
}
