# Zig CLI Tool Pitfalls - Crushcode Research

**Domain:** AI CLI Tool / Zig Programming
**Researched:** 2026-04-11
**Confidence:** HIGH (analyzed existing LSP errors + ecosystem research)

---

## LSP Errors Analysis

The following LSP errors were detected in the current codebase:

### Error 1: src/mcp/client.zig:87 - Expected Pointer Dereference

```zig
// Line 87: if (response.error) |err| {
```

**Root Cause:** `response` is a value type (not pointers), so optional unwrapping syntax is incorrect. The code treats `response.error` as an optional when it's actually a union or optional field.

**Fix:**
```zig
// Option A: Check if response is null first
if (response) |resp| {
    if (resp.error) |err| {
        std.log.err("Failed to discover tools: {s}", .{err.message.?});
        return error.ToolDiscoveryFailed;
    }
} else {
    return error.InvalidResponse;
}

// Option B: Use direct field access if response is always valid
if (response.error) |err| {
    std.log.err("Failed to discover tools: {s}", .{err.message.?});
    return error.ToolDiscoveryFailed;
}
```

### Error 2: src/config/provider_config.zig - Unused Local Constants

**Root Cause:** Multiple structs declared but not used anywhere in the codebase:
- `RetryPolicy` (line 50)
- `ErrorHandlingConfig` (line 58)
- `PerformanceConfig` (line 65)
- `ExtendedConfig` (line 72)

**Fix:** Either remove unused declarations or implement their usage. Given these appear to be planned features for provider configuration, mark as TODO or remove if not in scope.

### Error 3: src/plugin/interface.zig:16 - Function Type with Inferred Error Set

```zig
// Line 16-19: Function types with inferred error sets
init_fn: fn () !void,
deinit_fn: fn () void,
handle_fn: fn (request: Request) !Response,
health_fn: fn () HealthStatus,
```

**Root Cause:** Zig doesn't allow function types with inferred error sets (`!T` syntax) in struct fields. Error sets must be explicit.

**Fix:**
```zig
// Define explicit error set
const PluginError = error{
    InitFailed,
    DeinitFailed,
    HandleFailed,
    HealthCheckFailed,
};

// Use explicit error sets in function types
init_fn: fn () PluginError!void,
deinit_fn: fn () void,
handle_fn: fn (request: Request) PluginError!Response,
health_fn: fn () HealthStatus,
```

### Error 4: src/plugin/protocol.zig:47 - Syntax Error (Expected '.', Found ':')

**Root Cause:** Line 47 has incorrect syntax: `error: ?ErrorResponse = null,` should use `.error` for field access in the struct initialization.

**Fix:** Verify the field name matches the struct definition. The field is likely correctly named `error` in the struct, but the union tag usage might be wrong.

### Error 5: src/mcp/discovery.zig:8 - Undeclared Identifier 'MCPClient'

```zig
// Line 8: client: *MCPClient,
```

**Root Cause:** `MCPClient` is defined in `src/mcp/client.zig` but not imported in `discovery.zig`.

**Fix:**
```zig
// Add import at top of discovery.zig
const mcp_mod = @import("client.zig");
const MCPClient = mcp_mod.MCPClient;
```

---

## Common Zig CLI Tool Pitfalls

### 1. Memory Allocation Mistakes

| Pitfall | Description | Prevention |
|--------|-------------|------------|
| Forgetting to free | Allocating memory without corresponding free | Use arena allocators for CLI tools, defer deinit() |
| Wrong allocator | Using heap allocator everywhere | Use threadlocal allocator or arena for short-lived CLI operations |
| Slice lifetime | Returning slices that outlive allocator | Ensure caller owns allocation or use zeroing allocators |

**Best Practice for CLI Tools:**
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
```

### 2. Error Handling Mistakes

| Pitfall | Description | Prevention |
|--------|-------------|------------|
| Silent failures | Catching errors without logging | Always log error path at appropriate level |
| Inferred error sets | Using `!T` in function signatures | Explicit error sets: `error{A,B,C}!T` |
| Error union misuse | Treating errors as values | Use `try`/`catch` properly |

### 3. Optional vs Null Handling

| Pitfall | Description | Prevention |
|--------|-------------|------------|
| Wrong unwrapping | Using `|x|` on non-optionals | Check `?T` before using `orelse`/`|x|` |
| Null in structs | Confusing null with optionals | Use `?T` for optional fields |

### 4. JSON Parsing Pitfalls

| Pitfall | Description | Prevention |
|--------|-------------|------------|
| Field name mismatch | Case sensitivity in JSON keys | Use exact field names matching schema |
| Missing null checks | Accessing missing optional fields | Always use `.?` or `orelse` |
| ObjectMap confusion | Using wrong container type | Use `std.json.ObjectMap` not `std.json.Value` |

### 5. CLI Argument Parsing Mistakes

| Pitfall | Description | Prevention |
|--------|-------------|------------|
| Manual parsing | Reinventing argument parsing | Use `std.process.args()` or argparse |
| Missing help | No `--help` flag | Always implement help text |
| Invalid flags | Not validating flags | Validate before processing |

---

## AI CLI Tool Specific Pitfalls

### 1. Streaming Response Handling

```zig
// BAD: Blocking on streaming response
const response = try client.complete(prompt);
std.debug.print("{s}", .{response});

// GOOD: Handle streaming
var stream = client.streamComplete(prompt);
while (stream.next()) |chunk| {
    std.debug.print("{s}", .{chunk});
}
```

### 2. Rate Limiting

| Issue | Solution |
|------|----------|
| No backoff | Implement exponential backoff with jitter |
| Concurrent limits | Use semaphore for concurrent requests |
| Token limits | Track token usage, queue requests |

### 3. Tool Registration Discovery

```zig
// BAD: Static tool list
const tools = &[_]Tool{ tool1, tool2 };

// GOOD: Dynamic discovery
const tools = try discoverTools();
for (tools) |tool| {
    try registerTool(tool);
}
```

### 4. JSON-RPC Protocol Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Parse error | Invalid JSON | Validate request before sending |
| Invalid request | Wrong method name | Use constants for method names |
| Invalid params | Wrong param schema | Match schema exactly |

---

## Prevention Strategies for Phase Implementation

### Phase Mapping

| Phase | Focus | Pitfalls to Address | Current Errors Fixed |
|-------|-------|------------------|-------------------|
| Phase 1 | Core Infrastructure | Memory allocation, Error handling | Error 3 (function types) |
| Phase 2 | MCP Client | JSON parsing, Protocol | Error 1, Error 4, Error 5 |
| Phase 3 | Config System | Unused code cleanup | Error 2 |
| Phase 4 | Plugin System | Function signatures | Error 3 |
| Phase 5 | CLI Integration | Argument parsing, Streaming | Errors 1-5 resolved |

### Immediate Fixes Required

**Must fix before next build:**

1. **Add MCPClient import** to `discovery.zig`
2. **Fix function type error sets** in `interface.zig`
3. **Fix optional unwrapping** in `client.zig`
4. **Fix protocol field access** in `protocol.zig`
5. **Clean up unused code** or implement usage in `provider_config.zig`

---

## Best Practices Checklist

- [ ] Use arena allocators for CLI tool lifetime
- [ ] Explicit error sets in public APIs
- [ ] Always log errors with context
- [ ] Test with `--help` flag
- [ ] Validate JSON against schema before parsing
- [ ] Use constants for method/property names
- [ ] Implement proper deinit() for all init()
- [ ] Add health checks for external services
- [ ] Handle signals (SIGINT, SIGTERM) gracefully
- [ ] Rate limit and backoff for API calls

---

## Sources

- Zig GitHub Issues: Common compilation errors
- Zig Forum: Memory alignment, allocator patterns
- Context7: Zig std.json documentation
- MCP Protocol Spec: JSON-RPC 2.0

---

## Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| LSP Error Analysis | HIGH | Directly analyzed codebase |
| Zig Pitfalls | HIGH | Common patterns from Zig ecosystem |
| AI CLI Pitfalls | MEDIUM | Based on general CLI + API patterns |
| Prevention Strategies | HIGH | Proven Zig patterns |
| Phase Mapping | MEDIUM | Estimated based on code dependencies |