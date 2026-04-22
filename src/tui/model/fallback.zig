// src/tui/model/fallback.zig
// Fallback provider management extracted from chat_tui_app.zig

const std = @import("std");

const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

const config_mod = @import("config");
const registry_mod = @import("registry");
const fallback_mod = @import("fallback");
const widget_types = @import("widget_types");

const FallbackProvider = widget_types.FallbackProvider;
const setup_provider_data = widget_types.setup_provider_data;
const setupDefaultModel = @import("widget_setup").setupDefaultModel;

pub fn loadFallbackProviders(self: *Model) !void {
    var config = config_mod.Config.init(self.allocator);
    defer config.deinit();

    config.loadDefault() catch |err| switch (err) {
        error.ConfigNotFound, error.FileNotFound => {},
        else => return err,
    };

    try appendFallbackProvider(self, self.provider_name, self.api_key, self.model_name, self.override_url);

    for (setup_provider_data) |provider_name| {
        if (std.mem.eql(u8, provider_name, self.provider_name)) continue;
        const provider = self.registry.getProvider(provider_name) orelse continue;
        const api_key = config.getApiKey(provider_name) orelse "";
        if (api_key.len == 0 and !provider.config.is_local) continue;
        const model_name = fallbackModelForProvider(self, provider_name);
        try appendFallbackProvider(self, provider_name, api_key, model_name, config.getProviderOverrideUrl(provider_name));
    }

    self.active_provider_index = findFallbackProviderIndex(self, self.provider_name) orelse 0;
}

pub fn resetFallbackProviders(self: *Model) void {
    self.fallback_chain.deinit();
    self.fallback_chain = fallback_mod.FallbackChain.init(self.allocator);
    for (self.fallback_providers.items) |provider| freeFallbackProvider(self, provider);
    self.fallback_providers.clearRetainingCapacity();
    self.active_provider_index = 0;
}

pub fn appendFallbackProvider(self: *Model, provider_name: []const u8, api_key: []const u8, model_name: []const u8, override_url: ?[]const u8) !void {
    if (findFallbackProviderIndex(self, provider_name) != null) return;

    try self.fallback_chain.addEntry(provider_name, model_name);
    try self.fallback_providers.append(self.allocator, .{
        .provider_name = try self.allocator.dupe(u8, provider_name),
        .api_key = try self.allocator.dupe(u8, api_key),
        .model_name = try self.allocator.dupe(u8, model_name),
        .override_url = if (override_url) |url| try self.allocator.dupe(u8, url) else null,
    });
}

pub fn fallbackModelForProvider(self: *const Model, provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, self.provider_name)) return self.model_name;
    if (std.mem.indexOfScalar(u8, self.model_name, '/') == null) return self.model_name;
    return setupDefaultModel(provider_name);
}

pub fn findFallbackProviderIndex(self: *const Model, provider_name: []const u8) ?usize {
    for (self.fallback_providers.items, 0..) |provider, index| {
        if (std.mem.eql(u8, provider.provider_name, provider_name)) return index;
    }
    return null;
}

pub fn freeFallbackProvider(self: *Model, provider: FallbackProvider) void {
    self.allocator.free(provider.provider_name);
    self.allocator.free(provider.api_key);
    self.allocator.free(provider.model_name);
    if (provider.override_url) |override_url| self.allocator.free(override_url);
}

pub fn classifyToolTier(tool_name: []const u8) []const u8 {
    const read_tools = [_][]const u8{ "read_file", "glob", "grep", "list_directory", "file_info", "git_status", "git_diff", "git_log", "search_files" };
    const write_tools = [_][]const u8{ "write_file", "create_file", "edit", "move_file", "copy_file" };
    const destructive_tools = [_][]const u8{ "delete_file", "shell" };

    for (read_tools) |t| if (std.mem.eql(u8, tool_name, t)) return "READ";
    for (write_tools) |t| if (std.mem.eql(u8, tool_name, t)) return "WRITE";
    for (destructive_tools) |t| if (std.mem.eql(u8, tool_name, t)) return "DESTRUCTIVE";
    return "unknown";
}
