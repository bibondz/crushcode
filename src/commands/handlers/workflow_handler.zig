const std = @import("std");
const args_mod = @import("args");
const workflow_mod = @import("workflow");
const compaction_mod = @import("compaction");
const scaffold_mod = @import("scaffold");
const phase_runner_mod = @import("phase_runner");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleWorkflow(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse args: workflow <name> [--phases N]
    var workflow_name: []const u8 = "default-workflow";
    var phase_count: u32 = 3;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--phases")) {
            i += 1;
            if (i < args.remaining.len) {
                phase_count = std.fmt.parseInt(u32, args.remaining[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--phases=")) {
            phase_count = std.fmt.parseInt(u32, args.remaining[i][9..], 10) catch 3;
        } else if (std.mem.startsWith(u8, args.remaining[i], "--xml")) {
            // skip flag
        } else {
            workflow_name = args.remaining[i];
        }
    }

    var workflow = workflow_mod.PhaseWorkflow.init(allocator, workflow_name) catch return;
    defer workflow.deinit();

    // Add N phases with descriptive names and dependencies
    var phase_idx: u32 = 0;
    while (phase_idx < phase_count) : (phase_idx += 1) {
        const phase_num_f64: f64 = @floatFromInt(phase_idx + 1);

        const name = switch (phase_idx) {
            0 => "Phase 1: Setup",
            1 => "Phase 2: Implementation",
            2 => "Phase 3: Testing",
            else => "Additional Phase",
        };
        const goal = switch (phase_idx) {
            0 => "Initialize project structure and dependencies",
            1 => "Build core features and integrations",
            2 => "Write tests and verify functionality",
            else => "Complete additional work",
        };

        const phase = allocator.create(workflow_mod.WorkflowPhase) catch continue;
        phase.* = workflow_mod.WorkflowPhase.init(allocator, phase_num_f64, name, goal) catch continue;
        if (phase_idx > 0) {
            phase.addDependency(@floatFromInt(phase_idx)) catch {};
        }
        workflow.addPhase(phase) catch {};
    }

    // Progress through the lifecycle: complete first half, start one, leave rest pending
    const phases_to_complete = phase_count / 2;
    var p: u32 = 1;
    while (p <= phases_to_complete) : (p += 1) {
        workflow.startPhase(@floatFromInt(p)) catch {};
        workflow.completePhase(@floatFromInt(p)) catch {};
    }
    // Start the next phase (shows running state)
    if (phases_to_complete < phase_count) {
        workflow.startPhase(@floatFromInt(phases_to_complete + 1)) catch {};
    }

    // Print progress view
    workflow.printProgress();

    // Print XML output
    stdout_print("\n--- Workflow XML ---\n", .{});
    const xml = workflow.toXml(allocator) catch return;
    defer allocator.free(xml);
    stdout_print("{s}\n", .{xml});
}

/// Handle `crushcode phase-run [name] [--phases N] [--no-adversarial]`
/// Runs a multi-phase workflow with adversarial gate checks.
pub fn handlePhaseRun(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var phase_count: u32 = 3;
    var plan_name: []const u8 = "default-plan";
    var use_adversarial = true;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--no-adversarial")) {
            use_adversarial = false;
        } else if (std.mem.eql(u8, args.remaining[i], "--phases")) {
            i += 1;
            if (i < args.remaining.len) {
                phase_count = std.fmt.parseInt(u32, args.remaining[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--phases=")) {
            phase_count = std.fmt.parseInt(u32, args.remaining[i][9..], 10) catch 3;
        } else {
            plan_name = args.remaining[i];
        }
    }

    var runner = phase_runner_mod.PhaseRunner.init(allocator, .{
        .name = plan_name,
        .use_adversarial_gates = use_adversarial,
        .verbose = true,
    }) catch return;
    defer runner.deinit();

    // Add phases based on count
    const phase_templates = [_]struct { name: []const u8, goal: []const u8 }{
        .{ .name = "discuss", .goal = "Gather requirements and clarify scope for the user goal objective feature" },
        .{ .name = "plan", .goal = "Create detailed implementation plan with task steps build create write add fix update" },
        .{ .name = "execute", .goal = "Implement the planned changes and build features done complete success finished" },
        .{ .name = "verify", .goal = "Verify implementation meets requirements with test check criteria success pass validate" },
        .{ .name = "ship", .goal = "Ship the verified changes with pass ok success passed green all tests" },
    };
    const count = @min(phase_count, phase_templates.len);
    for (phase_templates[0..count], 0..) |tmpl, idx| {
        const tasks = [1][]const u8{tmpl.goal};
        const phase_num: f64 = @floatFromInt(idx + 1);
        runner.addPhase(phase_num, tmpl.name, tmpl.goal, &tasks) catch continue;
    }

    stdout_print("\n Running workflow: {s} ({d} phases, adversarial={s})\n\n", .{ plan_name, count, if (use_adversarial) "on" else "off" });

    var result = runner.run() catch {
        stdout_print(" Phase runner failed\n", .{});
        return;
    };
    defer result.deinit();

    runner.workflow.printProgress();
    phase_runner_mod.printResult(&result);
}

pub fn handleCompact(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    // Parse args: compact <file> [--max-tokens N]
    var file_path: ?[]const u8 = null;
    var max_tokens: u64 = 8000;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--max-tokens")) {
            i += 1;
            if (i < args.remaining.len) {
                max_tokens = std.fmt.parseInt(u64, args.remaining[i], 10) catch 8000;
            }
        } else if (std.mem.startsWith(u8, args.remaining[i], "--max-tokens=")) {
            max_tokens = std.fmt.parseInt(u64, args.remaining[i][13..], 10) catch 8000;
        } else if (file_path == null) {
            file_path = args.remaining[i];
        }
    }

    const path = file_path orelse {
        stdout_print("Usage: crushcode compact <file> [--max-tokens N]\n", .{});
        return;
    };

    // Read file content
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        stdout_print("Error reading file '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(content);

    // Count non-empty lines (first pass)
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    if (line_count == 0) {
        stdout_print("File is empty: {s}\n", .{path});
        return;
    }

    // Allocate messages array and fill from lines (second pass)
    const messages = allocator.alloc(compaction_mod.CompactMessage, line_count) catch return;
    defer allocator.free(messages);

    var msg_idx: usize = 0;
    iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) {
            messages[msg_idx] = .{
                .role = if (msg_idx % 2 == 0) "user" else "assistant",
                .content = line,
                .timestamp = null,
            };
            msg_idx += 1;
        }
    }

    // Create compactor and run compaction
    var compactor = compaction_mod.ContextCompactor.init(allocator, max_tokens);
    defer compactor.deinit();

    var estimated_tokens: u64 = 0;
    for (messages) |msg| {
        estimated_tokens += compaction_mod.ContextCompactor.estimateTokens(msg.content);
    }

    compactor.printStatus(estimated_tokens);

    var result = compactor.compact(messages) catch return;
    defer result.deinit();
    stdout_print("\nCompaction Result:\n", .{});
    stdout_print("  Source file: {s}\n", .{path});
    stdout_print("  Total messages: {d}\n", .{line_count});
    stdout_print("  Messages summarized: {d}\n", .{result.messages_summarized});
    stdout_print("  Tokens saved: {d}\n", .{result.tokens_saved});
    stdout_print("  Recent messages preserved: {d}\n", .{result.messages.len});
    if (result.summary.len > 0) {
        stdout_print("\n--- Generated Summary ---\n{s}\n", .{result.summary});
    }
}

// ============================================================
// Scaffold command helpers
// ============================================================

/// Metadata persisted to .crushcode/scaffold/<name>.json
const ScaffoldMeta = struct {
    name: []const u8,
    description: []const u8 = "A project scaffolded by Crushcode",
    tech_stack: []const []const u8 = &[_][]const u8{},
};

fn showScaffoldUsage() void {
    stdout_print("Usage: crushcode scaffold <subcommand> [args...]\n\n", .{});
    stdout_print("Subcommands:\n", .{});
    stdout_print("  new <name> [--stack tech1,tech2]  Create new project scaffolder\n", .{});
    stdout_print("  generate <name> [--dir <dir>]     Generate PROJECT.md, REQUIREMENTS.md, ROADMAP.md\n", .{});
    stdout_print("  requirements <name>               Show requirements for a project\n", .{});
    stdout_print("  phases <name>                     Show phases for a project\n", .{});
    stdout_print("  list                              List saved scaffolders\n\n", .{});
    stdout_print("Examples:\n", .{});
    stdout_print("  crushcode scaffold new my-app --stack zig,sqlite\n", .{});
    stdout_print("  crushcode scaffold generate my-app\n", .{});
    stdout_print("  crushcode scaffold generate my-app --dir ./docs\n", .{});
}

/// Build a ProjectScaffolder with 3 default requirements and 3 phases.
fn createDefaultScaffolder(allocator: std.mem.Allocator, name: []const u8, desc: []const u8) !scaffold_mod.ProjectScaffolder {
    var scaffolder = try scaffold_mod.ProjectScaffolder.init(allocator, name, desc);
    errdefer scaffolder.deinit();

    // REQ-01: Setup (critical)
    const req1 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req1.* = scaffold_mod.Requirement.init(allocator, "REQ-01", "Setup", .critical) catch return error.OutOfMemory;
    req1.setDescription("Project setup and initial configuration") catch {};
    req1.setCategory("Setup") catch {};
    req1.addCriterion("Project structure created") catch {};
    req1.addCriterion("Build system configured") catch {};
    scaffolder.addRequirement(req1) catch {};

    // REQ-02: Core Features (high)
    const req2 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req2.* = scaffold_mod.Requirement.init(allocator, "REQ-02", "Core Features", .high) catch return error.OutOfMemory;
    req2.setDescription("Implement core functionality") catch {};
    req2.setCategory("Features") catch {};
    req2.addCriterion("Main features working") catch {};
    scaffolder.addRequirement(req2) catch {};

    // REQ-03: Testing (medium)
    const req3 = allocator.create(scaffold_mod.Requirement) catch return error.OutOfMemory;
    req3.* = scaffold_mod.Requirement.init(allocator, "REQ-03", "Testing", .medium) catch return error.OutOfMemory;
    req3.setDescription("Write tests for core functionality") catch {};
    req3.setCategory("Testing") catch {};
    req3.addCriterion("Test suite passes") catch {};
    scaffolder.addRequirement(req3) catch {};

    // Phase 1: Foundation
    const ph1 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph1.* = scaffold_mod.ScaffoldPhase.init(allocator, 1, "Foundation") catch return error.OutOfMemory;
    ph1.setDescription("Set up project structure and dependencies") catch {};
    ph1.addRequirement("REQ-01") catch {};
    scaffolder.addPhase(ph1) catch {};

    // Phase 2: Features
    const ph2 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph2.* = scaffold_mod.ScaffoldPhase.init(allocator, 2, "Features") catch return error.OutOfMemory;
    ph2.setDescription("Build core features") catch {};
    ph2.addRequirement("REQ-02") catch {};
    scaffolder.addPhase(ph2) catch {};

    // Phase 3: Polish
    const ph3 = allocator.create(scaffold_mod.ScaffoldPhase) catch return error.OutOfMemory;
    ph3.* = scaffold_mod.ScaffoldPhase.init(allocator, 3, "Polish") catch return error.OutOfMemory;
    ph3.setDescription("Testing, documentation, and polish") catch {};
    ph3.addRequirement("REQ-03") catch {};
    scaffolder.addPhase(ph3) catch {};

    return scaffolder;
}

fn scaffoldSavePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".crushcode/scaffold/{s}.json", .{name});
}

/// Persist scaffold metadata (name, description, tech_stack) to disk.
fn saveScaffoldMeta(allocator: std.mem.Allocator, name: []const u8, desc: []const u8, tech_stack: []const []const u8) !void {
    std.fs.cwd().makePath(".crushcode/scaffold") catch {};

    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"tech_stack\":[", .{ name, desc });
    for (tech_stack, 0..) |tech, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{tech});
    }
    try writer.writeAll("]}");

    const path = try scaffoldSavePath(allocator, name);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Load scaffold metadata from .crushcode/scaffold/<name>.json. Returns null if not found.
fn loadScaffoldMeta(allocator: std.mem.Allocator, name: []const u8) !?ScaffoldMeta {
    const path = try scaffoldSavePath(allocator, name);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ScaffoldMeta, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Dupe all strings before parsed.deinit() frees the arena
    const duped_name = try allocator.dupe(u8, parsed.value.name);
    const duped_desc = try allocator.dupe(u8, parsed.value.description);
    const duped_stack = try allocator.alloc([]const u8, parsed.value.tech_stack.len);
    for (parsed.value.tech_stack, 0..) |tech, i| {
        duped_stack[i] = try allocator.dupe(u8, tech);
    }

    return ScaffoldMeta{
        .name = duped_name,
        .description = duped_desc,
        .tech_stack = duped_stack,
    };
}

fn deinitScaffoldMeta(allocator: std.mem.Allocator, meta: ScaffoldMeta) void {
    allocator.free(meta.name);
    allocator.free(meta.description);
    for (meta.tech_stack) |tech| allocator.free(tech);
    allocator.free(meta.tech_stack);
}

fn scaffoldWriteFile(path: []const u8, content: []const u8) void {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        stdout_print("  Error: could not write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        stdout_print("  Error: could not write content to {s}\n", .{path});
    };
}

/// `crushcode scaffold new <name> [--stack tech1,tech2] [--desc "description"]`
fn scaffoldNew(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var project_name: ?[]const u8 = null;
    var stack_str: ?[]const u8 = null;
    var description: []const u8 = "A new project";

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--stack")) {
            i += 1;
            if (i < rest.len) stack_str = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--stack=")) {
            stack_str = rest[i][8..];
        } else if (std.mem.eql(u8, rest[i], "--desc")) {
            i += 1;
            if (i < rest.len) description = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--desc=")) {
            description = rest[i][7..];
        } else if (project_name == null) {
            project_name = rest[i];
        }
    }

    const name = project_name orelse {
        stdout_print("Usage: crushcode scaffold new <project-name> [--stack tech1,tech2] [--desc \"description\"]\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, description) catch return;
    defer scaffolder.deinit();

    // Add tech stack from --stack or defaults
    if (stack_str) |ss| {
        var tech_iter = std.mem.splitScalar(u8, ss, ',');
        while (tech_iter.next()) |tech| {
            const trimmed = std.mem.trim(u8, tech, " \t");
            if (trimmed.len > 0) {
                scaffolder.addTech(trimmed) catch {};
            }
        }
    } else {
        scaffolder.addTech("Zig") catch {};
        scaffolder.addTech("Zig stdlib") catch {};
    }

    scaffolder.printSummary();

    // Save metadata to .crushcode/scaffold/<name>.json
    saveScaffoldMeta(allocator, name, description, scaffolder.tech_stack.items) catch {
        stdout_print("\nWarning: could not save scaffold metadata to .crushcode/scaffold/\n", .{});
        return;
    };
    stdout_print("\nProject '{s}' saved to .crushcode/scaffold/{s}.json\n", .{ name, name });
}

/// `crushcode scaffold generate <name> [--dir <dir>]`
fn scaffoldGenerate(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var project_name: ?[]const u8 = null;
    var output_dir: []const u8 = ".";

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--dir")) {
            i += 1;
            if (i < rest.len) output_dir = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--dir=")) {
            output_dir = rest[i][6..];
        } else if (project_name == null) {
            project_name = rest[i];
        }
    }

    const name = project_name orelse {
        stdout_print("Usage: crushcode scaffold generate <project-name> [--dir <dir>]\n", .{});
        return;
    };

    // Create scaffolder with defaults
    var scaffolder = createDefaultScaffolder(allocator, name, "A project scaffolded by Crushcode") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state if available
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    // Default tech stack if none loaded
    if (scaffolder.tech_stack.items.len == 0) {
        scaffolder.addTech("Zig") catch {};
        scaffolder.addTech("Zig stdlib") catch {};
    }

    // Generate markdown content
    const project_md = scaffolder.generateProjectMd() catch return;
    defer allocator.free(project_md);
    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);
    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);

    // Ensure output directory exists
    std.fs.cwd().makePath(output_dir) catch {};

    // Write files to disk
    const project_path = std.fmt.allocPrint(allocator, "{s}/PROJECT.md", .{output_dir}) catch return;
    defer allocator.free(project_path);
    const reqs_path = std.fmt.allocPrint(allocator, "{s}/REQUIREMENTS.md", .{output_dir}) catch return;
    defer allocator.free(reqs_path);
    const roadmap_path = std.fmt.allocPrint(allocator, "{s}/ROADMAP.md", .{output_dir}) catch return;
    defer allocator.free(roadmap_path);

    scaffoldWriteFile(project_path, project_md);
    scaffoldWriteFile(reqs_path, reqs_md);
    scaffoldWriteFile(roadmap_path, roadmap_md);

    stdout_print("\n=== Generated files for '{s}' ===\n\n", .{name});
    stdout_print("  {s}/PROJECT.md\n", .{output_dir});
    stdout_print("  {s}/REQUIREMENTS.md\n", .{output_dir});
    stdout_print("  {s}/ROADMAP.md\n\n", .{output_dir});
}

/// `crushcode scaffold list`
fn scaffoldList() void {
    stdout_print("\nSaved scaffolders (.crushcode/scaffold/):\n\n", .{});

    var dir = std.fs.cwd().openDir(".crushcode/scaffold", .{ .iterate = true }) catch {
        stdout_print("  No saved scaffolders found.\n", .{});
        stdout_print("  Use 'crushcode scaffold new <name>' to create one.\n", .{});
        return;
    };
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const name = entry.name[0 .. entry.name.len - 5]; // strip .json
            stdout_print("  {s}\n", .{name});
            count += 1;
        }
    }

    if (count == 0) {
        stdout_print("  No saved scaffolders found.\n", .{});
        stdout_print("  Use 'crushcode scaffold new <name>' to create one.\n", .{});
    } else {
        stdout_print("\n  Total: {d} project(s)\n", .{count});
    }
}

/// `crushcode scaffold requirements <name>`
fn scaffoldRequirements(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const name = if (rest.len > 0) rest[0] else {
        stdout_print("Usage: crushcode scaffold requirements <project-name>\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, "Project requirements") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);

    stdout_print("\n{s}\n", .{reqs_md});
}

/// `crushcode scaffold phases <name>`
fn scaffoldPhases(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const name = if (rest.len > 0) rest[0] else {
        stdout_print("Usage: crushcode scaffold phases <project-name>\n", .{});
        return;
    };

    var scaffolder = createDefaultScaffolder(allocator, name, "Project phases") catch return;
    defer scaffolder.deinit();

    // Load tech stack from saved state
    if (loadScaffoldMeta(allocator, name)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer deinitScaffoldMeta(allocator, meta);
            for (meta.tech_stack) |tech| {
                scaffolder.addTech(tech) catch {};
            }
        }
    } else |_| {}

    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);

    stdout_print("\n{s}\n", .{roadmap_md});
}

/// Handle `crushcode scaffold <subcommand>` — project scaffolding with requirements and phases.
/// Subcommands: new, generate, list, requirements, phases
pub fn handleScaffold(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        showScaffoldUsage();
        return;
    }

    const sub = args.remaining[0];
    const rest = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, sub, "new")) {
        try scaffoldNew(allocator, rest);
    } else if (std.mem.eql(u8, sub, "generate")) {
        try scaffoldGenerate(allocator, rest);
    } else if (std.mem.eql(u8, sub, "list")) {
        scaffoldList();
    } else if (std.mem.eql(u8, sub, "requirements")) {
        try scaffoldRequirements(allocator, rest);
    } else if (std.mem.eql(u8, sub, "phases")) {
        try scaffoldPhases(allocator, rest);
    } else {
        stdout_print("Unknown subcommand: {s}\n\n", .{sub});
        showScaffoldUsage();
    }
}
