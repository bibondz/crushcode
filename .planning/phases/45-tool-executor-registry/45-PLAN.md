# Phase 45 — Tool Executor Registry

**Phase**: 45 | **Milestone**: v3.2.0 — Agent Core Live
**Status**: 🔥 Planning | **Depends**: Phase 44
**Goal**: Map tool names → executor functions so AI can actually read/write/search files via tool calls.

## Context

AgentLoop calls `executeTool(tool_name, args_json)` but there's no dispatcher that maps tool names to actual executor functions for the built-in tools. The tool schemas are already sent to the AI (so it knows what tools exist), but when it responds with a `tool_call`, there's nothing to actually execute it.

Existing executor infrastructure:
- `src/tools/registry.zig` (530L) — ToolRegistry with register/execute pattern
- `src/tools/lsp_tools.zig` (706L) — LSP-based tools
- `src/tools/edit_batch.zig` (497L) — File editing
- `src/tools/subagent.zig` (120L) — Subagent spawning
- `src/tools/image_analyzer.zig` — Image analysis
- `src/fileops/reader.zig` — File reading
- `src/commands/read.zig` — File read command
- `src/search/semantic.zig` (381L) — Semantic search

## Plan Structure

4 plans in 2 waves:
- **Wave 1**: Plans 45-01, 45-02, 45-03 (individual tool executors — parallel)
- **Wave 2**: Plan 45-04 (registration + dispatch — depends on all Wave 1)

---

## Plan 45-01: Built-in File Tool Executors

**File**: `src/tools/executors/file_tools.zig` (NEW, ~250 lines)

### What
Implement tool executors for: `read_file`, `write_file`, `edit_file`, `glob`, `grep`.

### Tasks
1. Define `ToolExecutor` interface:
   ```zig
   pub const ToolExecutor = struct {
       name: []const u8,
       executeFn: *const fn (Allocator, std.json.Value) anyerror!ToolResult,
   };
   
   pub const ToolResult = struct {
       content: []const u8,
       is_error: bool = false,
   };
   ```

2. **read_file executor**:
   - Args: `{ path: string, offset?: number, limit?: number }`
   - Read file, return content with line numbers
   - Handle: file not found → error result, binary file → skip with warning
   - Reuse `src/fileops/reader.zig` patterns

3. **write_file executor**:
   - Args: `{ path: string, content: string, create_dirs?: boolean }`
   - Write content to file, create parent dirs if requested
   - Return: "Wrote {n} bytes to {path}"

4. **edit_file executor**:
   - Args: `{ path: string, old_string: string, new_string: string, replace_all?: boolean }`
   - Find `old_string` in file, replace with `new_string`
   - If `old_string` not found → error with context
   - If multiple matches and not `replace_all` → error listing all match locations
   - Reuse `src/tools/edit_batch.zig` logic
   - Return: diff-style output showing what changed

5. **glob executor**:
   - Args: `{ pattern: string, path?: string }`
   - Use `std.fs` to walk directory matching pattern
   - Return: list of matching file paths

6. **grep executor**:
   - Args: `{ pattern: string, path?: string, include?: string }`
   - Search file contents using regex or literal match
   - Return: matching lines with file:line prefix

### UAT
- [ ] read_file: read existing file → content with line numbers
- [ ] read_file: nonexistent file → error result
- [ ] write_file: create new file with content
- [ ] write_file: overwrite existing file
- [ ] edit_file: replace unique string → success + diff
- [ ] edit_file: old_string not found → error
- [ ] edit_file: multiple matches without replace_all → error listing locations
- [ ] glob: `**/*.zig` in src/ → list of .zig files
- [ ] grep: search "pub fn" in src/ → matching lines

---

## Plan 45-02: Shell Tool Executor

**File**: `src/tools/executors/shell_tool.zig` (NEW, ~180 lines)

### What
Execute shell commands via `std.process.Child` with permission checks and safety measures.

### Tasks
1. **shell executor**:
   - Args: `{ command: string, timeout?: number, cwd?: string }`
   - Spawn command via `std.process.Child`
   - Capture stdout + stderr
   - Apply timeout (default 30s, max 120s)
   - Return: `{ stdout, stderr, exit_code }`

2. Safety measures (reuse Phase 40 shell safety):
   - Block dangerous commands: `rm -rf /`, `mkfs`, `dd if=/dev/zero`
   - ANSI stripping on output
   - Working directory validation
   - Output truncation (max 10KB per stream)

3. Permission integration:
   - Check `src/permission/guardian.zig` before executing
   - If guardian denies → return error result with reason
   - Track command history for audit

### UAT
- [ ] `ls src/` → file listing
- [ ] `echo hello` → stdout "hello"
- [ ] `sleep 999` with timeout=1 → timeout error
- [ ] `rm -rf /` → blocked by safety
- [ ] Command with large output → truncated to 10KB

---

## Plan 45-03: Web Tool Executors

**File**: `src/tools/executors/web_tools.zig` (NEW, ~150 lines)

### What
Execute web_fetch and web_search tool calls.

### Tasks
1. **web_fetch executor**:
   - Args: `{ url: string, format?: string, timeout?: number }`
   - Use `std.http.Client` to fetch URL content
   - Return: page content (truncated to 50KB)
   - Handle: HTTP errors, timeouts, content-type detection

2. **web_search executor**:
   - Args: `{ query: string, limit?: number }`
   - This is a stub initially — requires a search API key
   - Return: "web_search not yet configured — set SEARCH_API_KEY in config"

### UAT
- [ ] web_fetch: fetch example.com → HTML content
- [ ] web_fetch: 404 URL → error result
- [ ] web_fetch: timeout → error result
- [ ] web_search: returns stub message

---

## Plan 45-04: Tool Registration + Permission-Aware Dispatch

**File**: `src/tools/executors/dispatch.zig` (NEW, ~200 lines)

### What
Central dispatcher that maps tool names → executors and routes tool calls through permission checks.

### Tasks
1. Create `ToolDispatcher` struct:
   ```zig
   pub const ToolDispatcher = struct {
       executors: std.StringHashMap(*ToolExecutor),
       guardian: *Guardian,
       
       pub fn register(dispatcher, name, executor) void;
       pub fn execute(dispatcher, tool_call: ToolCallInfo) ToolResult;
   };
   ```

2. `register()` — add executor to hashmap
3. `execute()` — the main dispatch:
   - Parse tool_call arguments from JSON string
   - Look up executor by tool_call.function.name
   - If not found → error result "Unknown tool: {name}"
   - If write operation (write_file, edit_file, shell) → check guardian permission
   - Execute tool, capture result
   - Return ToolResult

4. Permission classification:
   - **Read-only**: read_file, glob, grep, web_fetch, web_search → always allowed
   - **Write**: write_file, edit_file → require guardian approval
   - **Shell**: shell → require guardian approval + safety checks

5. Integration with AgentLoop:
   - AgentLoop already calls `executeTool()` — wire this to `dispatcher.execute()`
   - Create dispatcher in chat.zig alongside AgentLoop creation
   - Register all built-in executors

6. Update `build.zig` with new modules

### UAT
- [ ] Register 7 tools → dispatch by name → correct executor runs
- [ ] Unknown tool name → "Unknown tool" error result
- [ ] write_file without permission → blocked by guardian
- [ ] read_file without permission → allowed (read-only)
- [ ] Shell command with permission → executes
- [ ] Build clean with all new modules

---

## Wave Execution Order

```
Wave 1 (parallel):
  45-01: File tools (read/write/edit/glob/grep)
  45-02: Shell tool
  45-03: Web tools

Wave 2 (sequential, depends on Wave 1):
  45-04: Dispatcher + registration (uses all executors)
```

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `src/tools/executors/file_tools.zig` | NEW | ~250 |
| `src/tools/executors/shell_tool.zig` | NEW | ~180 |
| `src/tools/executors/web_tools.zig` | NEW | ~150 |
| `src/tools/executors/dispatch.zig` | NEW | ~200 |
| `build.zig` | MODIFY | +4 modules |
