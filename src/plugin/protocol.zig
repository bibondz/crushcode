// JSON-RPC 2.0 Communication Protocol
// Language-agnostic protocol for Crushcode Core Engine and External Tools

const std = @import("std");

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
    error: ?ErrorResponse = null,
    id: RequestId,
    
    pub fn success(result: std.json.Value, id: RequestId) Response {
        return Response{
            .result = result,
            .id = id,
        };
    }
    
    pub fn errorResponse(error_resp: ErrorResponse, id: RequestId) Response {
        return Response{
            .error = error_resp,
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
                .error = ErrorResponse{
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
        const self = @fieldParentPtr(StdioTransport, "transport", transport);
        const stdout = std.io.getStdOut();
        
        _ = try stdout.write("Content-Length: ");
        _ = try stdout.print("{d}\r\n\r\n", .{data.len});
        _ = try stdout.write(data);
    }
    
    fn receive(transport: *Transport) !?[]const u8 {
        const self = @fieldParentPtr(StdioTransport, "transport", transport);
        const stdin = std.io.getStdIn();
        
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