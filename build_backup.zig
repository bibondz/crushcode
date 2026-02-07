const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create sub-modules
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const commands_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/handlers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ai_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set up module imports
    main_mod.addImport("cli", cli_mod);
    main_mod.addImport("commands", commands_mod);

    // AI modules
    const providers_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/providers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const registry_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/registry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Chat module
    const chat_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/chat.zig"),
        .target = target,
        .optimize = optimize,
    });

    // AI module can import other AI modules
    ai_mod.addImport("providers", providers_mod);
    registry_mod.addImport("providers", providers_mod);
    chat_mod.addImport("providers", providers_mod);
    chat_mod.addImport("ai", ai_mod);

    // Allow commands to use AI
    commands_mod.addImport("ai", ai_mod);
    commands_mod.addImport("registry", registry_mod);
    commands_mod.addImport("chat", chat_mod);

    // Create executable
    const exe = b.addExecutable(.{
        .name = "crushcode",
        .root_module = main_mod,
    });

    b.installArtifact(exe);
}
