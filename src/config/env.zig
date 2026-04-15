const std = @import("std");

const Allocator = std.mem.Allocator;

/// Get the user's home directory.
/// Checks HOME (Unix) then USERPROFILE (Windows).
pub fn getHomeDir(allocator: Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => error.HomeNotFound,
            else => fallback_err,
        },
        else => err,
    };
}

/// XDG_CONFIG_HOME/crushcode — defaults to ~/.config/crushcode
/// This is where config.toml, providers.toml, profile.toml, auth/ live.
pub fn getConfigDir(allocator: Allocator) ![]const u8 {
    // Check XDG_CONFIG_HOME first
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config| {
        return std.fs.path.join(allocator, &.{ xdg_config, "crushcode" });
    } else |_| {
        // Fallback: ~/.config/crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "crushcode" });
    }
}

/// XDG_DATA_HOME/crushcode — defaults to ~/.local/share/crushcode
/// This is where sessions/, plugins/, mcp-servers/, models/ live.
pub fn getDataDir(allocator: Allocator) ![]const u8 {
    // Check XDG_DATA_HOME first
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg_data| {
        return std.fs.path.join(allocator, &.{ xdg_data, "crushcode" });
    } else |_| {
        // Fallback: ~/.local/share/crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "crushcode" });
    }
}

/// XDG_CACHE_HOME/crushcode — defaults to ~/.cache/crushcode
/// This is where update downloads, HTTP cache, temp files live.
pub fn getCacheDir(allocator: Allocator) ![]const u8 {
    // Check XDG_CACHE_HOME first
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg_cache| {
        return std.fs.path.join(allocator, &.{ xdg_cache, "crushcode" });
    } else |_| {
        // Fallback: ~/.cache/crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "crushcode" });
    }
}

/// XDG_STATE_HOME/crushcode — defaults to ~/.local/state/crushcode
/// This is where logs/ live.
pub fn getStateDir(allocator: Allocator) ![]const u8 {
    // Check XDG_STATE_HOME first
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg_state| {
        return std.fs.path.join(allocator, &.{ xdg_state, "crushcode" });
    } else |_| {
        // Fallback: ~/.local/state/crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "crushcode" });
    }
}

/// Get the log directory: stateDir/logs
pub fn getLogDir(allocator: Allocator) ![]const u8 {
    const state_dir = try getStateDir(allocator);
    defer allocator.free(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "logs" });
}

/// Get the session directory: dataDir/sessions
pub fn getSessionDir(allocator: Allocator) ![]const u8 {
    const data_dir = try getDataDir(allocator);
    defer allocator.free(data_dir);
    return std.fs.path.join(allocator, &.{ data_dir, "sessions" });
}

/// Get the plugin directory: dataDir/plugins
pub fn getPluginDir(allocator: Allocator) ![]const u8 {
    const data_dir = try getDataDir(allocator);
    defer allocator.free(data_dir);
    return std.fs.path.join(allocator, &.{ data_dir, "plugins" });
}

/// Get the MCP servers directory: dataDir/mcp-servers
pub fn getMCPDir(allocator: Allocator) ![]const u8 {
    const data_dir = try getDataDir(allocator);
    defer allocator.free(data_dir);
    return std.fs.path.join(allocator, &.{ data_dir, "mcp-servers" });
}

/// Ensure a directory exists (mkdir -p equivalent).
/// Returns the same path passed in for chaining convenience.
pub fn ensureDir(dir_path: []const u8) !void {
    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}
