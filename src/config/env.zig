const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const is_windows = builtin.target.os.tag == .windows;

/// Get the user's home directory.
/// Windows: %USERPROFILE%
/// Unix: $HOME
pub fn getHomeDir(allocator: Allocator) ![]const u8 {
    if (is_windows) {
        return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => error.HomeNotFound,
            else => err,
        };
    }
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => error.HomeNotFound,
            else => fallback_err,
        },
        else => err,
    };
}

/// Config directory — where config.toml, providers.toml, profile.toml, auth/ live.
/// Windows: %APPDATA%\crushcode
/// Unix: $XDG_CONFIG_HOME/crushcode or ~/.config/crushcode
pub fn getConfigDir(allocator: Allocator) ![]const u8 {
    if (is_windows) {
        if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
            return std.fs.path.join(allocator, &.{ appdata, "crushcode" });
        } else |_| {}
        // Fallback: USERPROFILE\AppData\Roaming\crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, "AppData", "Roaming", "crushcode" });
    }
    // Unix: XDG_CONFIG_HOME/crushcode or ~/.config/crushcode
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config| {
        return std.fs.path.join(allocator, &.{ xdg_config, "crushcode" });
    } else |_| {
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "crushcode" });
    }
}

/// Data directory — where sessions/, plugins/, mcp-servers/, models/ live.
/// Windows: %LOCALAPPDATA%\crushcode
/// Unix: $XDG_DATA_HOME/crushcode or ~/.local/share/crushcode
pub fn getDataDir(allocator: Allocator) ![]const u8 {
    if (is_windows) {
        if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |local_appdata| {
            return std.fs.path.join(allocator, &.{ local_appdata, "crushcode" });
        } else |_| {}
        // Fallback: USERPROFILE\AppData\Local\crushcode
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, "AppData", "Local", "crushcode" });
    }
    // Unix: XDG_DATA_HOME/crushcode or ~/.local/share/crushcode
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg_data| {
        return std.fs.path.join(allocator, &.{ xdg_data, "crushcode" });
    } else |_| {
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "crushcode" });
    }
}

/// Cache directory — where update downloads, HTTP cache, temp files live.
/// Windows: %LOCALAPPDATA%\crushcode\cache
/// Unix: $XDG_CACHE_HOME/crushcode or ~/.cache/crushcode
pub fn getCacheDir(allocator: Allocator) ![]const u8 {
    if (is_windows) {
        // Windows: cache lives inside data dir (LOCALAPPDATA\crushcode\cache)
        const data_dir = try getDataDir(allocator);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "cache" });
    }
    // Unix: XDG_CACHE_HOME/crushcode or ~/.cache/crushcode
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg_cache| {
        return std.fs.path.join(allocator, &.{ xdg_cache, "crushcode" });
    } else |_| {
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "crushcode" });
    }
}

/// State directory — where logs/ live.
/// Windows: %LOCALAPPDATA%\crushcode\state
/// Unix: $XDG_STATE_HOME/crushcode or ~/.local/state/crushcode
pub fn getStateDir(allocator: Allocator) ![]const u8 {
    if (is_windows) {
        // Windows: state lives inside data dir (LOCALAPPDATA\crushcode\state)
        const data_dir = try getDataDir(allocator);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "state" });
    }
    // Unix: XDG_STATE_HOME/crushcode or ~/.local/state/crushcode
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg_state| {
        return std.fs.path.join(allocator, &.{ xdg_state, "crushcode" });
    } else |_| {
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
pub fn ensureDir(dir_path: []const u8) !void {
    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}
