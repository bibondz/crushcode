# Phase 44 — Wire AgentLoop into Interactive Chat

**Phase**: 44 | **Milestone**: v3.2.0 — Agent Core Live
**Status**: 🔥 Planning | **Depends**: Phase 43 (complete)
**Goal**: `crushcode chat` uses AgentLoop.run() so AI can execute tools in a multi-turn loop.

## Context

The AgentLoop (src/agent/loop.zig, 1,187L) already implements the full agentic pattern:
- Receives AI response → parses tool_calls → executes tools → feeds results back → repeats
- Supports sequential AND parallel tool execution
- Has retry with exponential backoff, loop detection (SHA-256), context compaction
- Defines ToolCall, ToolResult, LoopMessage, AIResponse, FinishReason types
- Has AgentMode (plan/build/execute) with per-mode config

The problem: `chat.zig` manages its own conversation loop and never spawns AgentLoop.

## Plan Structure

3 plans in 2 waves:
- **Wave 1**: Plans 44-01 + 44-02 (adapter + system prompt — can run in parallel)
- **Wave 2**: Plan 44-03 (chat.zig refactor — depends on both Wave 1 outputs)

---

## Plan 44-01: AISendFn Adapter — Bridge AIClient → AgentLoop

**File**: `src/agent/ai_send_adapter.zig` (NEW, ~120 lines)

### What
Create an adapter that implements AgentLoop's `AISendFn` signature by calling `AIClient.sendChatStreaming()`.

### Why
AgentLoop.run() takes `AISendFn = *const fn (Allocator, []const LoopMessage) anyerror!AIResponse` but AIClient has a different signature: `sendChatStreaming(messages: []const ChatMessage, callback: StreamCallback) !ChatResponse`. These need bridging.

### Tasks
1. Create `AISendAdapter` struct that holds a reference to `*AIClient`
2. Implement `sendToAgentLoop()` that:
   - Converts `[]LoopMessage` → `[]ChatMessage` (map role/content fields)
   - Calls `client.sendChatStreaming()` with a callback that captures streaming tokens
   - Converts `ChatResponse` → `AIResponse` (map content, finish_reason, tool_calls)
   - Maps `finish_reason` strings ("stop", "tool_calls", "length") → `FinishReason` enum
   - Extracts `tool_calls` from `ChatResponse.choices[0].message.tool_calls` → `[]ToolCallInfo`
3. Handle streaming callback: accumulate tokens into a buffer, display to stdout during streaming
4. Handle error cases: network timeout → retry, API error → error response

### Constraints
- Must not modify AgentLoop or AIClient interfaces — this is a pure adapter
- Must handle the case where ChatResponse has no choices (API error)
- Must free all temporary allocations

### UAT
- [ ] Unit test: LoopMessage[] → ChatMessage[] conversion
- [ ] Unit test: ChatResponse → AIResponse conversion (with tool_calls)
- [ ] Unit test: FinishReason string → enum mapping
- [ ] Unit test: Empty/error response handling
- [ ] Build clean with new module in build.zig

---

## Plan 44-02: System Prompt Template with Tool Descriptions

**File**: `src/agent/system_prompt.zig` (NEW, ~150 lines)

### What
Generate a system prompt that tells the AI what tools are available and how to use them.

### Why
The AI won't use tools if it doesn't know about them. The system prompt must include:
- Tool names and descriptions
- Parameter schemas (from ToolSchema)
- Instructions for when to use each tool
- Response format expectations

### Tasks
1. Create `buildSystemPrompt()` that takes `[]const ToolSchema` and returns a formatted system prompt
2. Include tool descriptions in OpenAI function calling format:
   ```
   You are Crushcode, an AI coding assistant. You have access to the following tools:
   
   - read_file: Read file contents. Parameters: {path: string}
   - write_file: Create or overwrite a file. Parameters: {path: string, content: string}
   - edit_file: Search and replace in a file. Parameters: {path: string, old_string: string, new_string: string}
   - glob: Find files matching a pattern. Parameters: {pattern: string}
   - grep: Search file contents. Parameters: {pattern: string, path: string}
   - shell: Execute a shell command. Parameters: {command: string}
   - web_fetch: Fetch a URL's content. Parameters: {url: string}
   
   Use these tools to help the user. Always read a file before editing it.
   When editing, use edit_file with old_string (exact match) and new_string.
   ```
3. Support custom system prompt additions from config (config.system_prompt)
4. Include project context (CLAUDE.md / AGENTS.md content if present)
5. Support tool-specific instructions (e.g., "for edit_file, always show the old_string context")

### Constraints
- System prompt must be < 4000 tokens to leave room for conversation
- Must handle case where no tools are available (basic chat mode)
- Must be UTF-8 clean

### UAT
- [ ] Unit test: Empty tool list → basic prompt
- [ ] Unit test: 3 tools → prompt includes all 3 descriptions
- [ ] Unit test: With CLAUDE.md content → included in prompt
- [ ] Build clean with new module in build.zig

---

## Plan 44-03: Chat.zig Refactor — Interactive Mode Uses AgentLoop

**File**: `src/commands/chat.zig` (MODIFY existing, ~1,400 lines)

### What
Refactor the interactive chat loop in chat.zig to use AgentLoop.run() instead of its manual conversation management.

### Why
Currently chat.zig has its own loop: read input → send to AI → display response → repeat. This bypasses AgentLoop's tool execution, retry, and compaction. The refactor makes interactive chat a proper agentic session.

### Tasks
1. In the interactive chat handler function:
   - After loading config + creating AIClient, create an `AgentLoop`
   - Create the `AISendAdapter` with the client
   - Build system prompt using `buildSystemPrompt()` with available tool schemas
   - Add system prompt as first history message
   - For each user input: call `agentLoop.run(sendAdapter.sendToAgentLoop, user_input)`
   - Display `LoopResult.final_response` to user
   - If `show_intermediate` is true, display each step's tool calls and results
2. Handle the streaming display:
   - During `AISendFn` execution, stream AI response tokens to stdout (reuse existing streaming display)
   - Show tool execution progress: `⏳ executing {tool_name}...` → `✓ {tool_name} ({duration}ms)`
3. Preserve existing behavior:
   - Non-interactive single-shot mode (`crushcode chat "message"`) — keep existing path, no AgentLoop
   - `--stream` flag — streaming display during AgentLoop execution
   - `--json` flag — JSON output of LoopResult
   - `--interactive` / `-i` flag — uses AgentLoop
4. Wire tool schemas into the AI request:
   - Load default + user tool schemas (existing code at line 670-676)
   - Pass tool schemas to AIClient.setTools() (existing code at line 682)
   - This makes the AI respond with tool_calls which AgentLoop handles

### Constraints
- MUST NOT break non-interactive mode (single message → response)
- MUST preserve all existing flags (--provider, --model, --stream, --json, etc.)
- MUST NOT break TUI mode (tui flag routes to different handler)
- Keep the refactor minimal — don't rewrite chat.zig, just swap the core loop

### UAT
- [ ] `crushcode chat "hello"` — single-shot mode still works (no AgentLoop)
- [ ] `crushcode chat -i` → type "list files in src/" → AI calls `shell ls src/` → shows files
- [ ] `crushcode chat -i` → type "read main.zig" → AI calls `read_file` → shows content
- [ ] `crushcode chat -i` → type "fix the typo in config.zig" → AI calls read_file → edit_file → shows diff
- [ ] Tool call loop: AI makes 3 sequential tool calls → all execute and results display
- [ ] Build clean

---

## Wave Execution Order

```
Wave 1 (parallel):
  44-01: AISendAdapter (new file, no deps)
  44-02: System prompt (new file, no deps)

Wave 2 (sequential, depends on Wave 1):
  44-03: Chat.zig refactor (uses adapter + system prompt)
```

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `src/agent/ai_send_adapter.zig` | NEW | ~120 |
| `src/agent/system_prompt.zig` | NEW | ~150 |
| `src/commands/chat.zig` | MODIFY | ~+80/-30 |
| `build.zig` | MODIFY | +2 modules |
