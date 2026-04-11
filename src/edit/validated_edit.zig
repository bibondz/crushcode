const std = @import("std");
const hashline_mod = @import("hashline");
const hash_index_mod = @import("hash_index");
const conflict_mod = @import("conflict");

const Allocator = std.mem.Allocator;
const Hashline = hashline_mod.Hashline;
const HashIndex = hash_index_mod.HashIndex;
const HashCache = hash_index_mod.HashCache;
const Conflict = conflict_mod.Conflict;
const ConflictResolver = conflict_mod.ConflictResolver;
const ResolutionStrategy = conflict_mod.ResolutionStrategy;

/// An edit operation with hash validation
pub const EditOperation = struct {
    file_path: []const u8,
    line_number: u32,
    expected_hash: u32, // Hash of line to replace (0 = append at end)
    old_content: []const u8,
    new_content: []const u8,
};

/// Result of an edit operation
pub const EditResult = union(enum) {
    success: void,
    conflict: Conflict,
    file_not_found,
    hash_mismatch: Conflict,
    line_out_of_range,
    no_hash_provided,
};

/// Validated edit operations with hash validation
///
/// Usage:
///   var editor = ValidatedEdit.init(allocator);
///   defer editor.deinit();
///   const result = try editor.applyEdit(.{
///       .file_path = "src/main.zig",
///       .line_number = 42,
///       .expected_hash = 0xa3b4c5d6,
///       .old_content = "old line",
///       .new_content = "new line",
///   });
pub const ValidatedEdit = struct {
    allocator: Allocator,
    hash_cache: HashCache,
    resolver: ConflictResolver,

    pub fn init(allocator: Allocator) ValidatedEdit {
        return ValidatedEdit{
            .allocator = allocator,
            .hash_cache = HashCache.init(allocator, 100),
            .resolver = ConflictResolver.init(allocator),
        };
    }

    /// Apply a single edit operation with hash validation
    pub fn applyEdit(self: *ValidatedEdit, op: EditOperation) !EditResult {
        // Read current file content
        const content = std.fs.cwd().readFileAlloc(self.allocator, op.file_path, 100 * 1024 * 1024) catch {
            return .file_not_found;
        };
        defer self.allocator.free(content);

        // If no hash provided, fall back to unsafe edit
        if (op.expected_hash == 0) {
            try self.applyEditUnsafe(op, content);
            return .success;
        }

        // Get hash index for this file
        var index = try self.hash_cache.getIndex(op.file_path, content);

        // Validate the line hash
        const validation = index.validateLine(op.line_number, op.expected_hash, content);

        switch (validation) {
            .valid => {
                try self.applyEditUnsafe(op, content);
                return .success;
            },
            .stale_line => |info| {
                const expected_preview = index.getLineContent(op.line_number, content) orelse "";
                const actual_preview = index.getLineContent(op.line_number, content) orelse "";
                const conflict = Conflict{
                    .line_number = op.line_number,
                    .expected_hash = info.expected_hash,
                    .actual_hash = info.actual_hash,
                    .expected_preview = expected_preview,
                    .actual_preview = actual_preview,
                };
                Conflict.printConflict(conflict);
                return .{ .conflict = conflict };
            },
            .line_not_found => return .line_out_of_range,
            .index_empty => {
                // No index — apply without validation
                try self.applyEditUnsafe(op, content);
                return .success;
            },
        }
    }

    /// Apply edit without hash validation (fallback)
    fn applyEditUnsafe(self: *ValidatedEdit, op: EditOperation, current_content: []const u8) !void {
        // Split content into lines
        var lines = std.ArrayList([]const u8).init(self.allocator);
        defer lines.deinit();

        var iter = std.mem.splitScalar(u8, current_content, '\n');
        while (iter.next()) |line| {
            try lines.append(line);
        }

        // Apply the edit
        if (op.line_number == 0 or op.line_number > lines.items.len) {
            // Append at end
            try lines.append(op.new_content);
        } else {
            // Replace line (1-based to 0-based)
            lines.items[op.line_number - 1] = op.new_content;
        }

        // Rebuild content
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        for (lines.items, 0..) |line, i| {
            if (i > 0) try output.append('\n');
            try output.appendSlice(line);
        }

        // Write back to file
        const file = try std.fs.cwd().createFile(op.file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(output.items);

        // Invalidate cache for this file
        self.hash_cache.invalidate(op.file_path);
    }

    /// Apply multiple edits atomically (all-or-nothing)
    /// Validates ALL edits before applying any
    pub fn applyEditsAtomic(self: *ValidatedEdit, ops: []const EditOperation) ![]EditResult {
        var results = try self.allocator.alloc(EditResult, ops.len);
        errdefer self.allocator.free(results);

        // Phase 1: Validate all edits
        var conflicts = std.ArrayList(struct { index: usize, conflict: Conflict }).init(self.allocator);
        defer conflicts.deinit();

        for (ops, 0..) |op, i| {
            if (op.expected_hash == 0) {
                results[i] = .no_hash_provided;
                continue;
            }

            const content = std.fs.cwd().readFileAlloc(self.allocator, op.file_path, 100 * 1024 * 1024) catch {
                results[i] = .file_not_found;
                continue;
            };
            defer self.allocator.free(content);

            var index = try self.hash_cache.getIndex(op.file_path, content);
            const validation = index.validateLine(op.line_number, op.expected_hash, content);

            switch (validation) {
                .valid => {
                    results[i] = .success;
                },
                .stale_line => |info| {
                    const expected_preview = index.getLineContent(op.line_number, content) orelse "";
                    const actual_preview = index.getLineContent(op.line_number, content) orelse "";
                    const c = Conflict{
                        .line_number = op.line_number,
                        .expected_hash = info.expected_hash,
                        .actual_hash = info.actual_hash,
                        .expected_preview = expected_preview,
                        .actual_preview = actual_preview,
                    };
                    results[i] = .{ .conflict = c };
                    try conflicts.append(.{ .index = i, .conflict = c });
                },
                .line_not_found => {
                    results[i] = .line_out_of_range;
                },
                .index_empty => {
                    results[i] = .success;
                },
            }
        }

        // Phase 2: If any conflicts, don't apply any
        if (conflicts.items.len > 0) {
            return results;
        }

        // Phase 3: Apply all edits
        for (ops) |op| {
            self.applyEdit(op) catch |err| {
                // Log but continue — best effort
                std.debug.print("Warning: edit failed for {s}: {}\n", .{ op.file_path, err });
            };
        }

        return results;
    }

    pub fn deinit(self: *ValidatedEdit) void {
        self.hash_cache.deinit();
        self.resolver.deinit();
    }
};
