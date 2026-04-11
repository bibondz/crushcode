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

    // Write module
    const write_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/write.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Git module
    const git_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/git.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_mod.addImport("shell", shell_mod);

    // Skills module
    const skills_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/skills.zig"),
        .target = target,
        .optimize = optimize,
    });
    skills_mod.addImport("shell", shell_mod);

    // TUI module
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/tui.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install module
    const install_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/install.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Jobs module
    const jobs_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/jobs.zig"),
        .target = target,
        .optimize = optimize,
    });
    jobs_mod.addImport("shell", shell_mod);

    // Quantization module (TurboQuant KV cache compression)
    const quantization_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/rotation.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bitpack_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/bitpack.zig"),
        .target = target,
        .optimize = optimize,
    });

    const value_quant_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/value_quant.zig"),
        .target = target,
        .optimize = optimize,
    });

    const key_quant_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/key_quant.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link quantization modules
    key_quant_mod.addImport("rotation", quantization_mod);
    value_quant_mod.addImport("bitpack", bitpack_mod);

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
    handlers_mod.addImport("write", write_mod);
    handlers_mod.addImport("git", git_mod);
    handlers_mod.addImport("skills", skills_mod);
    handlers_mod.addImport("tui", tui_mod);
    handlers_mod.addImport("install", install_mod);
    handlers_mod.addImport("jobs", jobs_mod);

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
