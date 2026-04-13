const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn getHomeDir(allocator: Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => error.HomeNotFound,
            else => fallback_err,
        },
        else => err,
    };
}

pub fn getConfigDir(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".crushcode" });
}

pub fn getDataDir(allocator: Allocator) ![]const u8 {
    return getConfigDir(allocator);
}
