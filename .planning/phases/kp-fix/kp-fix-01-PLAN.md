---
phase: kp-fix
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/agent/context_builder.zig
  - src/tui/chat_tui_app.zig
  - src/commands/chat.zig
  - src/execution/autopilot.zig
  - src/commands/handlers/agent_loop_handler.zig
autonomous: true
requirements:
  - kp-fix-01
  - kp-fix-02

must_haves:
  truths:
    - "KnowledgePipeline.init() returns a heap-allocated pointer, not a stack value"
    - "Ingester and Querier internal vault pointers remain valid after init() returns"
    - "TUI initializes KnowledgePipeline without crashing (current workaround removed)"
    - "All existing call sites compile without changes to field access syntax"
    - "deinit() properly frees heap memory (no leak, no double-free)"
  artifacts:
    - path: "src/agent/context_builder.zig"
      provides: "heap-allocated KnowledgePipeline with valid internal pointers"
      contains: "fn init(allocator: Allocator, project_dir: ?[]const u8) !*KnowledgePipeline"
    - path: "src/tui/chat_tui_app.zig"
      provides: "re-enabled pipeline initialization in TUI Model.init()"
      contains: "pipeline = cognition_mod.KnowledgePipeline.init"
  key_links:
    - from: "KnowledgePipeline.init()"
      to: "KnowledgeIngester/Querier internal *KnowledgeVault"
      via: "&self.vault (stable — heap-allocated struct)"
      pattern: "KnowledgeIngester\.init\(.*&self\.vault\)"
    - from: "All call sites (chat.zig, autopilot.zig, agent_loop_handler.zig, tests)"
      to: "new *KnowledgePipeline return type"
      via: "Zig pointer auto-deref (.field access unchanged)"
      pattern: "var pipeline = try KnowledgePipeline\.init\(|pipeline\.deinit\(\)"
---

<objective>
Fix KnowledgePipeline dangling pointer crash that blocks v1.2.0 release.

Purpose: When `KnowledgePipeline.init()` returns a struct by value, internal pointers (`ingester.vault_ptr`, `querier.vault_ptr`) dangle — they point to the stack frame, not the moved struct. This causes assertion failure / segfault when the querier iterates the vault's HashMap.

Output: Stable heap-allocated KnowledgePipeline with valid internal pointers. TUI re-enabled. All existing call sites compatible.
</objective>

<execution_context>
@$HOME/.config/opencode/get-shit-done/workflows/execute-plan.md
@$HOME/.config/opencode/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@src/agent/context_builder.zig (KnowledgePipeline struct: lines 123-213)
@src/tui/chat_tui_app.zig (disabled code: lines 460-469)
@src/commands/chat.zig (call site: lines 680-707)
@src/execution/autopilot.zig (6 call sites)
@src/commands/handlers/agent_loop_handler.zig (5 call sites)

<interfaces>
<!-- Current KnowledgePipeline struct (context_builder.zig:123-133) -->
```zig
pub const KnowledgePipeline = struct {
    allocator: Allocator,
    detector: FileDetector,
    kg: KnowledgeGraph,
    vault: KnowledgeVault,
    ingester: KnowledgeIngester,   // contains *KnowledgeVault → &self.vault
    querier: KnowledgeQuerier,     // contains *KnowledgeVault → &self.vault
    pipeline_stats: PipelineStats,
    initialized: bool,
    memory: ?*LayeredMemory,
    source_tracker: SourceTracker,
};
```

<!-- Current init() signature (context_builder.zig:138) -->
```zig
pub fn init(allocator: Allocator, project_dir: ?[]const u8) !KnowledgePipeline
```

<!-- Current deinit() signature (context_builder.zig:201) -->
```zig
pub fn deinit(self: *KnowledgePipeline) void
```

<!-- All call sites use this pattern — var pipeline = try ..., pipeline.deinit() -->
<!-- chat.zig: var pipeline: cognition_mod.KnowledgePipeline = undefined; -->
<!-- autopilot.zig: var pipeline = try KnowledgePipeline.init(...); defer pipeline.deinit(); -->
<!-- agent_loop_handler.zig: var pipeline = try KnowledgePipeline.init(...); defer pipeline.deinit(); -->
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Change KnowledgePipeline.init() to return !*KnowledgePipeline (heap allocation)</name>
  <files>src/agent/context_builder.zig</files>
  <behavior>
    - Test 1: `init(allocator, null)` returns `*KnowledgePipeline`, `ingester.vault_ptr == &pipeline.vault` (pointers match, no dangle)
    - Test 2: `init(allocator, ".")` with project_dir returns `*KnowledgePipeline`, memory is created
    - Test 3: `deinit()` called → no leak (valgrind clean), struct freed, all sub-components cleaned up
    - Test 4: Both code paths (memory and no_memory branches) heap-allocate and return pointer
  </behavior>
  <action>
    Modify `pub fn init(allocator: Allocator, project_dir: ?[]const u8) !KnowledgePipeline` to return `!*KnowledgePipeline`.

    Two code paths to fix:

    **Path 1 — no_memory branch (lines 153-171):**
    - Replace local `pipeline_no_mem = KnowledgePipeline{...}` with `try allocator.create(KnowledgePipeline)` then assign fields
    - Use `errdefer allocator.destroy(pipeline_no_mem)` for rollback
    - `pipeline_no_mem.ingester = KnowledgeIngester.init(allocator, &pipeline_no_mem.vault)` — `&pipeline_no_mem.vault` is now stable (heap pointer)
    - Return `pipeline_no_mem` (which is now `*KnowledgePipeline`)

    **Path 2 — memory branch (lines 175-197):**
    - Replace local `pipeline = KnowledgePipeline{...}` with `try allocator.create(KnowledgePipeline)` then assign fields
    - Use `errdefer allocator.destroy(pipeline)` for rollback
    - Same pointer fix for ingester/querier initialization
    - Return `pipeline` (now `*KnowledgePipeline`)

    Key: `&self.vault` in heap-allocated struct is a stable pointer. Zig `.field` access on `*T` auto-derefs — all existing call sites that do `pipeline.scanProject(...)` or `pipeline.deinit()` continue to work without changes.

    **Do NOT:**
    - Return by value (the entire point of the fix)
    - Change field types on KnowledgePipeline struct
    - Change ingester/querier init patterns (just the pointer source is now stable)
  </action>
  <verify>
    <automated>zig build test --cache-dir /tmp/zigcache 2>&1 | grep -E "(PASS|FAIL|error)" | head -40</automated>
  </verify>
  <done>
    - `init()` signature changes: returns `!*KnowledgePipeline` instead of `!KnowledgePipeline`
    - Both code paths use `allocator.create(KnowledgePipeline)` 
    - Internal pointers stable: `ingester` and `querier` hold valid `&self.vault` references
    - All 24+ existing tests in context_builder.zig pass
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Update deinit() to free heap memory + update all call sites</name>
  <files>src/agent/context_builder.zig, src/commands/chat.zig, src/execution/autopilot.zig, src/commands/handlers/agent_loop_handler.zig</files>
  <behavior>
    - Test 1: `deinit()` calls `allocator.destroy(self)` after cleanup → struct freed
    - Test 2: Double deinit (accidental) → safe (initialized flag prevents double-destroy)
    - Test 3: All call sites compile with new `*KnowledgePipeline` type
  </behavior>
  <action>
    **Part A — context_builder.zig deinit() (lines 201-213):**
    - After existing cleanup (detector, kg, vault, source_tracker), add `self.allocator.destroy(self)` 
    - Keep `self.initialized = false` guard to prevent double-destroy
    - Order: cleanup sub-components first, then destroy self

    **Part B — chat.zig (lines 680-700):**
    - Change `var pipeline: cognition_mod.KnowledgePipeline = undefined` → `var pipeline: *cognition_mod.KnowledgePipeline = undefined`
    - The init() call pattern stays: `pipeline = try KnowledgePipeline.init(allocator, ".")` (now returns `*KnowledgePipeline`)
    - `pipeline.scanProject(...)` — unchanged (Zig auto-deref)
    - `pipeline.deinit()` — unchanged (takes `*KnowledgePipeline`, frees heap)

    **Part C — autopilot.zig (6 call sites, lines 387-510):**
    - Change `var pipeline = try KnowledgePipeline.init(allocator, null)` → stays same syntax
    - `pipeline` type changes from `KnowledgePipeline` to `*KnowledgePipeline` (inferred)
    - `defer pipeline.deinit()` — unchanged
    - All `.field` access — unchanged (auto-deref)

    **Part D — agent_loop_handler.zig (5 call sites, lines 79-189):**
    - Same as autopilot — only the inferred type changes
    - `defer pipeline.deinit()` — unchanged

    **Do NOT:**
    - Change `.field` access to `.*.field` (Zig auto-deref handles this)
    - Change function call patterns
    - Touch the test call sites in context_builder.zig (they use the same pattern and auto-update)
  </action>
  <verify>
    <automated>zig build test --cache-dir /tmp/zigcache 2>&1 | grep -E "(PASS|FAIL|error)" | head -40</automated>
  </verify>
  <done>
    - `deinit()` frees heap memory via `allocator.destroy(self)` after sub-component cleanup
    - chat.zig: pipeline type changed to `*KnowledgePipeline`, field access unchanged
    - autopilot.zig: 6 call sites compile, defer deinit works
    - agent_loop_handler.zig: 5 call sites compile, defer deinit works
    - Zero syntax changes needed at call sites beyond type declarations
  </done>
</task>

<task type="auto">
  <name>Task 3: Re-enable KnowledgePipeline in TUI + verify full build</name>
  <files>src/tui/chat_tui_app.zig</files>
  <action>
    In `chat_tui_app.zig` Model.init() (lines 460-474):

    **Remove the disabled block and replace with working code:**
    ```zig
    // Re-enabled: KnowledgePipeline now heap-allocated, no dangling pointers
    {
        var pipeline = cognition_mod.KnowledgePipeline.init(model.allocator, model.session_dir) catch null;
        if (pipeline) |p| {
            model.pipeline = p;
            model.pipeline_initialized = true;
        }
    }
    ```

    **Notes on the stored type:**
    - `model.pipeline` should be typed as `?*cognition_mod.KnowledgePipeline` (pointer, not value)
    - If Model struct has `pipeline: ?KnowledgePipeline` (value), change to `pipeline: ?*KnowledgePipeline` (pointer)
    - All existing `if (self.pipeline) |*p|` patterns — change to `if (self.pipeline) |p|` (it's already a pointer)
    - Check `model.pipeline_initialized` field and deinit logic for compatibility

    **Do NOT:**
    - Leave the disabled code as a comment block
    - Store the pipeline by value (would re-create the dangling pointer problem)
    - Skip deinit on Model cleanup
  </action>
  <verify>
    <automated>zig build --cache-dir /tmp/zigcache 2>&1 | tail -5</automated>
  </verify>
  <done>
    - KnowledgePipeline enabled in TUI Model.init()
    - Pipeline stored as `?*KnowledgePipeline` (pointer, not value)
    - Build passes clean with `zig build`
    - All existing features continue to work (streaming, context, chat)
  </done>
</task>

</tasks>

<verification>
**Full build + test:**
```
zig build --cache-dir /tmp/zigcache
zig build test --cache-dir /tmp/zigcache
```

**Runtime verification (manual):**
1. Start TUI: `./zig-out/bin/crushcode tui`
2. Check header shows context files indexed (pipeline is working)
3. Send a chat message — verify no crash, no assertion failure
4. Exit cleanly — no memory leak errors
</verification>

<success_criteria>
- [ ] `KnowledgePipeline.init()` returns `!*KnowledgePipeline` (heap-allocated)
- [ ] Internal vault pointers (`ingester`, `querier`) are valid — no dangling
- [ ] `deinit()` frees heap memory via `allocator.destroy(self)`
- [ ] TUI starts with pipeline enabled — no crash, files indexed
- [ ] All 4 call site files (chat.zig, autopilot.zig, agent_loop_handler.zig, context_builder.zig) compile and tests pass
- [ ] `zig build` passes clean
- [ ] No memory leaks (valgrind clean on deinit path)
</success_criteria>

<output>
After completion, create `.planning/phases/kp-fix/kp-fix-01-SUMMARY.md`
</output>