# Phase 47 — Session Persistence + Restore

**Phase**: 47 | **Milestone**: v3.2.0 — Agent Core Live
**Status**: 🔥 Planning | **Depends**: Phase 44
**Goal**: Conversations survive restart. JSONL append + restore.

## Context

Sessions exist in memory but don't survive restart. The session infrastructure:
- `src/session/session_db.zig` — SQLite-backed session database
- `src/session/types.zig` — Session, Message types
- `src/commands/chat.zig` — Manages in-memory conversation history

Need: Append-only JSONL log + restore on restart so users can resume conversations.

## Plan Structure

3 plans in 2 waves:
- **Wave 1**: Plans 47-01 + 47-02 (writer + reader — can be parallel)
- **Wave 2**: Plan 47-03 (crash recovery + wiring — depends on Wave 1)

---

## Plan 47-01: JSONL Append-Only Session Log

**File**: `src/session/jsonl_writer.zig` (NEW, ~180 lines)

### What
Append every conversation event to a JSONL file so the session can be reconstructed.

### Tasks
1. Define event types:
   ```zig
   pub const SessionEvent = union(enum) {
       system_prompt: []const u8,
       user_message: []const u8,
       assistant_message: struct { content: []const u8, tool_calls: ?[]ToolCallInfo },
       tool_result: struct { tool_name: []const u8, content: []const u8, is_error: bool },
       compaction: struct { removed_count: u32, summary: []const u8 },
   };
   ```

2. JSONL format (one JSON object per line):
   ```jsonl
   {"ts":"2026-04-28T10:30:00Z","type":"system_prompt","content":"You are Crushcode..."}
   {"ts":"2026-04-28T10:30:01Z","type":"user_message","content":"read main.zig"}
   {"ts":"2026-04-28T10:30:03Z","type":"assistant_message","content":"","tool_calls":[{"name":"read_file","args":"{\"path\":\"src/main.zig\"}","id":"call_abc"}]}
   {"ts":"2026-04-28T10:30:03Z","type":"tool_result","tool_name":"read_file","content":"1: const std = ...","is_error":false}
   {"ts":"2026-04-28T10:30:05Z","type":"assistant_message","content":"Here's main.zig...","tool_calls":null}
   ```

3. `JsonlWriter` struct:
   - `init(session_dir, session_id)` — open file for append, create dir if needed
   - `writeEvent(event)` — serialize to JSON + append line + flush
   - `deinit()` — close file

4. Session directory structure:
   ```
   ~/.crushcode/sessions/
   ├── 2026-04-28_10-30-00.jsonl   ← auto-generated session ID from timestamp
   ├── 2026-04-28_14-22-33.jsonl
   └── latest.jsonl                 ← symlink to most recent
   ```

5. Integration with chat.zig:
   - Create JsonlWriter when interactive session starts
   - After each user input → write user_message event
   - After each AI response → write assistant_message event
   - After each tool execution → write tool_result event
   - On compaction → write compaction event

### UAT
- [ ] Start chat session → JSONL file created in ~/.crushcode/sessions/
- [ ] Send 3 messages → file has 3 user_message + 3 assistant_message events
- [ ] AI calls tool → tool_result event logged
- [ ] File is valid JSONL (each line parses as JSON)
- [ ] Session exits → file closed cleanly

---

## Plan 47-02: Session Restore on Restart

**File**: `src/session/jsonl_reader.zig` (NEW, ~200 lines)

### What
Read a JSONL session file and reconstruct the conversation history.

### Tasks
1. `JsonlReader` struct:
   - `init(file_path)` — open file for reading
   - `readNext()` — read next line, parse JSON, return SessionEvent
   - `readAll()` — read all events into array

2. `restoreHistory()` function:
   - Takes `[]SessionEvent` → returns `[]ChatMessage` (reconstructed conversation)
   - Map events to ChatMessage:
     - system_prompt → system message
     - user_message → user message
     - assistant_message → assistant message (with tool_calls if present)
     - tool_result → tool message
   - Reconstruct tool_call_id linkage between assistant tool_calls and tool_results

3. CLI integration:
   - `crushcode chat --resume` → find latest session, restore, continue
   - `crushcode chat --resume <session_id>` → restore specific session
   - `crushcode sessions` → list available sessions (from ~/.crushcode/sessions/)

4. Restore flow:
   ```
   $ crushcode chat --resume
   Restoring session from 2026-04-28_10-30-00 (7 messages, 2 tool calls)
   Last message: "Here's the content of main.zig..."
   
   > what about config.zig?
   [continues conversation with full context restored]
   ```

### UAT
- [ ] Restore from valid JSONL → correct ChatMessage[] history
- [ ] `crushcode chat --resume` → finds latest session, restores
- [ ] Restored conversation continues correctly (AI has prior context)
- [ ] `crushcode sessions` → lists available sessions with metadata
- [ ] Empty/malformed JSONL → graceful error, start fresh session

---

## Plan 47-03: Crash Recovery + Session Metadata

**File**: `src/session/recovery.zig` (NEW, ~120 lines)

### What
Handle crash recovery and session metadata for robust persistence.

### Tasks
1. Crash recovery:
   - On startup, check if `latest.jsonl` has a clean shutdown marker
   - If no shutdown marker → session crashed, offer to resume
   - Recovery: replay events up to last complete exchange
   - A "complete exchange" = user_message + assistant_message (with all tool_results)

2. Clean shutdown:
   - Write `{"type":"session_end","reason":"normal"}` on graceful exit
   - Handle SIGINT/SIGTERM to write shutdown marker before exit

3. Session metadata:
   - First line of JSONL is metadata: `{"type":"session_meta","id":"...","created":"...","provider":"...","model":"..."}`
   - `crushcode sessions` reads metadata to display session info
   - Show: session ID, date, message count, provider, model

4. Session cleanup:
   - Keep last 50 sessions, archive older ones
   - `crushcode sessions --cleanup` → remove sessions older than 30 days

### UAT
- [ ] Graceful exit → shutdown marker in JSONL
- [ ] Kill process → no shutdown marker → on next start, detect crash
- [ ] Crash recovery → replay to last complete exchange
- [ ] `crushcode sessions` → shows metadata for each session
- [ ] Old sessions cleaned up after 50 threshold

---

## Wave Execution Order

```
Wave 1 (parallel):
  47-01: JSONL writer
  47-02: JSONL reader + restore

Wave 2 (sequential):
  47-03: Crash recovery + metadata
```

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `src/session/jsonl_writer.zig` | NEW | ~180 |
| `src/session/jsonl_reader.zig` | NEW | ~200 |
| `src/session/recovery.zig` | NEW | ~120 |
| `src/commands/chat.zig` | MODIFY | ~+40 (writer integration) |
| `src/cli/registry.zig` | MODIFY | +2 commands (sessions, --resume flag) |
| `build.zig` | MODIFY | +3 modules |
