// JSON-RPC 2.0 Communication Protocol
// Language-agnostic protocol for Crushcode Core Engine and External Tools

const std = @import("std");
const file_compat = @import("file_compat");

// JSON-RPC 2.0 Message Types
pub const MessageType = enum {
    request,
    response,
    notification,
};

// Request ID Types
pub const RequestId = union(enum) {
    null: void,
    number: i64,
    string: []const u8,
};

// JSON-RPC 2.0 Request
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: RequestId,

    pub fn init(method: []const u8, id: RequestId) Request {
        return Request{
            .method = method,
            .id = id,
        };
    }

    pub fn withParams(method: []const u8, params: std.json.Value, id: RequestId) Request {
        return Request{
            .method = method,
            .params = params,
            .id = id,
        };
    }
};

// JSON-RPC 2.0 Response
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    err: ?ErrorResponse = null,
    id: RequestId,

    pub fn success(result: std.json.Value, id: RequestId) Response {
        return Response{
            .result = result,
            .id = id,
        };
    }

    pub fn errorResponse(error_resp: ErrorResponse, id: RequestId) Response {
        return Response{
            .err = error_resp,
            .id = id,
        };
    }
};

// JSON-RPC 2.0 Error
pub const ErrorResponse = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,

    pub fn init(code: i32, message: []const u8) ErrorResponse {
        return ErrorResponse{
            .code = code,
            .message = message,
        };
    }

    pub fn withData(code: i32, message: []const u8, data: std.json.Value) ErrorResponse {
        return ErrorResponse{
            .code = code,
            .message = message,
            .data = data,
        };
    }
};

// JSON-RPC 2.0 Notification (no response expected)
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn init(method: []const u8) Notification {
        return Notification{
            .method = method,
        };
    }

    pub fn withParams(method: []const u8, params: std.json.Value) Notification {
        return Notification{
            .method = method,
            .params = params,
        };
    }
};

// Protocol Constants
pub const ErrorCodes = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;

    // Application-specific errors
    pub const PLUGIN_NOT_FOUND = -32000;
    pub const PLUGIN_ERROR = -32001;
    pub const TIMEOUT = -32002;
    pub const RATE_LIMITED = -32003;
};

// Standard Methods
pub const Methods = struct {
    pub const PLUGIN_REGISTER = "plugin.register";
    pub const PLUGIN_UNREGISTER = "plugin.unregister";
    pub const PLUGIN_EXECUTE = "plugin.execute";
    pub const PLUGIN_HEALTH_CHECK = "plugin.healthCheck";
    pub const PLUGIN_SHUTDOWN = "plugin.shutdown";

    pub const CORE_REQUEST = "core.request";
    pub const CORE_NOTIFY = "core.notify";
    pub const CORE_RESPONSE = "core.response";
};

// Communication Protocol Handler
pub const ProtocolHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProtocolHandler {
        return ProtocolHandler{
            .allocator = allocator,
        };
    }

    pub fn parseMessage(self: *ProtocolHandler, json_str: []const u8) !union(enum) {
        request: Request,
        response: Response,
        notification: Notification,
        invalid: void,
    } {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{});
        defer parsed.deinit();

        const value = parsed.value.object;

        if (!value.get("jsonrpc") orelse false) {
            return .{ .invalid = {} };
        }

        if (value.contains("id")) {
            // Has ID - could be request or response
            if (value.contains("method")) {
                // Request
                return .{ .request = try parseRequest(value) };
            } else {
                // Response
                return .{ .response = try parseResponse(value) };
            }
        } else {
            // No ID - notification
            return .{ .notification = try parseNotification(value) };
        }
    }

    fn parseRequest(obj: std.json.ObjectMap) !Request {
        const method = obj.get("method").?.string;
        const id = parseRequestId(obj.get("id").?) catch null;
        const params = obj.get("params");

        return Request{
            .method = method,
            .id = id,
            .params = params,
        };
    }

    fn parseResponse(obj: std.json.ObjectMap) !Response {
        const id = parseRequestId(obj.get("id").?) catch null;
        const result = obj.get("result");
        const error_obj = obj.get("error");

        if (error_obj) |err_val| {
            const err_obj = err_val.object;
            return Response{
                .id = id,
                .err = ErrorResponse{
                    .code = @intCast(err_obj.get("code").?.integer),
                    .message = err_obj.get("message").?.string,
                    .data = err_obj.get("data"),
                },
            };
        } else {
            return Response{
                .id = id,
                .result = result,
            };
        }
    }

    fn parseNotification(obj: std.json.ObjectMap) !Notification {
        const method = obj.get("method").?.string;
        const params = obj.get("params");

        return Notification{
            .method = method,
            .params = params,
        };
    }

    fn parseRequestId(value: std.json.Value) !RequestId {
        return switch (value) {
            .null => RequestId{ .null = {} },
            .integer => |num| RequestId{ .number = @intCast(num) },
            .string => |str| RequestId{ .string = str },
            else => error.InvalidRequestId,
        };
    }

    pub fn serializeRequest(self: *ProtocolHandler, request: Request) ![]const u8 {
        return std.json.stringifyAlloc(self.allocator, request, .{});
    }

    pub fn serializeResponse(self: *ProtocolHandler, response: Response) ![]const u8 {
        return std.json.stringifyAlloc(self.allocator, response, .{});
    }

    pub fn serializeNotification(self: *ProtocolHandler, notification: Notification) ![]const u8 {
        return std.json.stringifyAlloc(self.allocator, notification, .{});
    }
};

// Transport Layer Interface
pub const Transport = struct {
    vtable: *const VTable,

    const VTable = struct {
        send: *const fn (transport: *Transport, data: []const u8) anyerror!void,
        receive: *const fn (transport: *Transport) anyerror!?[]const u8,
        close: *const fn (transport: *Transport) void,
    };

    pub fn send(self: *Transport, data: []const u8) !void {
        return self.vtable.send(self, data);
    }

    pub fn receive(self: *Transport) !?[]const u8 {
        return self.vtable.receive(self);
    }

    pub fn close(self: *Transport) void {
        self.vtable.close(self);
    }
};

// Stdio Transport Implementation (for external tools)
pub const StdioTransport = struct {
    transport: Transport,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StdioTransport {
        return StdioTransport{
            .transport = Transport{
                .vtable = &.{
                    .send = send,
                    .receive = receive,
                    .close = close,
                },
            },
            .allocator = allocator,
        };
    }

    fn send(transport: *Transport, data: []const u8) !void {
        _ = transport;
        const stdout = file_compat.File.stdout();

        _ = try stdout.write("Content-Length: ");
        _ = try stdout.print("{d}\r\n\r\n", .{data.len});
        _ = try stdout.write(data);
    }

    fn receive(transport: *Transport) !?[]const u8 {
        const self: *StdioTransport = @fieldParentPtr("transport", transport);
        const stdin = file_compat.File.stdin();

        // Read headers (simplified)
        var line_buf: [1024]u8 = undefined;
        const line = try stdin.readUntilDelimiter(&line_buf, '\n');

        if (std.mem.startsWith(u8, line, "Content-Length:")) {
            const length_str = line[16..]; // Skip "Content-Length: "
            const content_length = try std.fmt.parseInt(usize, length_str, 10);

            // Skip empty line
            _ = try stdin.readUntilDelimiter(&line_buf, '\n');

            // Read content
            const content = try self.allocator.alloc(u8, content_length);
            _ = try stdin.readAll(content);

            return content;
        }

        return null;
    }

    fn close(transport: *Transport) void {
        _ = transport; // No cleanup needed for stdio
    }
};

// Message Router
pub const MessageRouter = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringMap(*const fn (std.json.Value, RequestId) anyerror!std.json.Value),

    pub fn init(allocator: std.mem.Allocator) MessageRouter {
        return MessageRouter{
            .allocator = allocator,
            .handlers = std.StringMap(*const fn (std.json.Value, RequestId) anyerror!std.json.Value).init(allocator),
        };
    }

    pub fn registerHandler(
        self: *MessageRouter,
        method: []const u8,
        handler: *const fn (std.json.Value, RequestId) anyerror!std.json.Value,
    ) !void {
        try self.handlers.put(method, handler);
    }

    pub fn handleRequest(
        self: *MessageRouter,
        request: Request,
        protocol: *ProtocolHandler,
        transport: *Transport,
    ) !void {
        if (self.handlers.get(request.method)) |handler| {
            const result = try handler(request.params orelse .null, request.id);
            const response = Response.success(result, request.id);
            const json = try protocol.serializeResponse(response);
            defer self.allocator.free(json);

            try transport.send(json);
        } else {
            const error_resp = ErrorResponse.init(ErrorCodes.METHOD_NOT_FOUND, "Method not found");
            const response = Response.errorResponse(error_resp, request.id);
            const json = try protocol.serializeResponse(response);
            defer self.allocator.free(json);

            try transport.send(json);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Request.init sets method, id, and defaults" {
    const req = Request.init("test.method", RequestId{ .number = 1 });
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("test.method", req.method);
    try testing.expect(req.params == null);
    try testing.expect(std.meta.activeTag(req.id) == .number);
    try testing.expectEqual(@as(i64, 1), req.id.number);
}

test "Request.init with string id" {
    const req = Request.init("another.method", RequestId{ .string = "abc-123" });
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("another.method", req.method);
    try testing.expect(req.params == null);
    try testing.expect(std.meta.activeTag(req.id) == .string);
    try testing.expectEqualStrings("abc-123", req.id.string);
}

test "Request.init with null id" {
    const req = Request.init("method", RequestId{ .null = {} });
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expect(std.meta.activeTag(req.id) == .null);
}

test "Request.withParams sets params field" {
    const params = std.json.Value{ .string = "param_value" };
    const req = Request.withParams("execute", params, RequestId{ .number = 5 });
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("execute", req.method);
    try testing.expect(req.params != null);
    try testing.expectEqualStrings("param_value", req.params.?.string);
    try testing.expectEqual(@as(i64, 5), req.id.number);
}

test "Request.withParams with object params" {
    var obj = std.json.ObjectMap.init(testing.allocator);
    defer obj.deinit();
    try obj.put("key", std.json.Value{ .integer = 42 });
    const params = std.json.Value{ .object = obj };
    const req = Request.withParams("run", params, RequestId{ .number = 1 });
    try testing.expect(req.params != null);
    try testing.expectEqual(@as(i64, 42), req.params.?.object.get("key").?.integer);
}

test "Response.success sets result and id, err is null" {
    const result = std.json.Value{ .string = "ok" };
    const resp = Response.success(result, RequestId{ .number = 1 });
    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expect(resp.err == null);
    try testing.expect(resp.result != null);
    try testing.expectEqualStrings("ok", resp.result.?.string);
    try testing.expectEqual(@as(i64, 1), resp.id.number);
}

test "Response.success with null result" {
    const resp = Response.success(.null, RequestId{ .null = {} });
    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expect(resp.err == null);
    try testing.expect(resp.result != null);
    try testing.expect(std.meta.activeTag(resp.result.?) == .null);
    try testing.expect(std.meta.activeTag(resp.id) == .null);
}

test "Response.errorResponse sets err, result is null" {
    const err_resp = ErrorResponse.init(-32600, "Invalid Request");
    const resp = Response.errorResponse(err_resp, RequestId{ .number = 2 });
    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expect(resp.result == null);
    try testing.expect(resp.err != null);
    try testing.expectEqual(@as(i32, -32600), resp.err.?.code);
    try testing.expectEqualStrings("Invalid Request", resp.err.?.message);
    try testing.expectEqual(@as(i64, 2), resp.id.number);
}

test "ErrorResponse.init sets code and message" {
    const err = ErrorResponse.init(-32601, "Method not found");
    try testing.expectEqual(@as(i32, -32601), err.code);
    try testing.expectEqualStrings("Method not found", err.message);
    try testing.expect(err.data == null);
}

test "ErrorResponse.init with parse error code" {
    const err = ErrorResponse.init(-32700, "Parse error");
    try testing.expectEqual(@as(i32, -32700), err.code);
    try testing.expectEqualStrings("Parse error", err.message);
    try testing.expect(err.data == null);
}

test "ErrorResponse.withData sets code, message, and data" {
    const data = std.json.Value{ .string = "extra info" };
    const err = ErrorResponse.withData(-32602, "Invalid params", data);
    try testing.expectEqual(@as(i32, -32602), err.code);
    try testing.expectEqualStrings("Invalid params", err.message);
    try testing.expect(err.data != null);
    try testing.expectEqualStrings("extra info", err.data.?.string);
}

test "ErrorResponse.withData with integer data" {
    const data = std.json.Value{ .integer = 999 };
    const err = ErrorResponse.withData(-32000, "Plugin error", data);
    try testing.expectEqual(@as(i32, -32000), err.code);
    try testing.expect(err.data != null);
    try testing.expectEqual(@as(i64, 999), err.data.?.integer);
}

test "Notification.init sets method and defaults" {
    const notif = Notification.init("core.notify");
    try testing.expectEqualStrings("2.0", notif.jsonrpc);
    try testing.expectEqualStrings("core.notify", notif.method);
    try testing.expect(notif.params == null);
}

test "Notification.withParams sets method and params" {
    const params = std.json.Value{ .bool = true };
    const notif = Notification.withParams("plugin.healthCheck", params);
    try testing.expectEqualStrings("2.0", notif.jsonrpc);
    try testing.expectEqualStrings("plugin.healthCheck", notif.method);
    try testing.expect(notif.params != null);
    try testing.expectEqual(true, notif.params.?.bool);
}

test "ErrorCodes standard JSON-RPC error codes" {
    try testing.expectEqual(@as(i32, -32700), ErrorCodes.PARSE_ERROR);
    try testing.expectEqual(@as(i32, -32600), ErrorCodes.INVALID_REQUEST);
    try testing.expectEqual(@as(i32, -32601), ErrorCodes.METHOD_NOT_FOUND);
    try testing.expectEqual(@as(i32, -32602), ErrorCodes.INVALID_PARAMS);
    try testing.expectEqual(@as(i32, -32603), ErrorCodes.INTERNAL_ERROR);
}

test "ErrorCodes application-specific error codes" {
    try testing.expectEqual(@as(i32, -32000), ErrorCodes.PLUGIN_NOT_FOUND);
    try testing.expectEqual(@as(i32, -32001), ErrorCodes.PLUGIN_ERROR);
    try testing.expectEqual(@as(i32, -32002), ErrorCodes.TIMEOUT);
    try testing.expectEqual(@as(i32, -32003), ErrorCodes.RATE_LIMITED);
}

test "Methods plugin constants" {
    try testing.expectEqualStrings("plugin.register", Methods.PLUGIN_REGISTER);
    try testing.expectEqualStrings("plugin.unregister", Methods.PLUGIN_UNREGISTER);
    try testing.expectEqualStrings("plugin.execute", Methods.PLUGIN_EXECUTE);
    try testing.expectEqualStrings("plugin.healthCheck", Methods.PLUGIN_HEALTH_CHECK);
    try testing.expectEqualStrings("plugin.shutdown", Methods.PLUGIN_SHUTDOWN);
}

test "Methods core constants" {
    try testing.expectEqualStrings("core.request", Methods.CORE_REQUEST);
    try testing.expectEqualStrings("core.notify", Methods.CORE_NOTIFY);
    try testing.expectEqualStrings("core.response", Methods.CORE_RESPONSE);
}

test "ProtocolHandler.parseMessage parses valid request" {
    var handler = ProtocolHandler.init(testing.allocator);
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}";
    const msg = try handler.parseMessage(json);
    switch (msg) {
        .request => |req| {
            try testing.expectEqualStrings("test", req.method);
            try testing.expect(std.meta.activeTag(req.id) == .number);
            try testing.expectEqual(@as(i64, 1), req.id.number);
        },
        else => try testing.expect(false),
    }
}

test "ProtocolHandler.parseMessage parses valid response" {
    var handler = ProtocolHandler.init(testing.allocator);
    const json = "{\"jsonrpc\":\"2.0\",\"result\":\"ok\",\"id\":1}";
    const msg = try handler.parseMessage(json);
    switch (msg) {
        .response => |resp| {
            try testing.expect(resp.err == null);
            try testing.expect(resp.result != null);
            try testing.expectEqualStrings("ok", resp.result.?.string);
            try testing.expectEqual(@as(i64, 1), resp.id.number);
        },
        else => try testing.expect(false),
    }
}

test "ProtocolHandler.parseMessage parses error response" {
    var handler = ProtocolHandler.init(testing.allocator);
    const json = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":1}";
    const msg = try handler.parseMessage(json);
    switch (msg) {
        .response => |resp| {
            try testing.expect(resp.result == null);
            try testing.expect(resp.err != null);
            try testing.expectEqual(@as(i32, -32600), resp.err.?.code);
            try testing.expectEqualStrings("Invalid Request", resp.err.?.message);
        },
        else => try testing.expect(false),
    }
}

test "ProtocolHandler.parseMessage parses notification (no id)" {
    var handler = ProtocolHandler.init(testing.allocator);
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}";
    const msg = try handler.parseMessage(json);
    switch (msg) {
        .notification => |notif| {
            try testing.expectEqualStrings("notify", notif.method);
            try testing.expect(notif.params == null);
        },
        else => try testing.expect(false),
    }
}

test "ProtocolHandler.parseMessage returns error on invalid JSON" {
    var handler = ProtocolHandler.init(testing.allocator);
    const result = handler.parseMessage("{invalid}");
    try testing.expect(result == error.UnexpectedToken);
}

test "ProtocolHandler.parseMessage returns invalid for missing jsonrpc field" {
    var handler = ProtocolHandler.init(testing.allocator);
    const json = "{\"method\":\"test\",\"id\":1}";
    const msg = try handler.parseMessage(json);
    switch (msg) {
        .invalid => {},
        else => try testing.expect(false),
    }
}

test "ProtocolHandler.serializeRequest produces valid JSON" {
    var handler = ProtocolHandler.init(testing.allocator);
    const req = Request.init("plugin.execute", RequestId{ .number = 42 });
    const json = try handler.serializeRequest(req);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"method\":\"plugin.execute\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\"") != null);
}

test "ProtocolHandler.serializeResponse produces valid JSON for success" {
    var handler = ProtocolHandler.init(testing.allocator);
    const resp = Response.success(std.json.Value{ .string = "done" }, RequestId{ .number = 1 });
    const json = try handler.serializeResponse(resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\"") != null);
}

test "ProtocolHandler.serializeResponse produces valid JSON for error" {
    var handler = ProtocolHandler.init(testing.allocator);
    const err_resp = ErrorResponse.init(-32601, "Method not found");
    const resp = Response.errorResponse(err_resp, RequestId{ .number = 3 });
    const json = try handler.serializeResponse(resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Method not found\"") != null);
}

test "ProtocolHandler.serializeNotification produces valid JSON" {
    var handler = ProtocolHandler.init(testing.allocator);
    const notif = Notification.init("plugin.shutdown");
    const json = try handler.serializeNotification(notif);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"method\":\"plugin.shutdown\"") != null);
}

test "RequestId null variant" {
    const id = RequestId{ .null = {} };
    try testing.expect(std.meta.activeTag(id) == .null);
}

test "RequestId number variant" {
    const id = RequestId{ .number = 99 };
    try testing.expect(std.meta.activeTag(id) == .number);
    try testing.expectEqual(@as(i64, 99), id.number);
}

test "RequestId string variant" {
    const id = RequestId{ .string = "request-xyz" };
    try testing.expect(std.meta.activeTag(id) == .string);
    try testing.expectEqualStrings("request-xyz", id.string);
}

test "MessageRouter.init initializes empty handlers map" {
    var router = MessageRouter.init(testing.allocator);
    defer router.handlers.deinit();
    try testing.expectEqual(@as(usize, 0), router.handlers.count());
}
