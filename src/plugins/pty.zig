const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const PTYPlugin = struct {
    allocator: Allocator,
    sessions: std.StringHashMap(Session),
    max_sessions: usize,
    buffer_lines: usize,

    pub fn init(allocator: Allocator) PTYPlugin {
        return PTYPlugin{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
            .max_sessions = 10,
            .buffer_lines = 50000,
        };
    }

    pub fn deinit(self: *PTYPlugin) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    pub fn handleRequest(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        switch (request.method) {
            .spawn => return self.spawnTerminal(request),
            .write => return self.writeToTerminal(request),
            .read => return self.readFromTerminal(request),
            .list => return self.listSessions(request),
            .kill => return self.killSession(request),
            .resize => return self.resizeTerminal(request),
            .open_dashboard => return self.openDashboard(request),
        }
    }

    fn spawnTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        if (self.sessions.count() >= self.max_sessions) {
            return PTYResponse{ .success = false, .err = "Maximum PTY sessions reached" };
        }

        const cmd_parts = request.args.command_parts orelse return PTYResponse{ .success = false, .err = "No command parts provided" };
        if (cmd_parts.len == 0) {
            return PTYResponse{ .success = false, .err = "No command parts provided" };
        }

        const session_id = try std.fmt.allocPrint(self.allocator, "pty_{d}", .{std.time.timestamp()});
        const pty_result = try self.spawnPTY(session_id, cmd_parts, request.args);

        if (!pty_result.success) {
            self.allocator.free(session_id);
            return PTYResponse{
                .success = false,
                .err = pty_result.error_msg orelse "Failed to spawn PTY",
            };
        }

        const command = try self.allocator.dupe(u8, request.args.command orelse cmd_parts[0]);
        errdefer self.allocator.free(command);

        const cwd = try self.allocator.dupe(u8, request.args.cwd orelse ".");
        errdefer self.allocator.free(cwd);

        const session = Session{
            .session_id = session_id,
            .pid = pty_result.pid.?,
            .master_fd = pty_result.master_fd.?,
            .command = command,
            .cwd = cwd,
            .created_at = std.time.timestamp(),
            .last_read = 0,
            .status = .active,
        };
        errdefer session.deinit(self.allocator);

        try self.sessions.put(session_id, session);

        return PTYResponse{
            .success = true,
            .data = try session.toJson(self.allocator),
            .message = try std.fmt.allocPrint(self.allocator, "Terminal session created: {s}", .{session_id}),
        };
    }

    fn spawnPTY(self: *PTYPlugin, session_id: []const u8, cmd_args: []const []const u8, args: PTYArgs) !PTYResult {
        _ = session_id;

        if (builtin.target.os.tag == .windows) {
            return self.spawnPTYWindows(cmd_args, args);
        }
        return self.spawnPTYUnix(cmd_args, args);
    }

    fn spawnPTYUnix(self: *PTYPlugin, cmd_args: []const []const u8, args: PTYArgs) !PTYResult {
        const master_fd = posix.open("/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0) catch {
            return PTYResult{ .success = false, .error_msg = "Failed to open /dev/ptmx" };
        };
        errdefer posix.close(master_fd);

        var unlock: i32 = 0;
        if (posix.errno(posix.system.ioctl(master_fd, posix.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) {
            return PTYResult{ .success = false, .error_msg = "Failed to unlock PTY" };
        }

        var pty_number: u32 = 0;
        if (posix.errno(posix.system.ioctl(master_fd, posix.T.IOCGPTN, @intFromPtr(&pty_number))) != .SUCCESS) {
            return PTYResult{ .success = false, .error_msg = "Failed to resolve PTY slave path" };
        }

        const slave_path = try std.fmt.allocPrint(self.allocator, "/dev/pts/{d}", .{pty_number});
        defer self.allocator.free(slave_path);

        const slave_fd = posix.open(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch {
            return PTYResult{ .success = false, .error_msg = "Failed to open PTY slave" };
        };
        errdefer posix.close(slave_fd);

        var winsize = posix.winsize{
            .row = @intCast(args.rows orelse 24),
            .col = @intCast(args.cols orelse 80),
            .xpixel = 0,
            .ypixel = 0,
        };
        if (posix.errno(posix.system.ioctl(slave_fd, posix.T.IOCSWINSZ, @intFromPtr(&winsize))) != .SUCCESS) {
            return PTYResult{ .success = false, .error_msg = "Failed to configure PTY size" };
        }

        const argv = try buildCStringVector(self.allocator, cmd_args);
        defer argv.deinit(self.allocator);

        const env_items = args.env orelse &.{};
        const envp = try buildCStringVector(self.allocator, env_items);
        defer envp.deinit(self.allocator);

        const pid = posix.fork() catch {
            return PTYResult{ .success = false, .error_msg = "Failed to fork process" };
        };

        if (pid == 0) {
            posix.close(master_fd);
            _ = posix.setsid() catch {};
            _ = posix.system.ioctl(slave_fd, std.os.linux.T.IOCSCTTY, 0);
            posix.dup2(slave_fd, posix.STDIN_FILENO) catch {};
            posix.dup2(slave_fd, posix.STDOUT_FILENO) catch {};
            posix.dup2(slave_fd, posix.STDERR_FILENO) catch {};
            if (slave_fd > posix.STDERR_FILENO) posix.close(slave_fd);

            if (args.cwd) |cwd| {
                posix.chdir(cwd) catch {};
            }

            posix.execvpeZ(argv.ptr[0].?, argv.ptr, envp.ptr) catch {};
            std.process.exit(1);
        }

        posix.close(slave_fd);
        try setNonBlocking(master_fd);

        return PTYResult{
            .success = true,
            .pid = @intCast(pid),
            .master_fd = master_fd,
        };
    }

    fn spawnPTYWindows(self: *PTYPlugin, cmd_args: []const []const u8, args: PTYArgs) !PTYResult {
        _ = self;
        _ = cmd_args;
        _ = args;
        return PTYResult{ .success = false, .error_msg = "Windows PTY not implemented" };
    }

    fn writeToTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_id = request.args.session_id orelse return PTYResponse{ .success = false, .err = "Session ID is required" };
        const data = request.args.data orelse return PTYResponse{ .success = false, .err = "Terminal input data is required" };
        const session = self.sessions.getPtr(session_id) orelse return PTYResponse{ .success = false, .err = "Session not found" };

        if (builtin.target.os.tag == .windows) {
            return PTYResponse{ .success = false, .err = "Windows PTY write not implemented" };
        }

        const bytes_written = posix.write(session.master_fd, data) catch {
            return PTYResponse{ .success = false, .err = "Failed to write to PTY" };
        };

        return PTYResponse{
            .success = true,
            .message = try std.fmt.allocPrint(self.allocator, "Wrote {d} bytes to session {s}", .{ bytes_written, session_id }),
        };
    }

    fn readFromTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_id = request.args.session_id orelse return PTYResponse{ .success = false, .err = "Session ID is required" };
        const session = self.sessions.getPtr(session_id) orelse return PTYResponse{ .success = false, .err = "Session not found" };

        if (builtin.target.os.tag == .windows) {
            return PTYResponse{ .success = false, .err = "Windows PTY read not implemented" };
        }

        var buffer: [4096]u8 = undefined;
        const bytes_read = posix.read(session.master_fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return PTYResponse{ .success = false, .err = "Failed to read from PTY" },
        };
        session.last_read = std.time.timestamp();

        const output = try self.allocator.dupe(u8, buffer[0..bytes_read]);
        return PTYResponse{
            .success = true,
            .data = .{ .string = output },
        };
    }

    fn listSessions(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        _ = request;

        var sessions_map = std.json.ObjectMap.init(self.allocator);
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try sessions_map.put(entry.key_ptr.*, try entry.value_ptr.toJson(self.allocator));
        }

        return PTYResponse{
            .success = true,
            .data = .{ .object = sessions_map },
        };
    }

    fn killSession(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_id = request.args.session_id orelse return PTYResponse{ .success = false, .err = "Session ID is required" };
        const removed = self.sessions.fetchRemove(session_id) orelse return PTYResponse{ .success = false, .err = "Session not found" };
        defer removed.value.deinit(self.allocator);

        if (builtin.target.os.tag == .windows) {
            return PTYResponse{ .success = false, .err = "Windows PTY kill not implemented" };
        }

        posix.kill(@intCast(removed.value.pid), posix.SIG.KILL) catch {};
        posix.close(removed.value.master_fd);

        return PTYResponse{
            .success = true,
            .message = try std.fmt.allocPrint(self.allocator, "Session {s} terminated", .{session_id}),
        };
    }

    fn resizeTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_id = request.args.session_id orelse return PTYResponse{ .success = false, .err = "Session ID is required" };
        const session = self.sessions.getPtr(session_id) orelse return PTYResponse{ .success = false, .err = "Session not found" };
        const rows = request.args.rows orelse 24;
        const cols = request.args.cols orelse 80;

        if (builtin.target.os.tag == .windows) {
            return PTYResponse{ .success = false, .err = "Windows PTY resize not implemented" };
        }

        var winsize = posix.winsize{
            .row = @intCast(rows),
            .col = @intCast(cols),
            .xpixel = 0,
            .ypixel = 0,
        };

        if (posix.errno(posix.system.ioctl(session.master_fd, posix.T.IOCSWINSZ, @intFromPtr(&winsize))) != .SUCCESS) {
            return PTYResponse{ .success = false, .err = "Failed to resize terminal" };
        }

        return PTYResponse{
            .success = true,
            .message = try std.fmt.allocPrint(self.allocator, "Terminal resized to {d}x{d}", .{ cols, rows }),
        };
    }

    fn openDashboard(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        _ = request;

        const port = 8080 + @rem(@as(u32, @intCast(std.time.timestamp())), 1000);
        const dashboard_url = try std.fmt.allocPrint(self.allocator, "http://localhost:{d}/pty", .{port});

        return PTYResponse{
            .success = true,
            .data = .{ .string = dashboard_url },
            .message = try std.fmt.allocPrint(self.allocator, "PTY dashboard available at {s}", .{dashboard_url}),
        };
    }
};

pub const PTYRequest = struct {
    method: PTYMethod,
    args: PTYArgs,
    id: ?u64 = null,
};

pub const PTYResponse = struct {
    success: bool,
    data: ?std.json.Value = null,
    message: ?[]const u8 = null,
    err: ?[]const u8 = null,
};

pub const PTYMethod = enum {
    spawn,
    write,
    read,
    list,
    kill,
    resize,
    open_dashboard,
};

pub const PTYArgs = struct {
    session_id: ?[]const u8 = null,
    command: ?[]const u8 = null,
    command_parts: ?[][]const u8 = null,
    cwd: ?[]const u8 = null,
    data: ?[]const u8 = null,
    rows: ?u32 = null,
    cols: ?u32 = null,
    env: ?[][]const u8 = null,
};

pub const PTYResult = struct {
    success: bool,
    pid: ?u32 = null,
    master_fd: ?posix.fd_t = null,
    error_msg: ?[]const u8 = null,
};

const Session = struct {
    session_id: []const u8,
    pid: u32,
    master_fd: posix.fd_t,
    command: []const u8,
    cwd: []const u8,
    created_at: i64,
    last_read: i64,
    status: Status,

    fn deinit(self: Session, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
    }

    fn toJson(self: Session, allocator: Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("session_id", .{ .string = self.session_id });
        try obj.put("pid", .{ .integer = @as(i64, @intCast(self.pid)) });
        try obj.put("master_fd", .{ .integer = @as(i64, @intCast(self.master_fd)) });
        try obj.put("command", .{ .string = self.command });
        try obj.put("cwd", .{ .string = self.cwd });
        try obj.put("created_at", .{ .integer = self.created_at });
        try obj.put("last_read", .{ .integer = self.last_read });
        try obj.put("status", .{ .string = @tagName(self.status) });
        return .{ .object = obj };
    }
};

const Status = enum {
    active,
};

const CStringVector = struct {
    owned: []const [:0]u8,
    ptr: [:null]?[*:0]const u8,

    fn deinit(self: CStringVector, allocator: Allocator) void {
        for (self.owned) |item| {
            allocator.free(item);
        }
        allocator.free(self.owned);
        allocator.free(self.ptr);
    }
};

fn buildCStringVector(allocator: Allocator, items: []const []const u8) !CStringVector {
    const owned = try allocator.alloc([:0]u8, items.len);
    errdefer allocator.free(owned);

    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |item| allocator.free(item);
    }

    const ptr = try allocator.allocSentinel(?[*:0]const u8, items.len, null);
    errdefer allocator.free(ptr);

    for (items, 0..) |item, index| {
        owned[index] = try allocator.dupeZ(u8, item);
        filled += 1;
        ptr[index] = owned[index].ptr;
    }

    return CStringVector{ .owned = owned, .ptr = ptr };
}

fn setNonBlocking(fd: posix.fd_t) !void {
    var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags);
}
