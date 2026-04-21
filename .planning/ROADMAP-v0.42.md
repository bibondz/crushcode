# Crushcode Roadmap — v0.42+ Intelligent Context & Tool Expansion

Created: 2026-04-21
Status: Planning

## หลักการ
AI ฉลาดขึ้นเมื่อ context ดีขึ้น — ลด token waste, เพิ่ม precision, ทำให้ AI เข้าใจ codebase ลึกขึ้น

## Execution Order

```
v0.42.0 Phase 43 (smart context)    ← Reduces token waste, improves AI accuracy
v0.43.0 Phase 44 (LSP as tools)     ← Closes tool gap 20→25+
v0.44.0 Phase 45 (multi-file edit)  ← Atomic multi-file operations
v0.45.0 Phase 46 (cost analytics)   ← Leverages SQLite for /cost dashboard
v0.46.0 Phase 47 (session forking)  ← Branch any session at any point
```

---

## v0.42.0 — Smart Context

**Goal:** AI spends too many tokens on irrelevant files. Build context ranking into the tool loop so AI auto-fetches only what matters.

**ปัญหา**: AI gets dumped full codebase context regardless of query relevance. Wastes tokens on unrelated files.

**Phase 43: Smart Context Engine**

ทำ:
1. Query intent extraction — parse user message to identify relevant file types, modules, patterns
2. Context scoring — rank files by relevance to current query (already have `scoreRelevanceAdvanced()`)
3. Auto-pruning — remove low-score files from context before sending to AI
4. Progressive loading — start with top-N files, load more on demand when AI requests
5. Context window budget — track token count, fit within model's context window
6. `/context` command — show what's in context, scores, token usage

ไฟล์:
- New `src/agent/smart_context.zig` — SmartContextEngine (query → score → prune → budget)
- Modify `src/agent/context_builder.zig` — integrate smart context
- Modify `src/tui/chat_tui_app.zig` — /context command, context display

---

## v0.43.0 — LSP as Tools

**Goal:** Expose LSP operations as AI-callable tools. Closes the tool count gap (20→25+).

**ปัญหา**: AI can't navigate code structurally — no go-to-definition, no find-references, no rename, no diagnostics as tools. Claude Code has these.

**Phase 44: LSP Tool Bridge**

ทำ:
1. `lsp_definition` tool — go-to-definition, returns location + snippet
2. `lsp_references` tool — find all references, returns file:line list
3. `lsp_diagnostics` tool — get errors/warnings for a file or project
4. `lsp_rename` tool — rename symbol across workspace
5. `lsp_hover` tool — get type info / documentation for symbol
6. `lsp_symbols` tool — list symbols in file or workspace

ไฟล์:
- New `src/tools/lsp_tools.zig` — LSP tool implementations (6 tools)
- Modify `src/tui/widgets/types.zig` — 6 new tool schemas
- Modify `src/chat/tool_executors.zig` — 6 new executors + bindings + dispatch
- Modify `build.zig` — lsp_tools module registration

---

## v0.44.0 — Multi-File Edit

**Goal:** AI can edit multiple files in a single atomic operation. Massive UX win for refactoring.

**ปัญหา**: Currently one file per tool call. Refactoring across 5 files = 5 separate calls, slow and error-prone.

**Phase 45: Multi-File Edit**

ทำ:
1. `edit_batch` tool — accept array of file edits, apply atomically
2. Transaction semantics — all succeed or all roll back
3. Diff preview for multi-file — show all changes before applying
4. Build verification — run build after batch edit, rollback on failure

ไฟล์:
- New `src/tools/edit_batch.zig` — batch edit with transaction semantics
- Modify `src/tui/widgets/types.zig` — edit_batch schema
- Modify `src/chat/tool_executors.zig` — edit_batch executor + binding + dispatch
- Modify `src/tui/chat_tui_app.zig` — multi-file diff preview
- Modify `build.zig` — edit_batch module registration

---

## v0.45.0 — Cost Analytics

**Goal:** `/cost` dashboard with per-session, per-day, per-provider breakdown. SQLite makes this trivial.

**ปัญหา**: No visibility into spending. Users don't know how much each session costs.

**Phase 46: Cost Analytics**

ทำ:
1. `/cost` command — show total spend, per-provider breakdown
2. `/cost session` — cost for current session
3. `/cost today` — today's spending
4. `/cost by-model` — per-model cost comparison
5. Token tracking — input/output/token counts per request
6. Cost estimation — price per token per model, running totals

ไฟล์:
- New `src/analytics/cost_dashboard.zig` — cost calculation + formatting
- Modify `src/db/session_db.zig` — cost query functions
- Modify `src/core/slash_commands.zig` — /cost command
- Modify `src/tui/chat_tui_app.zig` — /cost display

---

## v0.46.0 — Session Forking

**Goal:** Clone any session at any point, branch from past state. SQLite makes this trivial.

**ปัญหา**: Can't branch a conversation. If AI goes wrong direction, must start over.

**Phase 47: Session Forking**

ทำ:
1. `/fork` command — fork current session at a given message point
2. `/fork list` — show all forks from current session
3. Session tree — visualize fork relationships
4. Branch switching — jump between forks
5. Merge support — optionally merge insights from a fork back

ไฟล์:
- New `src/session/fork.zig` — fork operations
- Modify `src/db/session_db.zig` — fork queries
- Modify `src/core/slash_commands.zig` — /fork command
- Modify `src/tui/chat_tui_app.zig` — fork display

---

## Not Doing (defer)
- Voice input — requires whisper.cpp, high complexity
- Vim mode — niche, high effort
- IDE bridge — out of scope for CLI
- Enterprise features — premature
