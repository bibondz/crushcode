const std = @import("std");
const tool_exposition = @import("tool_exposition");
const file_compat = @import("file_compat");

const json = std.json;
const Allocator = std.mem.Allocator;

/// MCP Server that handles JSON-RPC 2.0 requests and routes them to handlers.
/// External clients connect (via stdio, HTTP, etc.) and send requests; this
/// server parses, dispatches, and returns well-formed JSON-RPC responses.
/// Tool executor callback — when set, the MCP server delegates tool execution
/// to this function instead of returning a stub acknowledgment.
/// Arguments: (allocator, tool_name, arguments_json) → result_string or error
pub const ToolExecutorFn = *const fn (Allocator, []const u8, []const u8) anyerror![]const u8;

pub const MCPServer = struct {
    allocator: Allocator,
    exposition: tool_exposition.ToolExposition,
    tool_executor: ?ToolExecutorFn = null,

    pub fn init(allocator: Allocator) MCPServer {
        return .{
            .allocator = allocator,
            .exposition = tool_exposition.ToolExposition.init(allocator),
            .tool_executor = null,
        };
    }

    pub fn deinit(self: *MCPServer) void {
        self.exposition.deinit();
    }

    /// Parse a JSON-RPC 2.0 request, route to the appropriate handler,
    /// and return a JSON-RPC response as an owned string.
    /// Caller must free the returned slice.
    pub fn handleRequest(self: *MCPServer, request_json: []const u8) ![]const u8 {
        // Parse the incoming JSON
        const parsed = json.parseFromSlice(json.Value, self.allocator, request_json, .{}) catch {
            return self.makeParseErrorResponse();
        };
        defer parsed.deinit();

        const root = parsed.value;

        // Must be a JSON object
        if (root != .object) {
            return self.makeErrorResponse(null, -32600, "Invalid Request");
        }

        const obj = root.object;

        // Validate jsonrpc version
        const version = obj.get("jsonrpc");
        if (version == null or version.? != .string or !std.mem.eql(u8, version.?.string, "2.0")) {
            const id = extractId(obj);
            return self.makeErrorResponse(id, -32600, "Invalid Request");
        }

        // Extract method
        const method_val = obj.get("method") orelse {
            const id = extractId(obj);
            return self.makeErrorResponse(id, -32600, "Invalid Request");
        };

        if (method_val != .string) {
            const id = extractId(obj);
            return self.makeErrorResponse(id, -32600, "Invalid Request");
        }

        const method = method_val.string;
        const id = extractId(obj);
        const params = obj.get("params");

        // Route to handler
        if (std.mem.eql(u8, method, "initialize")) {
            return self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return self.handleToolsList(id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(id, params);
        } else if (std.mem.eql(u8, method, "ping")) {
            return self.handlePing(id);
        } else {
            return self.makeErrorResponse(id, -32601, "Method not found");
        }
    }

    // -- JSON-RPC method handlers --

    fn handleInitialize(self: *MCPServer, id: ?json.Value) ![]const u8 {
        var result = json.ObjectMap.init(self.allocator);

        // Server info
        var server_info = json.ObjectMap.init(self.allocator);
        try server_info.put("name", .{ .string = "crushcode" });
        try server_info.put("version", .{ .string = "0.32.0" });
        try result.put("serverInfo", .{ .object = server_info });

        // Protocol version
        try result.put("protocolVersion", .{ .string = "2024-11-05" });

        // Capabilities
        var tools_cap = json.ObjectMap.init(self.allocator);
        try tools_cap.put("listChanged", .{ .bool = false });

        var capabilities = json.ObjectMap.init(self.allocator);
        try capabilities.put("tools", .{ .object = tools_cap });
        try result.put("capabilities", .{ .object = capabilities });

        return self.makeResultResponse(id, .{ .object = result });
    }

    fn handleToolsList(self: *MCPServer, id: ?json.Value) ![]const u8 {
        const tools = try self.exposition.getToolList();
        defer self.allocator.free(tools);

        var tools_array = json.Array.init(self.allocator);
        for (tools) |tool| {
            var tool_obj = json.ObjectMap.init(self.allocator);
            try tool_obj.put("name", .{ .string = tool.name });
            try tool_obj.put("description", .{ .string = tool.description });
            try tool_obj.put("inputSchema", tool.input_schema);
            try tools_array.append(.{ .object = tool_obj });
        }

        var result = json.ObjectMap.init(self.allocator);
        try result.put("tools", .{ .array = tools_array });

        return self.makeResultResponse(id, .{ .object = result });
    }

    fn handleToolsCall(self: *MCPServer, id: ?json.Value, params: ?json.Value) ![]const u8 {
        // Validate params
        if (params == null or params.? != .object) {
            return self.makeErrorResponse(id, -32602, "Invalid params");
        }

        const params_obj = params.?.object;
        const name_val = params_obj.get("name") orelse {
            return self.makeErrorResponse(id, -32602, "Invalid params: missing 'name'");
        };

        if (name_val != .string) {
            return self.makeErrorResponse(id, -32602, "Invalid params: 'name' must be a string");
        }

        const tool_name = name_val.string;

        // Extract arguments if present
        const args_val = params_obj.get("arguments");
        const args_json: []const u8 = if (args_val) |av| blk: {
            break :blk std.json.Stringify.valueAlloc(self.allocator, av, .{}) catch "{}";
        } else "{}";

        // Delegate to tool executor callback if set
        if (self.tool_executor) |executor| {
            const exec_result = executor(self.allocator, tool_name, args_json) catch |err| {
                const err_msg = std.fmt.allocPrint(self.allocator, "Tool execution failed: {}", .{err}) catch "Tool execution failed";
                var content = json.ObjectMap.init(self.allocator);
                try content.put("type", .{ .string = "text" });
                try content.put("text", .{ .string = err_msg });
                try content.put("isError", .{ .bool = true });

                var content_array = json.Array.init(self.allocator);
                try content_array.append(.{ .object = content });

                var result = json.ObjectMap.init(self.allocator);
                try result.put("content", .{ .array = content_array });

                return self.makeResultResponse(id, .{ .object = result });
            };
            defer self.allocator.free(exec_result);

            var content = json.ObjectMap.init(self.allocator);
            try content.put("type", .{ .string = "text" });
            try content.put("text", .{ .string = exec_result });

            var content_array = json.Array.init(self.allocator);
            try content_array.append(.{ .object = content });

            var result = json.ObjectMap.init(self.allocator);
            try result.put("content", .{ .array = content_array });

            return self.makeResultResponse(id, .{ .object = result });
        }

        // No tool executor set — return helpful error
        var content = json.ObjectMap.init(self.allocator);
        try content.put("type", .{ .string = "text" });
        try content.put("text", .{ .string = "Tool execution not available (no tool_executor callback configured)" });
        try content.put("isError", .{ .bool = true });

        var content_array = json.Array.init(self.allocator);
        try content_array.append(.{ .object = content });

        var result = json.ObjectMap.init(self.allocator);
        try result.put("content", .{ .array = content_array });

        return self.makeResultResponse(id, .{ .object = result });
    }

    fn handlePing(self: *MCPServer, id: ?json.Value) ![]const u8 {
        return self.makeResultResponse(id, .{ .object = json.ObjectMap.init(self.allocator) });
    }

    // -- JSON-RPC response builders --

    fn makeResultResponse(self: *MCPServer, id: ?json.Value, result: json.Value) ![]const u8 {
        var response = json.ObjectMap.init(self.allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        if (id) |id_val| {
            try response.put("id", id_val);
        } else {
            try response.put("id", .{ .integer = 0 });
        }
        try response.put("result", result);

        const response_val: json.Value = .{ .object = response };
        return std.fmt.allocPrint(self.allocator, "{f}", .{json.fmt(response_val, .{})});
    }

    fn makeErrorResponse(self: *MCPServer, id: ?json.Value, code: i64, message: []const u8) ![]const u8 {
        var error_obj = json.ObjectMap.init(self.allocator);
        try error_obj.put("code", .{ .integer = code });
        try error_obj.put("message", .{ .string = message });

        var response = json.ObjectMap.init(self.allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        if (id) |id_val| {
            try response.put("id", id_val);
        } else {
            try response.put("id", .null);
        }
        try response.put("error", .{ .object = error_obj });

        const response_val: json.Value = .{ .object = response };
        return std.fmt.allocPrint(self.allocator, "{f}", .{json.fmt(response_val, .{})});
    }

    fn makeParseErrorResponse(self: *MCPServer) ![]const u8 {
        return self.makeErrorResponse(null, -32700, "Parse error");
    }

    // -- Helpers --

    fn extractId(obj: json.ObjectMap) ?json.Value {
        return obj.get("id");
    }

    // -- Transport methods --

    /// Run stdio transport: read lines from stdin, process each as JSON-RPC, write response to stdout.
    /// Continues until EOF on stdin.
    pub fn runStdio(self: *MCPServer) !void {
        const stdin = file_compat.File.stdin().reader();
        const stdout = file_compat.File.stdout().writer();
        const stderr = file_compat.File.stderr().writer();

        stderr.print("MCP server started (stdio)\n", .{}) catch {};

        while (true) {
            const line = (stdin.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 1024 * 1024) catch |err| {
                stderr.print("Read error: {}\n", .{err}) catch {};
                continue;
            }) orelse break;
            defer self.allocator.free(line);

            const response = self.handleRequest(line) catch |err| {
                stderr.print("Handle error: {}\n", .{err}) catch {};
                continue;
            };
            defer self.allocator.free(response);

            stdout.print("{s}\n", .{response}) catch |err| {
                stderr.print("Write error: {}\n", .{err}) catch {};
                break;
            };
        }
    }

    /// Run HTTP transport: listen on given port, accept POST / requests with JSON-RPC body.
    /// Returns response as JSON.
    pub fn runHttp(self: *MCPServer, port: u16) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        var server = try address.listen(.{});
        defer server.deinit();

        const stderr = file_compat.File.stderr().writer();
        stderr.print("MCP server started (http://127.0.0.1:{})\n", .{port}) catch {};

        while (true) {
            const conn = server.accept() catch |err| {
                stderr.print("Accept error: {}\n", .{err}) catch {};
                continue;
            };
            defer std.posix.close(conn.stream.handle);

            self.handleHttpConnection(conn) catch |err| {
                stderr.print("HTTP connection error: {}\n", .{err}) catch {};
            };
        }
    }

    fn handleHttpConnection(self: *MCPServer, conn: std.net.Server.Connection) !void {
        const fc = file_compat.File{ .handle = conn.stream.handle };
        const reader = fc.reader();
        const writer = fc.writer();

        // Read headers byte-by-byte until \r\n\r\n
        var header_buf: [8192]u8 = undefined;
        var hpos: usize = 0;
        while (hpos < header_buf.len - 3) {
            const byte = reader.readByte() catch return;
            header_buf[hpos] = byte;
            hpos += 1;
            if (hpos >= 4 and
                header_buf[hpos - 4] == '\r' and
                header_buf[hpos - 3] == '\n' and
                header_buf[hpos - 2] == '\r' and
                header_buf[hpos - 1] == '\n')
            {
                break;
            }
        }

        const headers = header_buf[0..hpos];

        // Parse Content-Length from headers
        var content_length: usize = 0;
        var line_start: usize = 0;
        while (line_start < headers.len) {
            const nl = std.mem.indexOfScalar(u8, headers[line_start..], '\n') orelse break;
            const line_end = line_start + nl;
            const line = std.mem.trimRight(u8, headers[line_start..line_end], "\r");
            if (std.mem.indexOf(u8, line, "Content-Length:")) |_| {
                const value = std.mem.trimLeft(u8, line["Content-Length:".len..], " ");
                content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            }
            line_start = line_end + 1;
        }

        if (content_length == 0) return;

        // Read body (exactly content_length bytes)
        const body = try self.allocator.alloc(u8, content_length);
        defer self.allocator.free(body);

        var bpos: usize = 0;
        while (bpos < content_length) {
            const n = try reader.read(body[bpos..]);
            if (n == 0) return error.UnexpectedEof;
            bpos += n;
        }

        // Process request
        const response = try self.handleRequest(body);
        defer self.allocator.free(response);

        // Send HTTP response
        try writer.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", .{response.len});
        try writer.writeAll(response);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "MCPServer - init and deinit" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();
}

test "MCPServer - initialize response" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Check jsonrpc version
    try testing.expect(std.mem.eql(u8, obj.get("jsonrpc").?.string, "2.0"));
    // Check id
    try testing.expect(obj.get("id").?.integer == 1);
    // Check result exists
    const result = obj.get("result").?.object;
    // Check serverInfo
    const server_info = result.get("serverInfo").?.object;
    try testing.expectEqualStrings("crushcode", server_info.get("name").?.string);
    try testing.expectEqualStrings("0.32.0", server_info.get("version").?.string);
    // Check capabilities
    const capabilities = result.get("capabilities").?.object;
    const tools = capabilities.get("tools").?.object;
    try testing.expect(tools.get("listChanged").?.bool == false);
}

test "MCPServer - tools/list returns tool array" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const result = obj.get("result").?.object;
    const tools = result.get("tools").?.array;

    try testing.expect(tools.items.len == 6);

    // Verify first tool is bash
    const first = tools.items[0].object;
    try testing.expectEqualStrings("bash", first.get("name").?.string);

    // Verify last tool is grep
    const last = tools.items[5].object;
    try testing.expectEqualStrings("grep", last.get("name").?.string);
}

test "MCPServer - ping returns empty result" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.get("result") != null);
    try testing.expect(obj.get("error") == null);
}

test "MCPServer - parse error on invalid JSON" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const response = try server.handleRequest("{not valid json");
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const err = obj.get("error").?.object;
    try testing.expect(err.get("code").?.integer == -32700);
    try testing.expectEqualStrings("Parse error", err.get("message").?.string);
}

test "MCPServer - method not found" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":4,"method":"nonexistent","params":{}}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const err = obj.get("error").?.object;
    try testing.expect(err.get("code").?.integer == -32601);
    try testing.expectEqualStrings("Method not found", err.get("message").?.string);
}

test "MCPServer - invalid request (missing jsonrpc)" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"id":5,"method":"ping"}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const err = obj.get("error").?.object;
    try testing.expect(err.get("code").?.integer == -32600);
}

test "MCPServer - tools/call with missing name" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"arguments":{}}}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const err = obj.get("error").?.object;
    try testing.expect(err.get("code").?.integer == -32602);
}

test "MCPServer - tools/call bash acknowledges" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bash","arguments":{"command":"echo hi"}}}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.get("result") != null);
    const result = obj.get("result").?.object;
    const content = result.get("content").?.array;
    try testing.expect(content.items.len == 1);
}

test "MCPServer - tools/call with invalid params (not object)" {
    var server = MCPServer.init(testing.allocator);
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":"not-an-object"}
    ;

    const response = try server.handleRequest(request);
    defer testing.allocator.free(response);

    var parsed = try json.parseFromSlice(json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const err = obj.get("error").?.object;
    try testing.expect(err.get("code").?.integer == -32602);
}
