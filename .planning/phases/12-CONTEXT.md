# Phase 12 CONTEXT — Multi-Agent Threading

**Phase:** 12 (v0.5.0)
**Created:** 2026-04-14
**Status:** Decisions locked

---

## Goal

Replace the polling/sleep-based `ParallelExecutor` in `src/agent/parallel.zig` with real `std.Thread.spawn()` worker threads so that multiple AI tasks can run concurrently in the background.

---

## Prior Art (Reusable Assets)

| Asset | Location | Status |
|-------|----------|--------|
| ParallelExecutor + ParallelTask | `src/agent/parallel.zig` (300 lines) | ⚠️ Stub — has data structures but no real threading |
| AgentCategory enum + parsing | `src/agent/parallel.zig` | ✅ 7 categories: visual_engineering, ultrabrain, deep, quick, general, review, research |
| RunState + TaskResult + ExecutionContext | `src/agent/task.zig` (50 lines) | ✅ Production-ready — RunState enum, TaskResult struct |
| Thread spawning pattern | `src/tui/chat_tui_app.zig` line 2809 | ✅ `std.Thread.spawn(.{}, requestThreadMain, .{self})` — working pattern |
| Mutex + Condition pattern | `src/tui/chat_tui_app.zig` lines 1678-1686 | ✅ `std.Thread.Mutex` + `std.Thread.Condition` for permission dialog |
| WorkerItem display | `src/tui/chat_tui_app.zig` lines 25-31 | ✅ Sidebar Workers section with /workers and /kill commands |

---

## Decisions

### DEC-1: Thread Pool Design — Dynamic Spawn

- **Pattern**: Dynamic spawn per task, NOT fixed thread pool
- **How**: `std.Thread.spawn(.{}, workerThreadMain, .{task_ptr})` — same config as chat_tui_app.zig
- **Max concurrent**: `max_concurrent` field on `ParallelExecutor` — default 3, configurable
- **Spawn gate**: `canAcceptMore()` check before spawn — queue pending tasks if at limit
- **Thread lifecycle**: spawn → run → set status completed/failed → thread exits → main thread joins in `reapCompleted()`
- **No thread reuse** — each task gets its own thread, joined when done. Simpler than pool, matches existing pattern.

### DEC-2: Thread-Safe Queue — Mutex + ArrayList

- **Pattern**: `CompletionQueue` struct wrapping `std.Thread.Mutex` + `std.ArrayList(CompletedWork)`
- **Location**: In `parallel.zig` itself — no new file needed
- **Operations**:
  - `push(item)` — lock → append → unlock (called by worker thread)
  - `drain()` — lock → take snapshot → clear list → unlock (called by main thread)
- **CompletedWork struct**:
  ```zig
  pub const CompletedWork = struct {
      task_id: []const u8,  // owned
      success: bool,
      output: []const u8,  // owned
      duration_ms: u64,
  };
  ```
- **No Condition Variable** — TUI draw loop acts as natural consumer (30fps polling)

### DEC-3: Worker ↔ TUI Communication — Poll-Based

- **Worker thread**: Runs AI request → pushes result to `CompletionQueue` → updates `ParallelTask.status` under mutex → exits
- **Main thread (TUI)**: In each `draw()` frame:
  1. Call `executor.reapCompleted()` — drain queue, join finished threads
  2. Map results to display (WorkerItem update or message injection)
- **Status update**: Worker thread updates `ParallelTask.status` field under executor's mutex — from `running` → `completed`/`failed`
- **Error handling**: Worker thread catches all errors, records failure message, never panics

### DEC-4: Integration with Existing WorkerItem

- **Keep WorkerItem** in chat_tui_app.zig as TUI display struct (unchanged)
- **Add `parallel_executor: ParallelExecutor`** field to Model in chat_tui_app.zig
- **Initialize**: In `Model.create()`, init executor with `max_concurrent=3`
- **Cleanup**: In `Model.destroy()`, call `executor.deinit()` — joins all running threads
- **The `worker` field** (single `?std.Thread`) in Model is for the main chat request — **keep unchanged**
- **ParallelExecutor** is for background multi-agent tasks — separate from main chat
- **Phase 12 scope**: Focus on making `ParallelExecutor` use real threads. TUI integration is minimal — just init/deinit in Model.

### DEC-5: Worker Thread Function

- **Function**: `workerThreadMain(task_ptr: *ParallelTask) void` — top-level function in parallel.zig
- **Behavior**:
  1. Set `task.status = .running` (under mutex)
  2. Execute the task (for now: sleep simulation + result string — real AI integration is future scope)
  3. Set `task.status = .completed` or `.failed` (under mutex)
  4. Push result to executor's `CompletionQueue`
- **Error resilience**: Wrap entire body in `catch |err| { ... set failed ... }` — never crash
- **Thread storage**: `ParallelTask` gains `thread: ?std.Thread` field — set after spawn, used for join

### DEC-6: Execution Model — Phase 12 Scope

- **This phase**: Implement thread spawning infrastructure only
- **What workers do**: Simulated work (configurable delay + result string) — NOT real AI requests yet
- **Why**: Real AI integration requires AIClient per thread, streaming callback per thread, etc. — that's a bigger change. Phase 12 establishes the threading infrastructure.
- **Future**: Phase 12+ will add real AI request execution in worker threads

---

## Scope Boundaries

### IN scope:
- Real `std.Thread.spawn()` for worker tasks
- `CompletionQueue` (mutex + ArrayList)
- `workerThreadMain` function
- Thread joining in `reapCompleted()`
- `ParallelTask.thread` field
- Executor init/deinit in Model
- Status update from worker thread (running → completed/failed)

### OUT of scope (defer to future):
- Real AI request execution in worker threads (AIClient per thread, streaming)
- TUI command to spawn background tasks (/background, /delegate)
- Worktree isolation per worker
- Cancellation via `std.Thread.Condition` (just set status to cancelled, thread checks periodically)

---

## Files to Modify

| File | Change |
|------|--------|
| `src/agent/parallel.zig` | Add `CompletionQueue`, `CompletedWork`, `workerThreadMain`, add `thread` field to `ParallelTask`, real `spawn()` in executor, `reapCompleted()`, fix `ArrayList` API patterns (`.empty`, `.deinit(allocator)`, `.append(allocator, item)`) |
| `src/tui/chat_tui_app.zig` | Add `parallel_executor` field to Model, init in `create()`, deinit in `destroy()` |

---

## Testing Approach

- **Manual**: Call `executor.submit()` with a task → verify thread spawns → verify status updates → verify result in completion queue
- **Verify**: `zig build` succeeds
- **Verify**: Multiple concurrent tasks run without crash
- **Verify**: `executor.deinit()` joins all threads cleanly

---

*Context created: 2026-04-14*
