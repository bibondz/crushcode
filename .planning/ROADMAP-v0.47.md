# Crushcode Roadmap — v0.47+ Agent Unification & Safety Net

Created: 2026-04-22
Status: Planning

## หลักการ
Agents ที่มีตอนนี้เยอะแต่ไม่คุยกัน — เชื่อม orchestrator เข้า execution จริง, ใส่ safety net, เพิ่ม multi-agent coordination

## Execution Order

```
v0.47.0 Phase 48 (agent teams live)  ← Connect orchestrator → real AI execution, parallel multi-agent
v0.48.0 Phase 49 (session tree)      ← Visual TUI session hierarchy, tree navigation
v0.49.0 Phase 50 (checkpoints)       ← Auto-snapshot before AI edits, /rewind command
v0.50.0 Phase 51 (side chains)       ← /btw context switch, return to main thread
v0.51.0 Phase 52 (semantic compress) ← AST-aware context compression 5x ratio
```

---

## Competitive Gap Being Closed

| Feature | Claude Code | OpenCode | Crushcode (after) |
|---------|------------|----------|-------------------|
| Agent Teams | ✅ | ✅ | ✅ (native Zig) |
| Session Tree View | ✅ | ✅ | ✅ (unique) |
| Checkpoints/Rewind | ✅ | ❌ | ✅ (unique) |
| Side Chains (/btw) | ✅ | ❌ | ✅ (unique) |
| Semantic Compression | ❌ | ❌ | ✅ (unique) |
| Parallel Multi-Agent | ✅ | ✅ | ✅ (native) |

---

## v0.47.0 — Live Agent Teams

**Goal:** The orchestrator exists but returns "simulated" results. Connect it to real AI execution so multiple agents can work in parallel on the same codebase.

**ปัญหา**: `src/agent/orchestrator.zig` creates plans and spawns teams but agents are stubbed. `executePhase()` returns "simulated" when WorkerRunner unavailable. We need real execution.

**Phase 48: Live Agent Teams**

ทำ:
1. Wire `OrchestrationEngine.executePhase()` → actual `AIClient.sendChatWithHistory()` calls
2. Implement `TeamCoordinator.executeParallel()` — spawn N agents with separate contexts
3. Add `/team` command in TUI — create team, assign tasks, monitor progress
4. Agent budget tracking — each agent gets token/cost limit, auto-stop when exceeded
5. Inter-agent message passing via `CoordinatorAgent` relay
6. `/team status` shows live progress of all running agents

ไฟล์ใหม่:
- `src/agent/team_coordinator.zig` — parallel team execution with shared context

ไฟล์แก้:
- `src/agent/orchestrator.zig` — replace simulated results with real AI calls
- `src/tui/chat_tui_app.zig` — /team command handlers
- `build.zig` — team_coordinator_mod registration

---

## v0.48.0 — Session Tree Navigator

**Goal:** All competitors have visual session management. Build a TUI tree view showing session hierarchy (parent → fork → side chain) with navigation.

**ปัญหา**: Sessions are flat list. No way to see which session forked from which, or navigate the tree visually.

**Phase 49: Session Tree Navigator**

ทำ:
1. `SessionTree` widget — tree view in sidebar showing session hierarchy
2. Parent-child relationship tracking in SQLite (fork tracking already exists)
3. `/tree` command — show full session tree in TUI overlay
4. Navigate to any session node with Enter key
5. Show metadata per node: provider, model, cost, message count, timestamp
6. Color-coded: active (green), forked (yellow), archived (gray)

ไฟล์ใหม่:
- `src/tui/widgets/session_tree.zig` — tree widget with expand/collapse/navigation

ไฟล์แก้:
- `src/db/session_db.zig` — getChildren(), getTree() queries
- `src/tui/chat_tui_app.zig` — /tree command, tree overlay rendering
- `src/tui/widgets/sidebar.zig` — integrate session tree into sidebar
- `build.zig` — session_tree_mod registration

---

## v0.49.0 — Checkpoints & Rewind

**Goal:** Claude Code v2.0 has automatic checkpoints. Before every AI file edit, snapshot the file state. User can /rewind to undo any AI change.

**ปัญหา**: AI edits files and if something goes wrong, user has to manually git checkout. No safety net.

**Phase 50: Checkpoints & Rewind**

ทำ:
1. `CheckpointManager` — intercept file writes/edits from tool execution
2. Before each write_file/edit/create_file: copy original to `.crushcode/checkpoints/{session_id}/{timestamp}_{filename}`
3. `/rewind` command — show list of checkpoints with timestamps and diffs
4. `/rewind <N>` — restore file to checkpoint N (with confirmation)
5. `/rewind all` — restore all files modified in current session
6. Auto-cleanup: keep last 50 checkpoints per session, prune older ones
7. Checkpoint metadata in SQLite: file_path, timestamp, operation, session_id

ไฟล์ใหม่:
- `src/safety/checkpoint.zig` — CheckpointManager with snapshot/restore/prune

ไฟล์แก้:
- `src/chat/tool_executors.zig` — intercept write_file/edit to call checkpoint before execution
- `src/db/session_db.zig` — checkpoint table CRUD
- `src/tui/chat_tui_app.zig` — /rewind command handler
- `build.zig` — checkpoint_mod registration

---

## v0.50.0 — Side Chains

**Goal:** Claude Code has `/btw` for quick context switches. Implement side chains — temporary context branches that don't pollute the main conversation.

**ปัญหา**: User is working on a complex task and needs to check something quick. Current options: open new session (loses context) or ask in main thread (pollutes context).

**Phase 51: Side Chains**

ทำ:
1. `SideChainManager` — create temporary conversation branch from current context
2. `/btw <question>` — create side chain, execute, return summary to main thread
3. Side chain uses current context snapshot but doesn't modify main conversation
4. Side chain results injected as compact summary (not full conversation)
5. `/btw history` — list all side chains in current session
6. `/btw promote <N>` — promote side chain result to main thread as full context
7. Side chains share the session's AI client but have isolated message history

ไฟล์ใหม่:
- `src/agent/side_chain.zig` — SideChainManager with create/execute/promote/summarize

ไฟล์แก้:
- `src/tui/chat_tui_app.zig` — /btw command handler
- `src/agent/context_builder.zig` — snapshot context for side chain
- `build.zig` — side_chain_mod registration

---

## v0.51.0 — Semantic Context Compression

**Goal:** NO competitor has this. AST-aware context compression that preserves 90% semantic meaning at 5:1 ratio. Lets AI work with 5x more code in the same token budget.

**ปัญหา**: Context window fills up fast with file contents. Current compaction is basic truncation. We need intelligent compression that preserves code structure.

**Phase 52: Semantic Context Compression**

ทำ:
1. `SemanticCompressor` — parse file structure, identify symbols, build importance ranking
2. Hierarchical compression levels:
   - Level 0: Full source (critical files)
   - Level 1: Function signatures + types + doc comments (important files)
   - Level 2: Module interface only — public structs, functions, types (supporting files)
   - Level 3: One-line summary per file (background files)
3. Integration with `SmartContext` — use relevance scores to determine compression level
4. Symbol-based compression: keep call targets, compress call chains
5. Import graph analysis: compress transitive dependencies more aggressively
6. /compress command — show current context breakdown by compression level
7. Token savings report: "Compressed 45K tokens → 9K tokens (5:1 ratio)"

ไฟล์ใหม่:
- `src/agent/semantic_compressor.zig` — SemanticCompressor with multi-level compression

ไฟล์แก้:
- `src/agent/smart_context.zig` — integrate compression into selectContext pipeline
- `src/agent/context_budget.zig` — account for compressed vs uncompressed tokens
- `src/tui/chat_tui_app.zig` — /compress command handler
- `build.zig` — semantic_compressor_mod registration

---

## Success Criteria

- [ ] `/team` spawns real agents that execute real AI calls in parallel
- [ ] `/tree` shows visual session hierarchy in TUI
- [ ] `/rewind` restores files to pre-AI-edit state
- [ ] `/btw` creates side chain and returns compact summary
- [ ] `/compress` shows token savings from semantic compression
- [ ] Build passes clean: `zig build --cache-dir /tmp/zigcache`
- [ ] Total builtin tools: 26 → 26 (no new tools, these are infrastructure)
- [ ] All 5 phases have working TUI commands

## Dependencies Between Phases

```
Phase 48 (agent teams) → independent
Phase 49 (session tree) → uses fork data from Phase 47
Phase 50 (checkpoints) → intercepts tool_executors
Phase 51 (side chains) → uses context_builder from Phase 48
Phase 52 (semantic compress) → integrates with smart_context from Phase 43
```

Phases 48, 49, 50 are fully independent — can be parallelized.
Phase 51 depends on Phase 48's context builder.
Phase 52 depends on Phase 43's smart_context (already complete).
