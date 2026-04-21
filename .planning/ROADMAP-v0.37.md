# Crushcode Roadmap — v0.37+ Competitive Dominance

Created: 2026-04-21
Status: Planning

## หลักการ
เหนือกว่าทุก reference CLI — ไม่แค่ทดแทน แต่ทำให้คนเลือกใช้ crushcode

## Competitive Position (as of v0.36.0)

| Feature Area | Crushcode | Claude Code | OpenCode | Codex | Goose |
|---|---|---|---|---|---|
| Builtin tools | 17 | 40+ | 20+ | 15 | 12 |
| Providers | 22 | 1 | 20+ | 1 | 10 |
| Session backend | JSON | JSONL | SQLite | File | File |
| Syntax highlight | 20 langs ✅ | ⚠️ | ⚠️ | ❌ | ❌ |
| Knowledge Graph | ✅ unique | ❌ | ❌ | ❌ | ❌ |
| 4-layer Memory | ✅ unique | ❌ | ❌ | ❌ | ❌ |
| MoA Synthesis | ✅ unique | ❌ | ❌ | ❌ | ❌ |
| Autopilot | ✅ unique | ❌ | ❌ | ❌ | ❌ |
| LSP Integration | ✅ | ✅ | ⚠️ | ❌ | ❌ |
| Diff Preview | view-only | apply/reject | apply/reject | ❌ | ❌ |
| Image in Terminal | ❌ | ❌ | ❌ | ❌ | ❌ |
| Voice Input | ❌ | ✅ | ❌ | ❌ | ❌ |
| Vim Mode | ❌ | ✅ | ❌ | ❌ | ❌ |
| Web Search/Fetch | ❌ | ✅ | ❌ | ❌ | ❌ |
| Session Forking | ❌ | ❌ | ✅ | ❌ | ❌ |

---

## v0.37.0 — Streaming Diff Preview + Hunk Apply/Reject

**Goal:** Let users see AND approve/reject individual edits before they're applied. This is Claude Code's #1 UX advantage.

**ปัญหา**: AI edits files directly with no preview — user can't see what will change until it's done. Current diff view is read-only.

**Phase 38: Interactive Diff Preview**

ทำ:
1. Hunk-level diff display — show each change as a colored diff hunk in TUI
2. Apply/reject per hunk — user presses [y/n/a] for each change
3. Multi-hunk navigation — [n]ext/[p]rev/[a]ll/[q]uit across hunks
4. Syntax highlighting in diff — use the existing 20-language highlighter
5. Undo support — rejected hunks don't apply, applied hunks can be undone
6. Context lines — show 3 lines of context around each hunk (Myers diff)

ไฟล์:
- Modify `src/tui/chat_tui_app.zig` — add DiffPreviewMsg, hunk navigation state
- Modify `src/diff/myers.zig` — add hunk generation with context lines
- New `src/tui/widgets/diff_preview.zig` — interactive diff preview widget
- Modify `src/chat/tool_executors.zig` — intercept write/edit tools, route to preview

**Plans:** 1 plan
- [ ] 38-01-PLAN.md — Interactive diff preview widget + hunk apply/reject flow

---

## v0.38.0 — Crush Mode (Auto-Agentic)

**Goal:** One command: `crushcode crush "fix all auth bugs"` → auto plan → execute → verify → commit. No competitor does this.

**ปัญหา**: Every other CLI requires manual back-and-forth. Crush Mode automates the entire cycle leveraging our unique Knowledge Graph + Memory + MoA.

**Phase 39: Crush Mode Engine**

ทำ:
1. Task parser — parse natural language task into structured steps
2. Auto-plan generation — use Knowledge Graph to understand codebase, generate execution plan
3. Step-by-step execution — execute each step with tool calls, auto-approve safe operations
4. Auto-verify — after each step, run build/tests to verify changes
5. Auto-commit — if verification passes, commit with descriptive message
6. Progress display — show plan steps, current step, tool calls, verification results
7. Human-in-the-loop — pause on risky operations (deletions, destructive commands)
8. `/crush` TUI command — enter crush mode from within chat
9. CLI entry — `crushcode crush "description"` from command line

ไฟล์:
- New `src/execution/crush_mode.zig` — CrushMode engine (task → plan → exec → verify → commit)
- Modify `src/execution/autopilot.zig` — integrate crush mode as new agent type
- Modify `src/tui/chat_tui_app.zig` — crush mode state machine, progress display
- Modify `src/cli/args.zig` — add `crush` subcommand

**Plans:** 1 plan
- [ ] 39-01-PLAN.md — Crush Mode engine with plan-generate-execute-verify-commit cycle

---

## v0.39.0 — SQLite Session Backend

**Goal:** Replace JSON with SQLite for sessions. Enables fast queries, crash recovery, session forking, cost analytics.

**ปัญหา**: JSON sessions are slow for large histories, no crash recovery, no analytics. OpenCode uses SQLite for this.

**Phase 40: SQLite Session Backend**

ทำ:
1. SQLite integration — use Zig's std lib or minimal C bindings for SQLite
2. Schema — sessions, messages, parts, tools, tokens tables with proper indexes
3. Migration system — auto-migrate from JSON to SQLite on first run
4. Fast queries — session list, search messages, cost analytics via SQL
5. Crash recovery — WAL mode + integrity check on startup
6. Session forking — clone session at any point, branch from past state
7. Cost analytics — `/cost` shows per-session, per-day, per-provider breakdown
8. Backward compatible — existing JSON sessions auto-imported

ไฟล์:
- New `src/session/sqlite_backend.zig` — SQLite session storage
- New `src/session/migration.zig` — JSON → SQLite migration
- Modify `src/session.zig` — add SQLite backend option
- Modify `src/tui/chat_tui_app.zig` — use SQLite for session persistence

**Plans:** 1 plan
- [ ] 40-01-PLAN.md — SQLite session backend with migration and analytics

---

## v0.40.0 — Web Tools

**Goal:** Give AI web search and URL fetch capabilities. Closes the tool count gap without adding complexity.

**ปัญหา**: AI can't search the web or fetch documentation. Claude Code has this built-in.

**Phase 41: Web Search + Fetch Tools**

ทำ:
1. `web_search` tool — search the web using configurable search API (SearXNG, Google, DuckDuckGo)
2. `web_fetch` tool — fetch and extract text content from URLs
3. HTML → Markdown conversion — strip HTML tags, keep code blocks
4. Rate limiting — prevent excessive requests
5. Caching — cache fetch results for session duration
6. Config — search provider config in config.toml
7. Safety — URL allowlist/blocklist, max response size

ไฟล์:
- New `src/tools/web_search.zig` — web search tool implementation
- New `src/tools/web_fetch.zig` — URL content fetcher + HTML→Markdown
- Modify `src/chat/tool_executors.zig` — register web tools
- Modify `src/config/config.zig` — web tool configuration

**Plans:** 1 plan
- [ ] 41-01-PLAN.md — Web search and fetch tools with configurable backends

---

## v0.41.0 — Image in Terminal

**Goal:** Display images inline in the terminal using Kitty/Sixel protocols. Unique differentiator — no AI coding CLI does this.

**ปัญหา**: No AI coding CLI can display images in the terminal. We'd be the first.

**Phase 42: Image Display (Kitty/Sixel)**

ทำ:
1. Kitty graphics protocol — send images via escape sequences (supported by Kitty, WezTerm, Ghostty)
2. Sixel fallback — for terminals that support Sixel (xterm, mlterm)
3. Image detection — detect terminal protocol support at startup
4. Inline display — show images inline in chat messages (screenshots, diagrams, etc.)
5. Image tool — AI can request to display an image
6. Resize — fit images to terminal width
7. Graceful fallback — if terminal doesn't support images, show [image: path.png] placeholder

ไฟล์:
- New `src/tui/image.zig` — Kitty/Sixel protocol encoder
- Modify `src/tui/chat_tui_app.zig` — image rendering in message display
- New `src/tools/image_display.zig` — image display tool
- Modify `src/detection/file_type.zig` — integrate image detection

**Plans:** 1 plan
- [ ] 42-01-PLAN.md — Kitty/Sixel image protocol support with terminal detection

---

## Execution Order

```
v0.37.0 Phase 38  (diff preview)     ← Highest UX impact, closes biggest gap
v0.38.0 Phase 39  (crush mode)       ← Killer feature, unique to crushcode
v0.39.0 Phase 40  (SQLite sessions)  ← Foundation for analytics + reliability
v0.40.0 Phase 41  (web tools)        ← Closes tool gap, enables research tasks
v0.41.0 Phase 42  (image display)    ← Unique differentiator, wow factor
```

## Not Doing (defer)
- Voice input — requires whisper.cpp integration, high complexity for low usage
- Vim mode — niche, high effort
- IDE bridge (VS Code/JetBrains) — out of scope for CLI tool
- Enterprise features (OAuth, RBAC, console) — premature optimization
- Session timeline UI — nice-to-have but not critical
