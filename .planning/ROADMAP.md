# Crushcode Roadmap — v0.3.x → v0.4.0

Created: 2026-04-14

## หลักการ
ทำให้ crushcode ใช้เป็น daily driver ได้จริง — ทดแทน opencode ได้

## Ref Sources (ทั้งหมดที่ใช้)
- `/mnt/d/crushcode-references/opencode/` — TypeScript/Node.js (OpenTUI + SolidJS)
- `/mnt/d/crushcode-references/crush/` — Go (Bubble Tea + Lipgloss)
- `/mnt/d/crushcode-references/open-claude-code/` — Node.js
- `/mnt/d/crushcode-references/claude-code/` — TypeScript (React + Ink)
- `/mnt/d/crushcode-references/cheetahclaws/` — Python

---

## v0.3.1 — Core Completion (ใช้งานได้จริง)

### Phase 1: File Context → AI
**ปัญหา**: TUI ส่งแค่ conversation history ให้ AI ไม่ส่ง codebase context
**ทำ**: 
- ย้าย knowledge graph context builder จาก chat.zig เข้า TUI
- ส่ง source files เป็น system prompt เหมือนที่ chat.zig ทำ (lines 588-650)
- Auto-detect project structure (src/ files, build.zig)
- แสดงใน header: `ctx: 14 files indexed`
- ไฟล์: แก้ chat_tui_app.zig — เพิ่ม context builder ตอน init

### Phase 2: Multi-turn Tool Loop
**ปัญหา**: AI ตอบแค่ทีเดียว ไม่วน tool call loop
**ทำ**:
- หลัง AI ตอบ: check ว่ามี tool_calls ไหม
- ถ้ามี: execute tools → ส่งผลกลับเป็น tool result message → เรียก AI อีกที
- วนจนกว่า AI จะตอบโดยไม่เรียก tool (หรือครบ max iterations = 10)
- แสดง tool execution progress ใน TUI
- ไฟล์: แก้ chat_tui_app.zig streaming worker — เพิ่ม tool loop

### Phase 3: Permission TUI Dialog
**ปัญหา**: AI เรียก shell command โดยไม่ถาม user
**ทำ**:
- ก่อน execute tool: popup dialog "Allow Bash: rm -rf / ? [y/n/a(lways)]"
- 3 modes: default (ask), auto (allow all), plan (ask only destructive)
- แสดง tool name + arguments ใน dialog
- จำคำตอบตาม session
- ไฟล์: แก้ chat_tui_app.zig — เพิ่ม PermissionDialog widget

### Phase 4: Provider Fallback
**ปัญหา**: provider ล่ม = จบ ไม่ลองตัวอื่น
**ทำ**:
- ต่อจาก fallback.zig ที่มีอยู่แล้ว
- ถ้า primary provider ล้มเหลว: ลองตัวถัดไปที่มี API key
- แสดงใน status bar: `⚠ openrouter timeout → trying groq`
- Auto-retry ด้วย backoff

---

## v0.3.2 — Readability Polish

### Phase 5: Full Markdown Rendering
**ปัญหา**: Markdown parser ยัง basic — ไม่รองรับ table, blockquote, nested list
**ทำ**:
- Tables: `| col1 | col2 |` → aligned columns with box-drawing chars
- Blockquotes: `> text` → dimmed prefix
- Nested lists: indentation
- Horizontal rules: `---` → full-width line
- Links: `[text](url)` → underlined text
- Task lists: `- [x] done` / `- [ ] todo` → checkbox icons ☑ ☐

### Phase 6: Diff View
**ปัญหา**: ไม่มี diff display เลย
**ทำ**:
- Unified diff: `-` red lines, `+` green lines, context dimmed
- แสดงเมื่อ AI เรียก edit/write_file tool
- Line numbers ด้านซ้าย
- Truncate ถ้า diff ยาวเกิน 30 lines + "show more"
- ไฟล์: สร้าง `src/tui/diff.zig` — diff parser + renderer

### Phase 7: Theme System
**ปัญหา**: มี theme เดียว
**ทำ**:
- Theme struct: user_fg, assistant_fg, error_fg, header_bg, code_bg, border, dimmed
- 3 built-in themes: default (dark), light, monochrome
- `/theme` command in palette — switch live
- Save preference to config.toml
- ไฟล์: สร้าง `src/tui/theme.zig`

---

## v0.4.0 — Advanced Features

### Phase 8: Session Persistence + Resume
**ทำ**:
- Auto-save conversation to `~/.crushcode/sessions/`
- `/resume` command — list sessions, pick one to continue
- Session file: JSON with messages + metadata (tokens, duration, model)
- Crash recovery: detect interrupted session, offer resume

### Phase 9: Multi-Agent in TUI
**ทำ**:
- Spawn sub-agents in background threads
- Show agent status in TUI: `● Agent 1: analyzing src/ai/... ✓`
- Results merge back into main conversation
- `/agents` palette command — spawn with category

### Phase 10: Sidebar (stretch)
**ทำ**:
- Toggle sidebar with Ctrl+B
- Show: recent files, LSP diagnostics (if available), session info
- Minimal — just file list + error count
- ไม่จำเป็นสำหรับ v0.4.0 ถ้าเวลาไม่พอ

---

## ลำดับการทำ
```
v0.3.1 Phase 1 → Phase 2 → Phase 3 → Phase 4
         (context)  (tool loop)  (permission)  (fallback)

v0.3.2 Phase 5 → Phase 6 → Phase 7
         (markdown)  (diff)  (theme)

v0.4.0 Phase 8 → Phase 9 → Phase 10
         (session)  (agents)  (sidebar)
```

## ไม่ทำ (defer indefinitely)
- Voice input
- Vim mode
- Full LSP integration (just diagnostics display)
- Package managers (deb/rpm/brew) — install command พอ
- IDE bridge (VS Code / JetBrains)
