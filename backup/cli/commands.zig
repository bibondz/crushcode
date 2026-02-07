const std = @import("std");
const fs = std.fs;
const parser = @import("openspec/parser.zig");
const common = @import("openspec/common.zig");

pub fn commandList() !void {
    const allocator = std.heap.page_allocator;

    // Get all spec directories
    const spec_dir = "openspec/specs";
    var dir = fs.cwd().openDir(spec_dir, .{}) catch |err| {
        std.debug.print("Error: Cannot open directory '{s}': {s}\n", .{ spec_dir, @errorName(err) });
        return err;
    };
    defer dir.close();

    var spec_count: usize = 0;

    std.debug.print("CrushCode Specifications:\n", .{});
    std.debug.print("═════════════════════════════════════════════════\n", .{});

    // Iterate through directories
    var entry_iter = dir.iterate();
    defer entry_iter.deinit();

    while (try entry_iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check for spec.md file
        const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}/spec.md", .{ entry.name });
        const file = fs.cwd().openFile(spec_path, .{}) catch {
            allocator.free(spec_path);
            continue;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB per spec
        defer allocator.free(content);

        // Parse YAML front matter
        const yaml_parser = parser.YAMLParser.init(allocator, content);
        const metadata = yaml_parser.parseFrontMatter() catch {
            allocator.free(content);
            allocator.free(spec_path);
            continue;
        };

        // Display spec information
        std.debug.print("  {s} - {s}\n", .{ metadata.id, metadata.status });

        spec_count += 1;

        // Free memory
        allocator.free(content);
        allocator.free(spec_path);
    }

    std.debug.print("════════════════════════════════════════\n", .{});
    std.debug.print("\nTotal specs: {}\n", .{spec_count});
}

pub fn commandValidate() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = std.process.args();

    // Skip "validate" command
    _ = args.skip();

    // Get spec file path
    const spec_path = args.next() orelse {
        std.debug.print("Error: No spec file provided\n", .{});
        return;
    };

    // Load and validate spec
    const file = std.fs.cwd().openFile(spec_path, .{}) catch |err| {
        std.debug.print("Error: Cannot open file '{s}': {s}\n", .{ spec_path, @errorName(err) });
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB per spec
    defer allocator.free(content);

    std.debug.print("Validating: {s}\n", .{ spec_path });

    // Parse and validate
    const yaml_parser = parser.YAMLParser.init(allocator, content);
    const metadata = yaml_parser.parseFrontMatter() catch {
        std.debug.print("  ERROR: Invalid front matter\n", .{});
        return;
    };

    // Validate metadata
    if (metadata.id.len == 0 or metadata.status.len == 0) {
        std.debug.print("  ERROR: Missing required fields\n", .{});
        return;
    }

    // Validate status
    const valid_statuses = [_][]const u8{
        "draft", "review", "approved", "implemented", "archived",
    };

    var status_valid = false;
    for (valid_statuses) |status| {
        if (std.mem.eql(u8, metadata.status, status)) {
            status_valid = true;
            break;
        }
    }

    if (!status_valid) {
        std.debug.print("  ERROR: Invalid status: {s}\n", .{ metadata.status });
    }

    std.debug.print("  ✅ Validation complete\n", .{});

    // Clean up
    allocator.free(content);
}

pub fn commandShow() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const args = std.process.args();

    // Skip "show" command
    _ = args.skip();

    // Get ID or file path
    const id_or_path = args.next() orelse {
        std.debug.print("Error: No ID or file provided\n", .{});
        return;
    };

    // Check if it's a file path (contains '/')
    if (std.mem.indexOf(u8, id_or_path, '/') != null) {
        std.debug.print("Showing spec file: {s}\n", .{ id_or_path });

        // Load and display file
        const file = std.fs.cwd().openFile(id_or_path, .{}) catch |err| {
            std.debug.print("Error: Cannot open file '{s}': {s}\n", .{ id_or_path, @errorName(err) });
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Parse YAML front matter
        const yaml_parser = parser.YAMLParser.init(allocator, content);
        const metadata = yaml_parser.parseFrontMatter() catch {
            std.debug.print("  ERROR: Invalid front matter\n", .{});
            return;
        };

        std.debug.print("ID: {s}\n", .{ metadata.id });
        std.debug.print("Status: {s}\n", .{ metadata.status });
        if (metadata.created) |created| {
            std.debug.print("Created: {s}\n", .{ created });
        }
        if (metadata.updated) |updated| {
            std.debug.print("Updated: {s}\n", .{ updated });
        }
        if (metadata.source) |source| {
            std.debug.print("Source: {s}\n", .{ source });
        }

        allocator.free(content);
    } else {
        std.debug.print("Showing spec: {s}\n", .{ id_or_path });

        // Try to load as spec ID
        const spec_path = try std.fmt.allocPrint(allocator, "openspec/specs/{s}/spec.md", .{ id_or_path });
        defer allocator.free(spec_path);

        const file = std.fs.cwd().openFile(spec_path, .{}) catch {
            std.debug.print("Error: Cannot open spec '{s}': {s}\n", .{ spec_path, @errorName(err) });
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const yaml_parser = parser.YAMLParser.init(allocator, content);
        const metadata = yaml_parser.parseFrontMatter() catch {
            std.debug.print("  ERROR: Invalid front matter\n", .{});
            return;
        }

        std.debug.print("ID: {s}\n", .{ metadata.id });
        std.debug.print("Status: {s}\n", .{ metadata.status });

        allocator.free(content);
    }
}

pub fn commandInit() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Initializing OpenSpec structure...\n", .{});

    // Create openspec directory
    const openspec_dir = "openspec";
    fs.cwd().makeDir(openspec_dir, .{}) catch |err| {
        std.debug.print("Error: Cannot create directory '{s}': {s}\n", .{ openspec_dir, @errorName(err) });
        return err;
    };

    // Create subdirectories
    const dirs = [_][]const u8{ "specs", "changes", "archives" };
    for (dirs) |dir| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ openspec_dir, dir });
        fs.cwd().makeDir(dir_path, .{}) catch |err| {
            std.debug.print("Error: Cannot create directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
            return err;
        };
        allocator.free(dir_path);
    }

    // Create sample spec
    const specs_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ openspec_dir, "specs" });
    fs.cwd().makeDir(specs_dir, .{}) catch |err| {
        std.debug.print("Error: Cannot create directory '{s}': {s}\n", .{ specs_dir, @errorName(err) });
        return err;
    };

    const sample_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ specs_dir, "sample" });
    fs.cwd().makeDir(sample_dir, .{}) catch |err| {
        std.debug.print("Error: Cannot create directory '{s}': {s}\n", .{ sample_dir, @errorName(err) });
        return err;
    };
    allocator.free(sample_dir);

    // Create sample spec file
    const sample_path = try std.fmt.allocPrint(allocator, "{s}/{s}/spec.md", .{ sample_dir, "sample" });
    defer allocator.free(sample_path);

    const sample_file = fs.cwd().createFile(sample_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create file '{s}': {s}\n", .{ sample_path, @errorName(err) });
        return err;
    };
    defer sample_file.close();

    const sample_content =
        \\---
        \\id: sample
        \\status: draft
        \\source: crushcode init
        \\---
        \\
        \\# Sample Spec
        \\
        \\## Purpose
        \\
        \\This is a sample specification created by crushcode.
        \\
        \\## Requirements
        \\
        \\### Requirement: Example
        \\
        \\The system SHALL demonstrate sample functionality.
        \\
        \\#### Scenario: Basic Usage
        \\- GIVEN the user has crushcode installed
        \\- WHEN they run `crushcode list`
        \\- THEN it SHALL list available specifications
        \\
        \\
        \\## Implementation Notes
        \\
        \\This is just a sample for testing purposes.
    ;

    _ = sample_file.writeAll(sample_content) catch |err| {
        std.debug.print("Error: Cannot write to file '{s}': {s}\n", .{ sample_path, @errorName(err) });
        return err;
    };

    // Free allocated memory
    allocator.free(sample_path);
    allocator.free(sample_dir);
    allocator.free(specs_dir);
    allocator.free(openspec_dir);

    std.debug.print("✅ OpenSpec structure initialized\n", .{});
    std.debug.print("\nCreated directories:\n", .{});
    std.debug.print("  openspec/\n", .{});
    std.debug.print("  openspec/specs/\n", .{});
    std.debug.print("  openspec/specs/sample/\n", .{});
    std.debug.print("  openspec/changes/\n", .{});
    std.debug.print("  openspec/archives/\n", .{});
    std.debug.print("\nCreated sample spec: openspec/specs/sample/spec.md\n", .{});
}

pub fn commandArchive() !void {
    const allocator = std.heap.page_allocator;

    // Get change ID
    const args = std.process.args();
    _ = args.skip();
    const change_id = args.next() orelse {
        std.debug.print("Error: No change ID provided\n", .{});
        return;
    };

    // Construct paths
    const changes_dir = "openspec/changes";
    const change_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ changes_dir, change_id });
    defer allocator.free(change_path);

    const archives_dir = "openspec/archives";
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archives_dir, change_id });
    defer allocator.free(archive_path);

    // Check if change exists
    if (fs.cwd().access(change_path, .{})) {
        // Move to archives
        fs.cwd().rename(change_path, archive_path) catch |err| {
            std.debug.print("Error: Cannot move '{s} to '{s}': {s}\n", .{ change_path, archive_path, @errorName(err) });
            return err;
        }

        std.debug.print("✅ Archived change: {s}\n", .{ change_id });
        std.debug.print("Moved to: {s}\n", .{ archive_path });
    } else {
        std.debug.print("Error: Change '{s}' not found\n", .{ change_id });
    }

    // Free memory
    allocator.free(archive_path);
    allocator.free(changes_dir);
    allocator.free(archives_dir);
}