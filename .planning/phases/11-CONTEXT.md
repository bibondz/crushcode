# Phase 11 CONTEXT — LSP Deep Integration

**Phase:** 11 (v0.5.0)
**Created:** 2026-04-14
**Status:** Decisions locked

---

## Goal

Connect existing LSP client (`src/lsp/client.zig`) into the TUI (`src/tui/chat_tui_app.zig`) so that diagnostics from LSP servers appear in the sidebar when files are edited.

---

## Prior Art (Reusable Assets)

| Asset | Location | Status |
|-------|----------|--------|
| LSPClient (JSON-RPC 2.0) | `src/lsp/client.zig` (756 lines) | ✅ Production-ready — init/start/shutdown, openDocument, getDiagnostics, goToDefinition, findReferences, hover, completion |
| Auto-detect LSP server | `getLSPServer()` in client.zig | ✅ Supports: zls, rust-analyzer, gopls, typescript-language-server, pylsp, jdtls |
| Diagnostics notification handler | `handleNotification()` in client.zig | ✅ Auto-captures `textDocument/publishDiagnostics`, stores in `self.diagnostics` ArrayList |
| SidebarWidget | `chat_tui_app.zig` lines 658-889 | ✅ 4 sections: Files, Session, Workers, Theme — extensible |
| Theme severity colors | `theme.zig` | ✅ `tool_error` (red), `tool_pending` (yellow), `tool_success` (green) |
| Build module | `build.zig` line 276 | ✅ `lsp_mod` defined, NOT yet imported into `tui_mod` |

---

## Decisions

### DEC-1: LSP Lifecycle — Lazy Init, Multi-Server

- **When to start:** Lazy — first time a file of a given language is opened/edited
- **How many:** One LSP server per language, stored in a simple struct (not HashMap — Zig stdlib HashMap with string keys is heavyweight). Use `std.ArrayList(LspEntry)` where `LspEntry = struct { language: []const u8, client: LSPClient }`
- **Where to store:** New field `lsp_clients: std.ArrayList(LspEntry)` on `Model`
- **Auto-detect:** File extension → language map (build inline in chat_tui_app.zig, reuse pattern from lsp_handler.zig):
  - `.zig` → "zig", `.rs` → "rust", `.go` → "go", `.ts`/`.tsx`/`.js`/`.jsx` → "typescript", `.py` → "python", `.java` → "java"
- **Error handling:** `getLSPServer()` returns `error.LSPServerNotFound` → skip silently, no crash, no error message to user
- **Cleanup:** `Model.destroy()` iterates `lsp_clients`, calls `deinit()` on each, frees entries

### DEC-2: Diagnostics Display in Sidebar

- **Position:** New "Diagnostics" section between Workers and Theme in `SidebarWidget.draw()`
- **Summary line:** `⚠ 3 errors, 5 warnings` using severity counts
  - Error count in `theme.tool_error` color
  - Warning count in `theme.tool_pending` color
- **Detail lines (top 3):** `E src/main.zig:42 unused variable`
  - Severity prefix: `E` (error) or `W` (warning)
  - File:line extracted from diagnostic range
  - Message truncated to sidebar width - 8 chars
- **Overflow:** `+N more` (same pattern as Files section)
- **Zero state:** `(no issues)` in dimmed text
- **No diagnostics / no LSP:** Section shows `(no LSP active)` in dimmed text

### DEC-3: Update Strategy — Hybrid (Post-Edit + Draw-Loop Drain)

- **After file edit:** In `executeToolCalls()`, after executing `write_file` or `edit` tool:
  1. Detect file language from extension
  2. Ensure LSP client for that language is started (lazy init)
  3. Call `lsp_client.openDocument(uri, language, content)` with updated file content
  4. Call `lsp_client.getDiagnostics(uri)` to fetch diagnostics
  5. Store result in Model's diagnostics cache field
- **Draw-loop drain:** In `Model.draw()`, before rendering sidebar:
  1. Check if any LSP client is active
  2. For each active client, call `drainNotifications(0)` (non-blocking, timeout=0)
  3. If notifications captured diagnostics, update cache
- **Cache field:** `lsp_diagnostic_summary: ?DiagnosticSummary` on Model, where:
  ```zig
  const DiagnosticSummary = struct {
      error_count: u32,
      warning_count: u32,
      top_diagnostics: [3]?DiagnosticInfo,
  };
  const DiagnosticInfo = struct {
      severity: lsp.LSPClient.Severity,
      file: []const u8,  // owned
      line: u32,
      message: []const u8,  // owned
  };
  ```
- **No separate thread** for LSP — all operations happen on main thread

### DEC-4: Build Integration — Minimal

- **Add one import line** to `build.zig`: `addImports(tui_mod, &.{imp("lsp", lsp_mod)});`
  - Place after existing `tui_mod` imports (around line 325)
- **No new bridge module** — LSP logic lives in `chat_tui_app.zig` because:
  - LSP state is tightly coupled to Model lifecycle
  - SidebarWidget needs Model reference anyway
  - Avoids indirection for a single-consumer module
- **Import in code:** `const lsp = @import("lsp");` at top of chat_tui_app.zig

### DEC-5: Palette Command — /diag

- **Add `/diag` to `palette_command_data`** array
- **Action:** Shows full diagnostics list as assistant message (not just sidebar summary)
- **Format:** One line per diagnostic: `E src/main.zig:42:1 — unused variable`
- **Shortcut:** "d"

---

## Scope Boundaries

### IN scope:
- LSP client lifecycle in TUI
- Diagnostics in sidebar
- `/diag` palette command
- `openDocument()` after AI edits files
- Non-blocking notification drain

### OUT of scope (defer to future):
- LSP-powered goto definition / references / hover in TUI (Phase 11+ stretch)
- Code completion from LSP (Phase 11+ stretch)
- LSP configuration in config.toml (use hardcoded server map for now)
- `textDocument/didChange` incremental sync (use full `didOpen` for simplicity)
- Multiple files tracked simultaneously (track last-edited file only)

---

## Files to Modify

| File | Change |
|------|--------|
| `src/tui/chat_tui_app.zig` | Add `lsp` import, `DiagnosticSummary`/`DiagnosticInfo` types, `lsp_clients` field on Model, lazy init in `executeToolCalls`, drain in `draw`, Diagnostics section in SidebarWidget, `/diag` command |
| `build.zig` | Add `imp("lsp", lsp_mod)` to `tui_mod` imports (1 line) |

---

## Testing Approach

- **Manual:** Open TUI, ask AI to edit a `.zig` file → check sidebar shows diagnostics
- **Verify:** Kill LSP server mid-session → no crash, sidebar shows `(no LSP active)`
- **Verify:** Edit file with no LSP installed → no crash, sidebar shows `(no LSP active)`

---

*Context created: 2026-04-14*
