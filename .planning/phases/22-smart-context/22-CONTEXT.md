# Phase 22: Smart Context + Auto-Compact — Context

**Phase:** 22
**Milestone:** v0.7.0 — Full AI Agent
**Goal:** Relevance-scored context selection and automatic context compaction when window fills

---

## Problem

1. **Knowledge graph dumps ALL files** — `buildCodebaseContext()` in `chat_tui_app.zig:873-887` iterates a hardcoded list of 8 files (`context_source_files` in `widgets/types.zig:97-106`), indexes each via `graph.indexFile()`, then calls `kg.toCompressedContext()` which outputs the entire graph. No query-aware filtering, no token budget check.

2. **Compaction not wired** — `src/agent/compaction.zig` (608 lines) has full heuristic compaction logic with tests, but:
   - `/compact` in TUI returns "not yet implemented" (`chat_tui_app.zig:2157-2158`)
   - No `ContextCompactor` instance in `Model` struct
   - No auto-compact trigger in streaming loop
   - No token tracking against model limits

3. **No token awareness** — The system prompt is assembled without any token budget calculation. Large codebase context + long conversation can silently exceed model limits, causing truncation or errors.

---

## Existing Components (already built)

### ContextCompactor (`src/agent/compaction.zig`)
- **608 lines**, well-tested (13 test cases)
- `init(allocator, max_tokens)` — creates compactor with token limit
- `needsCompaction(current_tokens)` — checks if >threshold (default 80%)
- `compactionTier(current_tokens)` — returns `.none`, `.light`, `.heavy`, `.full`
- `compact(messages)` — heuristic compaction: keeps recent window, summarizes old messages
- `compactLight(messages)` — truncates long content (>500 chars → 200 + "...")
- `compactWithSummary(messages, previous_summary)` — rolling summary with previous context
- `buildSummarizationPrompt(messages, previous_summary)` — for AI-based summarization (future use)
- `estimateTokens(text)` — char/4 heuristic
- `CompactMessage` struct: `{ role, content, timestamp }`
- `CompactResult` struct: `{ messages, tokens_saved, messages_summarized, summary }`

### KnowledgeGraph (`src/graph/graph.zig`)
- **575 lines**, well-tested
- `indexFile(path)` — parses Zig source → adds module/symbol/edge nodes
- `toCompressedContext(allocator)` — dumps full graph as text (current approach)
- `detectCommunities()` — groups by file path
- `compressionRatio()` — token savings metric
- No relevance scoring, no query-based filtering

### TUI Model (`src/tui/chat_tui_app.zig`)
- `Model.codebase_context: ?[]const u8` — stored compressed context
- `Model.context_file_count: u32` — files indexed
- `Model.max_tokens: u32` — model max output tokens
- `Model.history: std.ArrayList(core.ChatMessage)` — conversation history for AI
- `Model.messages: std.ArrayList(Message)` — display messages
- `buildCodebaseContext()` — indexes hardcoded files, stores result
- `refreshEffectiveSystemPrompt()` — assembles system prompt with context + tools

### Header (`src/tui/widgets/header.zig`)
- Simple title-only display (57 lines)
- `title: []const u8` — just a string, no structured fields
- Needs new fields for context usage display

---

## What Needs To Change

### Plan 22-01: Wire Compaction
1. Add `ContextCompactor` instance to `Model`
2. Implement `/compact` command
3. Auto-compact after AI response when threshold exceeded
4. Show context usage in header

### Plan 22-02: Relevance Context
1. Add `scoreRelevance()` to KnowledgeGraph — rank files by query similarity
2. Replace `context_source_files` hardcoded list with dynamic discovery
3. Token-aware system prompt — budget calculation + truncation
4. Header shows `ctx: 45% | 14 files`

---

## Key Constraints

- Zig 0.15.2 API: `ArrayList.append(allocator, item)`, `splitScalar()` returns iterator directly
- `export CI=true GIT_TERMINAL_PROMPT=0 GIT_EDITOR=: GIT_PAGER=cat` always
- Context compaction is heuristic-only (no AI round-trip for summaries yet)
- Token estimation: char/4 heuristic (same as compaction.zig uses)
- Must not break existing build or tests
- Keep changes minimal — wire existing code, don't rebuild
