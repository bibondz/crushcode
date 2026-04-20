const std = @import("std");
const args_mod = @import("args");
const mcp_client_mod = @import("mcp_client");
const mcp_discovery_mod = @import("mcp_discovery");
const mcp_server_mod = @import("mcp_server");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Handle MCP tool listing and execution
pub fn handleMCP(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const subcommand = if (args.remaining.len > 0) args.remaining[0] else "";

    if (subcommand.len == 0 or std.mem.eql(u8, subcommand, "help")) {
        stdout_print("MCP Tools — Model Context Protocol integration\n\n", .{});
        stdout_print("Usage:\n", .{});
        stdout_print("  crushcode mcp list                    List connected servers\n", .{});
        stdout_print("  crushcode mcp tools <server>          List tools on a server\n", .{});
        stdout_print("  crushcode mcp execute <server> <tool> [json]  Execute a tool\n", .{});
        stdout_print("  crushcode mcp connect <name> <command> [--args ...]  Connect via stdio\n", .{});
        stdout_print("  crushcode mcp connect <name> --transport sse --url <url>  Connect via SSE\n", .{});
        stdout_print("  crushcode mcp connect <name> --transport http --url <url>  Connect via HTTP\n", .{});
        stdout_print("  crushcode mcp discover [search]       Search for MCP servers\n", .{});
        stdout_print("  crushcode mcp serve [--transport stdio|http] [--port 8080]  Start MCP server\n", .{});
        stdout_print("\nOptions:\n", .{});
        stdout_print("  --auto-connect    Auto-discover and connect MCP servers\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "serve")) {
        const serve_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

        var transport: enum { stdio, http } = .stdio;
        var port: u16 = 8080;

        var i: usize = 0;
        while (i < serve_args.len) : (i += 1) {
            if (std.mem.eql(u8, serve_args[i], "--transport")) {
                i += 1;
                if (i < serve_args.len) {
                    if (std.mem.eql(u8, serve_args[i], "http")) {
                        transport = .http;
                    } else if (std.mem.eql(u8, serve_args[i], "stdio")) {
                        transport = .stdio;
                    }
                }
            } else if (std.mem.eql(u8, serve_args[i], "--port")) {
                i += 1;
                if (i < serve_args.len) {
                    port = std.fmt.parseInt(u16, serve_args[i], 10) catch 8080;
                }
            }
        }

        var server = mcp_server_mod.MCPServer.init(allocator);
        defer server.deinit();

        switch (transport) {
            .stdio => try server.runStdio(),
            .http => try server.runHttp(port),
        }
        return;
    }

    var client = mcp_client_mod.MCPClient.init(allocator);
    defer client.deinit();

    if (std.mem.eql(u8, subcommand, "list")) {
        if (client.servers.count() == 0) {
            stdout_print("No MCP servers configured.\n", .{});
            stdout_print("Use 'crushcode mcp connect <name> <command>' to connect.\n", .{});
            return;
        }

        stdout_print("Connected MCP Servers:\n", .{});
        stdout_print("----------------------\n", .{});
        var iter = client.servers.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            const connected = if (info == .object) blk: {
                if (info.object.get("connected")) |c| {
                    break :blk c == .bool and c.bool;
                }
                break :blk false;
            } else false;
            const status = if (connected) "✓ connected" else "✗ disconnected";
            stdout_print("  {s} — {s}\n", .{ name, status });
        }
    } else if (std.mem.eql(u8, subcommand, "tools")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode mcp tools <server>\n", .{});
            return;
        }

        const server_name = args.remaining[1];

        if (!client.connections.contains(server_name)) {
            stdout_print("Server '{s}' is not connected. Connect first.\n", .{server_name});
            return;
        }

        const tools = client.discoverTools(server_name) catch |err| {
            stdout_print("Error discovering tools from '{s}': {}\n", .{ server_name, err });
            return;
        };

        stdout_print("Tools on '{s}' ({d} found):\n", .{ server_name, tools.len });
        stdout_print("----------------------\n", .{});
        for (tools) |tool| {
            stdout_print("  {s}", .{tool.name});
            if (tool.description.len > 0) {
                stdout_print(" — {s}", .{tool.description});
            }
            stdout_print("\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "execute")) {
        if (args.remaining.len < 3) {
            stdout_print("Usage: crushcode mcp execute <server> <tool> [json-args]\n", .{});
            stdout_print("Example: crushcode mcp execute filesystem read_file '{{\"path\":\"/tmp/test.txt\"}}'\n", .{});
            return;
        }
        const server_name = args.remaining[1];
        const tool_name = args.remaining[2];

        if (!client.connections.contains(server_name)) {
            stdout_print("Server '{s}' is not connected. Connect first.\n", .{server_name});
            return;
        }

        var args_obj = std.json.ObjectMap.init(allocator);
        if (args.remaining.len >= 4) {
            const json_str = args.remaining[3];
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch |err| {
                stdout_print("Error parsing JSON arguments: {}\n", .{err});
                stdout_print("Expected valid JSON object, got: {s}\n", .{json_str});
                return;
            };
            defer parsed.deinit();
            if (parsed.value == .object) {
                args_obj = parsed.value.object;
            }
        }

        const result = client.executeTool(server_name, tool_name, args_obj) catch |err| {
            stdout_print("Error executing tool '{s}' on '{s}': {}\n", .{ tool_name, server_name, err });
            return;
        };

        if (result.success) {
            stdout_print("✓ Tool executed successfully\n", .{});
            if (result.result) |res| {
                const out = file_compat.File.stdout().writer();
                out.print("{}\n", .{res}) catch {};
                stdout_print("\n", .{});
            }
        } else {
            stdout_print("✗ Tool execution failed: {s}\n", .{result.error_message orelse "unknown error"});
        }
    } else if (std.mem.eql(u8, subcommand, "connect")) {
        if (args.remaining.len < 3) {
            stdout_print("Usage: crushcode mcp connect <name> <command> [--args ...]\n", .{});
            stdout_print("       crushcode mcp connect <name> --transport sse --url <url>\n", .{});
            stdout_print("       crushcode mcp connect <name> --transport http --url <url>\n", .{});
            stdout_print("Example: crushcode mcp connect filesystem mcp-server-filesystem /tmp\n", .{});
            stdout_print("         crushcode mcp connect my-server --transport sse --url http://localhost:8080/sse\n", .{});
            return;
        }
        const name = args.remaining[1];

        // Parse --transport and --url flags, everything else is command + args for stdio
        var transport_type: mcp_client_mod.TransportType = .stdio;
        var url: ?[]const u8 = null;
        var command: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.remaining.len) : (i += 1) {
            if (std.mem.eql(u8, args.remaining[i], "--transport")) {
                i += 1;
                if (i < args.remaining.len) {
                    if (std.mem.eql(u8, args.remaining[i], "sse")) {
                        transport_type = .sse;
                    } else if (std.mem.eql(u8, args.remaining[i], "http")) {
                        transport_type = .http;
                    }
                }
            } else if (std.mem.eql(u8, args.remaining[i], "--url")) {
                i += 1;
                if (i < args.remaining.len) {
                    url = args.remaining[i];
                }
            } else if (command == null) {
                command = args.remaining[i];
            }
        }

        // For non-stdio transports, url is required
        if (transport_type != .stdio) {
            if (url == null) {
                stdout_print("Error: --url is required for {s} transport\n", .{@tagName(transport_type)});
                return;
            }
            command = null; // not needed for SSE/HTTP
        }

        var server_args = array_list_compat.ArrayList([]const u8).init(allocator);
        defer server_args.deinit();

        // For stdio, collect positional args after the command as server arguments
        if (transport_type == .stdio and command != null) {
            var found_cmd = false;
            for (args.remaining[2..]) |arg| {
                if (std.mem.eql(u8, arg, "--transport") or std.mem.eql(u8, arg, "--url")) break;
                if (found_cmd) {
                    try server_args.append(arg);
                }
                if (std.mem.eql(u8, arg, command.?)) {
                    found_cmd = true;
                }
            }
        }

        const config = mcp_client_mod.MCPServerConfig{
            .transport = transport_type,
            .command = command,
            .url = url,
            .args = if (server_args.items.len > 0) server_args.items else null,
        };

        stdout_print("Connecting to MCP server '{s}' via {s}...\n", .{ name, @tagName(transport_type) });
        const conn = client.connectToServer(name, config) catch |err| {
            stdout_print("Error connecting to '{s}': {}\n", .{ name, err });
            return;
        };
        stdout_print("✓ Connected to '{s}' (transport: {s})\n", .{ name, @tagName(conn.transport) });

        const tools = client.discoverTools(name) catch |err| {
            stdout_print("Connected but tool discovery failed: {}\n", .{err});
            return;
        };
        stdout_print("  Found {d} tools:\n", .{tools.len});
        for (tools) |tool| {
            stdout_print("    • {s}\n", .{tool.name});
        }
    } else if (std.mem.eql(u8, subcommand, "discover")) {
        const search_term = if (args.remaining.len >= 2) args.remaining[1] else "mcp";

        var discovery = mcp_discovery_mod.MCPDiscovery.init(allocator, &client);
        const results = discovery.discoverServers(search_term) catch |err| {
            stdout_print("Error discovering servers: {}\n", .{err});
            return;
        };
        defer allocator.free(results);

        stdout_print("MCP Server Discovery (searching for '{s}'):\n", .{search_term});
        stdout_print("Found {d} results:\n\n", .{results.len});
        for (results) |result| {
            stdout_print("  {s}", .{result.name});
            if (result.description.len > 0) {
                stdout_print(" — {s}", .{result.description});
            }
            stdout_print("\n", .{});
            if (result.install_command) |cmd| {
                stdout_print("    Install: {s}\n", .{cmd});
            }
            if (result.url) |url| {
                stdout_print("    URL: {s}\n", .{url});
            }
            stdout_print("\n", .{});
        }
    } else {
        stdout_print("Unknown MCP subcommand: '{s}'\n", .{subcommand});
        stdout_print("Run 'crushcode mcp help' for usage.\n", .{});
    }
}
