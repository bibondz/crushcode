const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI module
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Registry module
    const registry_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/registry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Client module
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("registry", registry_mod);

    // Config module
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Provider config module
    const provider_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/provider_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // File operations module
    const fileops_mod = b.createModule(.{
        .root_source_file = b.path("src/fileops/reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Plugin module
    const plugin_mod = b.createModule(.{ .root_source_file = b.path("src/plugin/interface.zig"), .imports = &.{
        .{ .name = "protocol", .module = b.createModule(.{ .root_source_file = b.path("src/plugin/protocol.zig"), .imports = &.{} }) },
    } });

    // Read module
    const read_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/read.zig"),
        .target = target,
        .optimize = optimize,
    });
    read_mod.addImport("fileops", fileops_mod);

    // Chat module
    const chat_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/chat.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("args", cli_mod);
    chat_mod.addImport("registry", registry_mod);
    chat_mod.addImport("config", config_mod);
    chat_mod.addImport("client", client_mod);
    chat_mod.addImport("provider_config", provider_config_mod);
    chat_mod.addImport("plugin", plugin_mod);

    // Shell module
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/shell.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Handlers module
    const handlers_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/handlers.zig"),
        .target = target,
        .optimize = optimize,
    });
    handlers_mod.addImport("args", cli_mod);
    handlers_mod.addImport("registry", registry_mod);
    handlers_mod.addImport("config", config_mod);
    handlers_mod.addImport("chat", chat_mod);
    handlers_mod.addImport("read", read_mod);
    handlers_mod.addImport("shell", shell_mod);

    // Main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("args", cli_mod);
    main_mod.addImport("handlers", handlers_mod);
    main_mod.addImport("config", config_mod);
    main_mod.addImport("provider_config", provider_config_mod);
    main_mod.addImport("plugin", plugin_mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "crushcode",
        .root_module = main_mod,
    });

    b.installArtifact(exe);
}
