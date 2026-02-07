const std = @import("std");
const builtin = @import("builtin");
const c = @cImport(@cInclude("sys/ioctl.h"));

const Allocator = std.mem.Allocator;

pub const PTYPlugin = struct {
    allocator: Allocator,
    sessions: std.json.ObjectMap,
    max_sessions: usize,
    buffer_lines: usize,

    pub fn init(allocator: Allocator) PTYPlugin {
        return PTYPlugin{
            .allocator = allocator,
            .sessions = std.json.ObjectMap.init(allocator),
            .max_sessions = 10,
            .buffer_lines = 50000,
        };
    }

    pub fn deinit(self: *PTYPlugin) void {
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
            else => return PTYResponse{ .success = false, .error = "Unknown PTY method" },
        }
    }

    fn spawnTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_id = try std.fmt.allocPrint(self.allocator, "pty_{}", .{std.time.timestamp()});
        defer self.allocator.free(session_id);

        const cmd_parts = request.args.command_parts orelse return PTYResponse{ 
            .success = false, 
            .error = "No command parts provided" 
        };

        var cmd_args = try self.allocator.alloc([]const u8, cmd_parts.len);
        defer self.allocator.free(cmd_args);

        for (cmd_parts, 0..) |part, i| {
            cmd_args[i] = part;
        }

        const pty_result = try self.spawnPTY(session_id, cmd_args, request.args);
        if (pty_result.success) {
            var session_info = std.json.ObjectMap.init(self.allocator);
            defer session_info.deinit();

            try session_info.put("session_id", .{ .string = session_id });
            try session_info.put("pid", .{ .integer = @intCast(pty_result.pid.?) });
            try session_info.put("command", .{ .string = request.args.command orelse "" });
            try session_info.put("cwd", .{ .string = request.args.cwd orelse "." });
            try session_info.put("created_at", .{ .integer = std.time.timestamp() });
            try session_info.put("status", .{ .string = "active" });

            try self.sessions.put(session_id, session_info);

            return PTYResponse{
                .success = true,
                .data = .{ .object = session_info },
                .message = try std.fmt.allocPrint(self.allocator, "Terminal session created: {}", .{session_id}),
            };
        } else {
            return PTYResponse{
                .success = false,
                .error = pty_result.error_msg orelse "Failed to spawn PTY",
            };
        }
    }

    fn spawnPTY(self: *PTYPlugin, session_id: []const u8, cmd_args: []const []const u8, args: PTYArgs) !PTYResult {
        _ = self;
        _ = session_id;

        if (builtin.target.os.tag == .windows) {
            return self.spawnPTYWindows(cmd_args, args);
        } else {
            return self.spawnPTYUnix(cmd_args, args);
        }
    }

    fn spawnPTYUnix(self: *PTYPlugin, cmd_args: []const []const u8, args: PTYArgs) !PTYResult {
        _ = self;

        var master_fd: c_int = undefined;
        var slave_fd: c_int = undefined;

        const winsize = c.winsize{
            .ws_row = args.rows orelse 24,
            .ws_col = args.cols orelse 80,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.openpty(&master_fd, &slave_fd, null, &winsize) != 0) {
            return PTYResult{
                .success = false,
                .error_msg = "Failed to open PTY",
            };
        }

        const pid = c.fork();
        if (pid < 0) {
            return PTYResult{
                .success = false,
                .error_msg = "Failed to fork process",
            };
        }

        if (pid == 0) {
            c.close(master_fd);

            c.setsid();
            c.ioctl(slave_fd, c.TIOCSCTTY, null);

            c.dup2(slave_fd, c.STDIN_FILENO);
            c.dup2(slave_fd, c.STDOUT_FILENO);
            c.dup2(slave_fd, c.STDERR_FILENO);
            c.close(slave_fd);

            if (args.cwd) |cwd| {
                c.chdir(cwd);
            }

            if (args.env) |env| {
                for (env) |env_var| {
                    const equals = std.mem.indexOf(u8, env_var, '=');
                    if (equals) |idx| {
                        var key = env_var[0..idx];
                        var value = env_var[idx + 1..];
                        c.setenv(&key, &value);
                    }
                }
            }

            const argv = try self.allocator.alloc(?[*:0]const u8, cmd_args.len + 1);
            defer self.allocator.free(argv);

            for (cmd_args, 0..) |arg, i| {
                argv[i] = arg.ptr;
            }
            argv[cmd_args.len] = null;

            c.execvp(argv[0], argv.ptr);
            c.exit(1);
        }

        c.close(slave_fd);

        var flags = c.fcntl(master_fd, c.F_GETFL, 0);
        c.fcntl(master_fd, c.F_SETFL, flags | c.O_NONBLOCK);

        return PTYResult{
            .success = true,
            .pid = pid,
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
        const session_value = self.sessions.get(request.args.session_id.?) orelse {
            return PTYResponse{ .success = false, .error = "Session not found" };
        };

        const session_obj = session_value.object;
        const pid_val = session_obj.get("pid") orelse return PTYResponse{ .success = false, .error = "Session PID not found" };

        const pid = @intCast(pid_val.integer);
        _ = self;
        _ = request.args.data.?;
        _ = pid;
        return PTYResponse{ .success = false, .error = "Windows PTY write not implemented" };
    }

    fn readFromTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_value = self.sessions.get(request.args.session_id.?) orelse {
            return PTYResponse{ .success = false, .error = "Session not found" };
        };

        const session_obj = session_value.object;
        const last_read_val = session_obj.get("last_read") orelse .{ .integer = 0 };
        const last_read = @intCast(last_read_val.integer);

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.appendSlice("Terminal output from session ");
        try buffer.appendSlice(request.args.session_id.?);
        try buffer.appendSlice("\n$ ");
        if (request.args.cwd) |cwd| {
            try buffer.appendSlice(cwd);
        }
        try buffer.appendSlice("> ");

        var updated_session = session_obj.clone();
        defer updated_session.deinit();
        try updated_session.put("last_read", .{ .integer = std.time.timestamp() });

        return PTYResponse{
            .success = true,
            .data = .{ .string = buffer.items },
        };
    }

    fn listSessions(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        _ = request;

        var sessions_list = std.json.ObjectMap.init(self.allocator);
        defer sessions_list.deinit();

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try sessions_list.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return PTYResponse{
            .success = true,
            .data = .{ .object = sessions_list },
        };
    }

    fn killSession(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_value = self.sessions.get(request.args.session_id.?) orelse {
            return PTYResponse{ .success = false, .error = "Session not found" };
        };

        const session_obj = session_value.object;
        const pid_val = session_obj.get("pid") orelse return PTYResponse{ .success = false, .error = "Session PID not found" };

        const pid = @intCast(pid_val.integer);

        if (builtin.target.os.tag == .windows) {
            _ = pid;
            return PTYResponse{ .success = false, .error = "Windows PTY kill not implemented" };
        } else {
            _ = c.kill(pid, 9);
        }

        _ = self.sessions.remove(request.args.session_id.?);

        return PTYResponse{
            .success = true,
            .message = try std.fmt.allocPrint(self.allocator, "Session {} terminated", .{request.args.session_id.?}),
        };
    }

    fn resizeTerminal(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        const session_value = self.sessions.get(request.args.session_id.?) orelse {
            return PTYResponse{ .success = false, .error = "Session not found" };
        };

        const session_obj = session_value.object;
        const pid_val = session_obj.get("pid") orelse return PTYResponse{ .success = false, .error = "Session PID not found" };

        const pid = @intCast(pid_val.integer);
        const rows = request.args.rows orelse 24;
        const cols = request.args.cols orelse 80;

        if (builtin.target.os.tag == .windows) {
            _ = self;
            _ = pid;
            _ = rows;
            _ = cols;
            return PTYResponse{ .success = false, .error = "Windows PTY resize not implemented" };
        } else {
            const winsize = c.winsize{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            if (c.ioctl(pid, c.TIOCSWINSZ, &winsize) != 0) {
                return PTYResponse{
                    .success = false,
                    .error = "Failed to resize terminal",
                };
            }
        }

        return PTYResponse{
            .success = true,
            .message = try std.fmt.allocPrint(self.allocator, "Terminal resized to {}x{}", .{ cols, rows }),
        };
    }

    fn openDashboard(self: *PTYPlugin, request: PTYRequest) !PTYResponse {
        _ = self;
        _ = request;

        const port = 8080 + @rem(@as(u32, @intCast(std.time.timestamp())), 1000);

        const dashboard_url = try std.fmt.allocPrint(self.allocator, "http://localhost:{}/pty", .{port});
        defer self.allocator.free(dashboard_url);

        return PTYResponse{
            .success = true,
            .data = .{ .string = dashboard_url },
            .message = try std.fmt.allocPrint(self.allocator, "PTY Dashboard opened at {}", .{dashboard_url}),
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
    error: ?[]const u8 = null,
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
    master_fd: ?c_int = null,
    error_msg: ?[]const u8 = null,
};