const std = @import("std");
const args_mod = @import("args");
const session_mod = @import("session");
const file_compat = @import("file_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Handle session management commands
pub fn handleSessions(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const subcommand = if (args.remaining.len > 0) args.remaining[0] else "";

    if (subcommand.len == 0 or std.mem.eql(u8, subcommand, "list")) {
        return listSessions(allocator);
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode sessions show <id-or-prefix>\n", .{});
            return;
        }
        return showSession(allocator, args.remaining[1]);
    }

    if (std.mem.eql(u8, subcommand, "delete")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode sessions delete <id-or-prefix>\n", .{});
            return;
        }
        return deleteSessionCmd(allocator, args.remaining[1]);
    }

    if (std.mem.eql(u8, subcommand, "clean")) {
        var days: u32 = 30;
        // Check for --days N
        for (args.remaining[1..], 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--days") and i + 2 < args.remaining.len) {
                days = std.fmt.parseInt(u32, args.remaining[i + 2], 10) catch {
                    stdout_print("Invalid --days value. Using default 30.\n", .{});
                    days = 30;
                    break;
                };
            }
        }
        return cleanSessions(allocator, days);
    }

    if (std.mem.eql(u8, subcommand, "help")) {
        printHelp();
        return;
    }

    stdout_print("Unknown subcommand: {s}\n", .{subcommand});
    printHelp();
}

fn printHelp() void {
    stdout_print("Session Management — View and manage chat sessions\n\n", .{});
    stdout_print("Usage:\n", .{});
    stdout_print("  crushcode sessions                    List all sessions\n", .{});
    stdout_print("  crushcode sessions list               List all sessions\n", .{});
    stdout_print("  crushcode sessions show <id>          Show session details\n", .{});
    stdout_print("  crushcode sessions delete <id>        Delete a session\n", .{});
    stdout_print("  crushcode sessions clean [--days N]   Remove old sessions (default: 30 days)\n", .{});
    stdout_print("\nSession IDs can be specified as a prefix for convenience.\n", .{});
}

fn listSessions(allocator: std.mem.Allocator) void {
    const session_dir = session_mod.defaultSessionDir(allocator) catch |err| {
        stdout_print("Error finding session directory: {}\n", .{err});
        return;
    };
    defer allocator.free(session_dir);

    const sessions = session_mod.listSessions(allocator, session_dir) catch |err| {
        stdout_print("Error listing sessions: {}\n", .{err});
        return;
    };
    defer {
        for (sessions) |*s| session_mod.deinitSession(allocator, s);
        allocator.free(sessions);
    }

    if (sessions.len == 0) {
        stdout_print("No sessions found.\n\n", .{});
        stdout_print("Start a chat with: crushcode chat\n", .{});
        return;
    }

    stdout_print("\n  Sessions ({d} total)\n\n", .{sessions.len});
    stdout_print("  ID                       Title                           Model           Turns Tokens   Cost\n", .{});
    stdout_print("  ─────────────────────────────────────────────────────────────────────────────────────────────\n", .{});

    for (sessions) |session| {
        const short_id = if (session.id.len > 26) session.id[0..26] else session.id;

        // Truncate title to fit column
        var title_buf: [34]u8 = undefined;
        const title = truncateFit(session.title, &title_buf, 32);

        // Truncate model name to fit column
        var model_buf: [17]u8 = undefined;
        const model = truncateFit(session.model, &model_buf, 15);

        // Format tokens with K suffix
        const tokens = session.total_tokens;
        var token_buf: [10]u8 = undefined;
        const token_str = blk: {
            if (tokens >= 1_000_000) {
                const val: f64 = @floatFromInt(tokens);
                const result = std.fmt.bufPrint(&token_buf, "{d:.1}M", .{val / 1_000_000.0}) catch break :blk "???";
                break :blk result;
            } else if (tokens >= 1000) {
                const val: f64 = @floatFromInt(tokens);
                const result = std.fmt.bufPrint(&token_buf, "{d:.1}K", .{val / 1000.0}) catch break :blk "???";
                break :blk result;
            } else {
                const result = std.fmt.bufPrint(&token_buf, "{}", .{tokens}) catch break :blk "???";
                break :blk result;
            }
        };

        // Format cost
        var cost_buf: [9]u8 = undefined;
        const cost_str = if (session.total_cost > 0)
            std.fmt.bufPrint(&cost_buf, "${d:.4}", .{session.total_cost}) catch "$?"
        else
            std.fmt.bufPrint(&cost_buf, "-", .{}) catch "-";

        stdout_print("  │ {s} │ {s} │ {s} │ {d} │ {s} │ {s} │\n", .{ short_id, title, model, session.turn_count, token_str, cost_str });
    }

    stdout_print("  ─────────────────────────────────────────────────────────────────────────────────────────────\n", .{});
    stdout_print("\n  Use 'crushcode sessions show <id>' to see details.\n", .{});
    stdout_print("  Use 'crushcode --continue' to resume the most recent session.\n\n", .{});
}

fn showSession(allocator: std.mem.Allocator, id_prefix: []const u8) void {
    const session_dir = session_mod.defaultSessionDir(allocator) catch |err| {
        stdout_print("Error finding session directory: {}\n", .{err});
        return;
    };
    defer allocator.free(session_dir);

    const sessions = session_mod.listSessions(allocator, session_dir) catch |err| {
        stdout_print("Error listing sessions: {}\n", .{err});
        return;
    };
    defer {
        for (sessions) |*s| session_mod.deinitSession(allocator, s);
        allocator.free(sessions);
    }

    // Find session by prefix match
    const session = findSessionByIdPrefix(sessions, id_prefix) orelse {
        stdout_print("Session '{s}' not found.\n", .{id_prefix});
        return;
    };

    const interrupted = session_mod.isInterrupted(session);

    stdout_print("\n  === Session Details ===\n\n", .{});
    stdout_print("  ID:       {s}\n", .{session.id});
    stdout_print("  Title:    {s}\n", .{session.title});
    stdout_print("  Model:    {s}/{s}\n", .{ session.provider, session.model });
    stdout_print("  Turns:    {d}\n", .{session.turn_count});
    stdout_print("  Messages: {d}\n", .{session.messages.len});
    stdout_print("  Tokens:   {d} total\n", .{session.total_tokens});
    stdout_print("  Cost:     ${d:.4}\n", .{session.total_cost});

    // Use timestamp directly (epoch seconds)
    stdout_print("  Created:  {d} (epoch)\n", .{session.created_at});
    stdout_print("  Updated:  {d} (epoch)\n", .{session.updated_at});
    stdout_print("  Duration: {d}s\n", .{session.duration_seconds});

    if (interrupted) {
        stdout_print("  Status:   ⚠ Interrupted\n", .{});
    } else {
        stdout_print("  Status:   ✓ Complete\n", .{});
    }

    // Show message role summary
    stdout_print("\n  Message Summary:\n", .{});
    var user_count: u32 = 0;
    var assistant_count: u32 = 0;
    var tool_count: u32 = 0;
    var system_count: u32 = 0;
    for (session.messages) |msg| {
        if (std.mem.eql(u8, msg.role, "user")) user_count += 1 else if (std.mem.eql(u8, msg.role, "assistant")) assistant_count += 1 else if (std.mem.eql(u8, msg.role, "tool")) tool_count += 1 else if (std.mem.eql(u8, msg.role, "system")) system_count += 1;
    }
    stdout_print("    System:    {d}\n", .{system_count});
    stdout_print("    User:      {d}\n", .{user_count});
    stdout_print("    Assistant: {d}\n", .{assistant_count});
    if (tool_count > 0) {
        stdout_print("    Tool:      {d}\n", .{tool_count});
    }

    stdout_print("\n  Resume with: crushcode --session {s}\n\n", .{session.id});
}

fn deleteSessionCmd(allocator: std.mem.Allocator, id_prefix: []const u8) void {
    const session_dir = session_mod.defaultSessionDir(allocator) catch |err| {
        stdout_print("Error finding session directory: {}\n", .{err});
        return;
    };
    defer allocator.free(session_dir);

    const sessions = session_mod.listSessions(allocator, session_dir) catch |err| {
        stdout_print("Error listing sessions: {}\n", .{err});
        return;
    };
    defer {
        for (sessions) |*s| session_mod.deinitSession(allocator, s);
        allocator.free(sessions);
    }

    const session = findSessionByIdPrefix(sessions, id_prefix) orelse {
        stdout_print("Session '{s}' not found.\n", .{id_prefix});
        return;
    };

    const path = session_mod.sessionFilePath(allocator, session_dir, session.id) catch |err| {
        stdout_print("Error building session path: {}\n", .{err});
        return;
    };
    defer allocator.free(path);

    session_mod.deleteSession(allocator, path) catch |err| {
        stdout_print("Error deleting session: {}\n", .{err});
        return;
    };

    stdout_print("Deleted session: {s}\n", .{session.id});
}

fn cleanSessions(allocator: std.mem.Allocator, max_age_days: u32) void {
    const session_dir = session_mod.defaultSessionDir(allocator) catch |err| {
        stdout_print("Error finding session directory: {}\n", .{err});
        return;
    };
    defer allocator.free(session_dir);

    const sessions = session_mod.listSessions(allocator, session_dir) catch |err| {
        stdout_print("Error listing sessions: {}\n", .{err});
        return;
    };
    defer {
        for (sessions) |*s| session_mod.deinitSession(allocator, s);
        allocator.free(sessions);
    }

    const now = std.time.timestamp();
    const cutoff = now - @as(i64, @intCast(max_age_days)) * 86400;

    var deleted_count: u32 = 0;
    var interrupted_deleted: u32 = 0;

    for (sessions) |session| {
        const is_old = session.updated_at < cutoff;
        const is_interrupted = session_mod.isInterrupted(&session);

        if (is_old or is_interrupted) {
            const path = session_mod.sessionFilePath(allocator, session_dir, session.id) catch continue;
            defer allocator.free(path);

            session_mod.deleteSession(allocator, path) catch continue;

            if (is_interrupted and !is_old) {
                interrupted_deleted += 1;
            } else {
                deleted_count += 1;
            }
        }
    }

    if (deleted_count + interrupted_deleted == 0) {
        stdout_print("No sessions to clean. All sessions are recent and complete.\n", .{});
    } else {
        if (deleted_count > 0) stdout_print("Deleted {d} session(s) older than {d} days.\n", .{ deleted_count, max_age_days });
        if (interrupted_deleted > 0) stdout_print("Deleted {d} interrupted session(s).\n", .{interrupted_deleted});
    }
}

/// Find a session by ID or ID prefix (returns first match)
fn findSessionByIdPrefix(sessions: []const session_mod.Session, prefix: []const u8) ?*const session_mod.Session {
    // Try exact match first
    for (sessions) |*session| {
        if (std.mem.eql(u8, session.id, prefix)) return session;
    }
    // Try prefix match
    for (sessions) |*session| {
        if (session.id.len >= prefix.len and std.mem.eql(u8, session.id[0..prefix.len], prefix)) return session;
    }
    return null;
}

/// Truncate a string to fit in a column with ellipsis
fn truncateFit(input: []const u8, buf: []u8, max_len: usize) []const u8 {
    if (input.len <= max_len) return input;
    if (max_len < 3) return input[0..max_len];
    @memcpy(buf[0 .. max_len - 3], input[0 .. max_len - 3]);
    buf[max_len - 3] = '.';
    buf[max_len - 2] = '.';
    buf[max_len - 1] = '.';
    return buf[0..max_len];
}
