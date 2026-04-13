const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const NotifierPlugin = struct {
    allocator: Allocator,
    enabled: bool,
    sound_enabled: bool,
    notification_enabled: bool,
    custom_commands: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) NotifierPlugin {
        return NotifierPlugin{
            .allocator = allocator,
            .enabled = true,
            .sound_enabled = true,
            .notification_enabled = true,
            .custom_commands = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *NotifierPlugin) void {
        self.custom_commands.deinit();
    }

    pub fn handleEvent(self: *NotifierPlugin, event: NotifierEvent) !void {
        switch (event.type) {
            .session_started => try self.notifySessionStarted(event),
            .session_completed => try self.notifySessionCompleted(event),
            .permission_requested => try self.notifyPermissionRequested(event),
            .permission_updated => try self.notifyPermissionUpdated(event),
            .task_started => try self.notifyTaskStarted(event),
            .task_completed => try self.notifyTaskCompleted(event),
            .error_occurred => try self.notifyErrorOccurred(event),
        }
    }

    fn notifySessionStarted(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Crushcode session started: {s}", .{event.session_id.?});
        defer self.allocator.free(message);

        try self.showNotification("Session Started", message);
        try self.playSound("session_start");
    }

    fn notifySessionCompleted(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Crushcode session completed: {s}", .{event.session_id.?});
        defer self.allocator.free(message);

        try self.showNotification("Session Completed", message);
        try self.playSound("session_complete");
    }

    fn notifyPermissionRequested(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Permission requested for: {s}", .{event.permission.?});
        defer self.allocator.free(message);

        try self.showNotification("Permission Request", message);
        try self.playSound("permission_request");
    }

    fn notifyPermissionUpdated(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Permission updated: {s} = {}", .{ event.permission.?, event.permission_granted.? });
        defer self.allocator.free(message);

        try self.showNotification("Permission Updated", message);
        try self.playSound("permission_update");
    }

    fn notifyTaskStarted(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Task started: {s}", .{event.task_name.?});
        defer self.allocator.free(message);

        try self.showNotification("Task Started", message);
        try self.playSound("task_start");
    }

    fn notifyTaskCompleted(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Task completed: {s}", .{event.task_name.?});
        defer self.allocator.free(message);

        try self.showNotification("Task Completed", message);
        try self.playSound("task_complete");
    }

    fn notifyErrorOccurred(self: *NotifierPlugin, event: NotifierEvent) !void {
        if (!self.enabled) return;

        const message = try std.fmt.allocPrint(self.allocator, "Error occurred: {s}", .{event.error_message.?});
        defer self.allocator.free(message);

        try self.showNotification("Error", message);
        try self.playSound("error");
    }

    fn showNotification(self: *NotifierPlugin, title: []const u8, message: []const u8) !void {
        if (!self.notification_enabled) return;

        if (builtin.target.os.tag == .windows) {
            try self.showWindowsNotification(title, message);
        } else {
            try self.showUnixNotification(title, message);
        }
    }

    fn showWindowsNotification(self: *NotifierPlugin, title: []const u8, message: []const u8) !void {
        _ = self;
        // In a real implementation, this would use Windows API
        // For now, just print to console
        const full_message = try std.fmt.allocPrint(std.heap.page_allocator, "[NOTIFICATION] {s}: {s}", .{ title, message });
        defer std.heap.page_allocator.free(full_message);
        std.log.info("{s}", .{full_message});
    }

    fn showUnixNotification(self: *NotifierPlugin, title: []const u8, message: []const u8) !void {
        _ = self;
        // Use notify-send or similar on Unix systems
        const full_message = try std.fmt.allocPrint(std.heap.page_allocator, "[NOTIFICATION] {s}: {s}", .{ title, message });
        defer std.heap.page_allocator.free(full_message);
        std.log.info("{s}", .{full_message});
    }

    fn playSound(self: *NotifierPlugin, sound_type: []const u8) !void {
        if (!self.sound_enabled) return;

        // In a real implementation, this would play sound files
        // For now, just log the sound event
        const sound_message = try std.fmt.allocPrint(std.heap.page_allocator, "[SOUND] Playing: {s}", .{sound_type});
        defer std.heap.page_allocator.free(sound_message);
        std.log.info("{s}", .{sound_message});
    }

    pub fn addCustomCommand(self: *NotifierPlugin, name: []const u8, command: []const u8) !void {
        try self.custom_commands.put(name, command);
    }

    pub fn executeCustomCommand(self: *NotifierPlugin, name: []const u8) !void {
        if (self.custom_commands.get(name)) |command| {
            // Execute custom command
            const full_command = try std.fmt.allocPrint(self.allocator, "Executing custom command: {s}", .{command});
            defer self.allocator.free(full_command);
            std.log.info("{s}", .{full_command});

            // In a real implementation, this would actually execute the command
            // For now, we just log it
        }
    }

    pub fn setEnabled(self: *NotifierPlugin, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn setSoundEnabled(self: *NotifierPlugin, enabled: bool) void {
        self.sound_enabled = enabled;
    }

    pub fn setNotificationEnabled(self: *NotifierPlugin, enabled: bool) void {
        self.notification_enabled = enabled;
    }
};

pub const NotifierEvent = struct {
    type: EventType,
    session_id: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    permission: ?[]const u8 = null,
    permission_granted: ?bool = null,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub const EventType = enum {
    session_started,
    session_completed,
    permission_requested,
    permission_updated,
    task_started,
    task_completed,
    error_occurred,
};
