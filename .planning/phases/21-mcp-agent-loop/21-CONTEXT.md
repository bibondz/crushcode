# Phase 21 Context: MCP → Agent Loop + Tool Unification

## User Intent
Wire MCP tools into the TUI agent loop so AI can use ANY discovered MCP server tool. Unify the duplicate tool implementations.

## Problem Statement
TUI's `executeInlineTool()` (chat_tui_app.zig:2898-2906) dispatches only 6 hardcoded tools:
- read_file, shell, write_file, glob, grep, edit

MCP client (src/mcp/client.zig, 633 lines) can discover and call tools via JSON-RPC 2.0, but TUI never routes to it.

MCP bridge (src/mcp/bridge.zig, 169 lines) wraps MCP tools as ToolSchema for AI function calling, but it's never connected to TUI.

## Decisions

### Locked (D-01, D-02, D-03)
- **D-01**: Use MCPBridge as the integration point — it already wraps MCP tools as ToolSchema
- **D-02**: Replace inline tool implementations with shared tool_executors.zig (eliminate 250 lines of duplication)
- **D-03**: MCP server discovery happens at TUI init, NOT on every request

### Deferred
- Custom MCP server management UI (add/remove servers from within TUI)
- MCP tool result caching
- MCP server auto-restart on crash

## Key Files

### MCP Side (exists, needs wiring)
- `src/mcp/client.zig` — Full MCP JSON-RPC 2.0 client (633 lines)
- `src/mcp/bridge.zig` — Wraps MCP tools as ToolSchema (169 lines)
- `src/mcp/discovery.zig` — Discovers MCP servers (542 lines)
- `src/mcp/transport.zig` — Transport layer (521 lines)

### Tool Side (exists, needs sharing)
- `src/chat/tool_executors.zig` — 6 tool executors (462 lines)
- `src/tools/registry.zig` — Tool registry with metadata (530 lines)
- `src/protocol/tool_types.zig` — ToolSchema struct

### TUI Side (needs modification)
- `src/tui/chat_tui_app.zig` — Main TUI app (3154 lines)
  - Line 2898: `executeInlineTool()` — dispatches 6 hardcoded tools
  - Lines 2908-3068: Inline tool implementations (DUPLICATES of tool_executors.zig)
  - Lines 855-888: `refreshEffectiveSystemPrompt()` — builds system prompt with tool list
  - Lines 2278-2314: Agent loop with tool call execution
  - Lines 2388-2405: `executeToolCalls()` — calls executeInlineTool per tool call

### Critical Interfaces
```zig
// From src/mcp/bridge.zig
pub const MCPBridge = struct {
    pub fn addServer(self: *MCPBridge, name: []const u8, config: ServerConfig) !void
    pub fn connectServer(self: *MCPBridge, name: []const u8) !void
    pub fn connectAll(self: *MCPBridge) !void
    pub fn executeTool(self: *MCPBridge, server_name: []const u8, tool_name: []const u8, arguments: []const u8) ![]const u8
    pub fn getToolSchemas(self: *MCPBridge) ![]const ToolSchema
};

// From src/mcp/discovery.zig
pub const MCPDiscovery = struct {
    pub fn discoverServers(self: *MCPDiscovery) ![]const DiscoveredServer
};

// From src/chat/tool_executors.zig
pub fn executeBuiltinTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution
pub fn collectSupportedToolSchemas(allocator: std.mem.Allocator, tool_schemas: []const core.ToolSchema) ![]const core.ToolSchema
```
