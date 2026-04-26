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
    - "KnowledgePipeline.init() returns a heap-allocated pointer — internal vault pointers never dangle"
    - "TUI starts without assertion/segfault when pipeline is enabled"
    - "All call sites pass *KnowledgePipeline to AutopilotEngine.init() correctly (no double-pointer)"
    - "deinit() frees heap memory — no leak, no double-free"
    - "Model.pipeline stores ?*KnowledgePipeline (pointer), not value copy"
  artifacts:
    - path: "src/agent/context_builder.zig"
      provides: "heap-allocated KnowledgePipeline with valid internal pointers"
      contains: "fn init(allocator: Allocator, project_dir: ?[]const u8) !*KnowledgePipeline"
    - path: "src/tui/chat_tui_app.zig"
      provides: "re-enabled pipeline initialization in TUI Model.init()"
      contains: "pipeline: ?*cognition_mod.KnowledgePipeline"
  key_links:
    - from: "KnowledgePipeline.init()"
      to: "KnowledgeIngester/Querier internal *KnowledgeVault"
      via: "&pipeline.vault on heap-allocated struct (stable address)"
      pattern: "KnowledgeIngester\.init\(.*&.*\.vault\)"
    - from: "agent_loop_handler.zig / autopilot.zig call sites"
      to: "AutopilotEngine.init(allocator, pipeline, ...)"
      via: "pipeline is now *KnowledgePipeline — pass directly, NOT &pipeline"
      pattern: "AutopilotEngine\.init\(.*pipeline"
    - from: "TUI Model struct"
      to: "pipeline field"
      via: "?*KnowledgePipeline — all if-pipeline captures use |p| not |*p|"
      pattern: "if \(self\.pipeline\) \|p\|"
---

<objective>
Fix KnowledgePipeline dangling pointer crash that blocks v1.2.0 release.

Purpose: When `KnowledgePipeline.init()` returns a struct by value, internal pointers (`ingester` and `querier` hold `*KnowledgeVault` → `&self.vault`) dangle — they reference the stack frame of `init()`, not the returned struct. When the querier later iterates the vault's HashMap, it hits invalid memory → assertion failure / segfault.

Output: Stable heap-allocated KnowledgePipeline with valid internal pointers. TUI re-enabled. All existing call sites updated.
</objective>

<execution_context>
@$HOME/.config/opencode/get-shit-done/workflows/execute-plan.md
@$HOME/.config/opencode/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@src/agent/context_builder.zig
@src/tui/chat_tui_app.zig
@src/commands/chat.zig
@src/execution/autopilot.zig
@src/commands/handlers/agent_loop_handler.zig

<interfaces>
<!-- KnowledgePipeline struct (context_builder.zig:123-134) -->
```zig
pub const KnowledgePipeline = struct {
    allocator: Allocator,
    detector: FileDetector,
    kg: KnowledgeGraph,
    vault: KnowledgeVault,
    ingester: KnowledgeIngester,   // holds *KnowledgeVault → must point to &self.vault
    querier: KnowledgeQuerier,     // holds *KnowledgeVault → must point to &self.vault
    pipeline_stats: PipelineStats,
    initialized: bool,
    memory: ?*LayeredMemory,
    source_tracker: SourceTracker,
};
```

<!-- AutopilotEngine.init expects *KnowledgePipeline (already pointer!) -->
```zig
// autopilot.zig:65-70
pub fn init(
    allocator: Allocator,
    pipeline: *KnowledgePipeline,  // <-- already takes pointer
    guardian: ?*Guardian,
    project_dir: []const u8,
    results_dir: []const u8,
) !AutopilotEngine
```

<!-- Current call site patterns (MUST change after fix): -->
<!-- BEFORE: var pipeline = try KnowledgePipeline.init(allocator, null); -->
<!-- BEFORE: var engine = try AutopilotEngine.init(allocator, &pipeline, ...); // &pipeline = **KnowledgePipeline WRONG after fix -->

<!-- AFTER:  var pipeline = try KnowledgePipeline.init(allocator, null); -->
<!-- AFTER:  var engine = try AutopilotEngine.init(allocator, pipeline, ...);  // pipeline already *KnowledgePipeline -->

<!-- Model struct field (chat_tui_app.zig:328): -->
```zig
pipeline: ?cognition_mod.KnowledgePipeline = null,  // BEFORE — value storage
// AFTER: pipeline: ?*cognition_mod.KnowledgePipeline = null,  // pointer storage
```

<!-- All TUI pipeline access patterns (BEFORE → AFTER): -->
<!-- if (self.pipeline) |*p| p.scanProject(...) → if (self.pipeline) |p| p.scanProject(...) -->
<!-- if (self.pipeline) |*p| p.deinit()         → if (self.pipeline) |p| p.deinit() -->
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Change init() to return !*KnowledgePipeline + update deinit() to free heap</name>
  <files>src/agent/context_builder.zig</files>
  <action>
    **Change init() signature (line 138):**
    `pub fn init(allocator: Allocator, project_dir: ?[]const u8) !KnowledgePipeline`
    → `pub fn init(allocator: Allocator, project_dir: ?[]const u8) !*KnowledgePipeline`

    **Path 1 — no_memory branch (lines 153-170):**
    Replace the local struct literal with heap allocation:
    ```zig
    const pipeline_no_mem = try allocator.create(KnowledgePipeline);
    errdefer allocator.destroy(pipeline_no_mem);
    pipeline_no_mem.* = KnowledgePipeline{
        .allocator = allocator,
        .detector = detector,
        .kg = KnowledgeGraph.init(allocator),
        .vault = KnowledgeVault.init(allocator, ".knowledge/raw") catch {
            allocator.destroy(pipeline_no_mem);
            detector.deinit();
            return error.PipelineInitFailed;
        },
        .ingester = undefined,
        .querier = undefined,
        .pipeline_stats = PipelineStats{},
        .initialized = true,
        .memory = null,
        .source_tracker = SourceTracker.init(allocator),
    };
    pipeline_no_mem.ingester = KnowledgeIngester.init(allocator, &pipeline_no_mem.vault);
    pipeline_no_mem.querier = KnowledgeQuerier.init(allocator, &pipeline_no_mem.vault);
    return pipeline_no_mem;
    ```
    Key: `&pipeline_no_mem.vault` is now a stable heap address.

    **Path 2 — memory branch (lines 175-197):**
    Same pattern — `try allocator.create(KnowledgePipeline)`, `errdefer allocator.destroy(pipeline)`, assign fields to `pipeline.*`, then:
    ```zig
    pipeline.ingester = KnowledgeIngester.init(allocator, &pipeline.vault);
    pipeline.querier = KnowledgeQuerier.init(allocator, &pipeline.vault);
    return pipeline;
    ```

    **Update deinit() (lines 201-213):**
    After existing cleanup (detector, kg, vault, source_tracker), add:
    ```zig
    self.initialized = false;
    self.allocator.destroy(self);  // free heap allocation
    ```
    The `initialized` guard must come BEFORE cleanup, and `self.allocator.destroy(self)` must be LAST since it frees `self` (making all `self.X` access invalid after).

    **Do NOT:**
    - Change field types on KnowledgePipeline struct
    - Change ingester/querier init patterns (only the allocator source changes)
    - Forget errdefer cleanup on the errdefer chain
  </action>
  <verify>
    <automated>zig build --cache-dir /tmp/zigcache 2>&1 | tail -3</automated>
  </verify>
  <done>
    - `init()` returns `!*KnowledgePipeline` — heap-allocated via `allocator.create()`
    - Both code paths (memory/no-memory) use same heap pattern
    - `&pipeline.vault` is a stable heap address — no dangling pointers
    - `deinit()` calls `allocator.destroy(self)` as last step after sub-component cleanup
    - File compiles (call site errors expected — fixed in Task 2)
  </done>
</task>

<task type="auto">
  <name>Task 2: Update all call sites — remove & where pipeline is already a pointer</name>
  <files>src/execution/autopilot.zig, src/commands/handlers/agent_loop_handler.zig, src/commands/chat.zig</files>
  <action>
    **autopilot.zig — 6 test call sites (lines 387-509):**
    `init()` now returns `*KnowledgePipeline`. The tests currently do:
    ```zig
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();
    var engine = try AutopilotEngine.init(allocator, &pipeline, ...);
    ```
    Since `pipeline` is now `*KnowledgePipeline` (pointer), `&pipeline` gives `**KnowledgePipeline` — wrong type.
    Fix: Remove `&` from all 6 AutopilotEngine.init() calls:
    ```zig
    var pipeline = try KnowledgePipeline.init(allocator, null);
    defer pipeline.deinit();
    var engine = try AutopilotEngine.init(allocator, pipeline, ...);
    ```
    Lines to change: 390, 406, 428, 443, 464, 511.

    **agent_loop_handler.zig — 5 call sites (lines 79-194):**
    Same pattern — remove `&` from all `AutopilotEngine.init(allocator, &pipeline, ...)`.
    Lines to change: 81, 114, 163, 178, 194.
    ```zig
    // BEFORE (line 81):
    var engine = autopilot_mod.AutopilotEngine.init(allocator, &pipeline, null, ".", ".crushcode/autopilot/") catch return;
    // AFTER:
    var engine = autopilot_mod.AutopilotEngine.init(allocator, pipeline, null, ".", ".crushcode/autopilot/") catch return;
    ```

    Also on lines 79, 102, 161, 176, 188: the `catch return` / `catch { ... }` pattern is fine — `init()` now returns `!*KnowledgePipeline`, catch gives `null` on failure.

    **chat.zig — 1 call site (lines 680-700):**
    Change type declaration:
    ```zig
    // BEFORE:
    var pipeline: cognition_mod.KnowledgePipeline = undefined;
    // AFTER:
    var pipeline: *cognition_mod.KnowledgePipeline = undefined;
    ```
    The catch block (lines 684-696) — both branches call `init()` which now returns `*KnowledgePipeline`:
    ```zig
    pipeline = cognition_mod.KnowledgePipeline.init(allocator, ".") catch blk: {
        const p = cognition_mod.KnowledgePipeline.init(allocator, null) catch {
            // ...fallback...
            return;
        };
        break :blk p;
    };
    ```
    This still works — `p` is `*KnowledgePipeline`, `break :blk p` assigns to `pipeline`.

    All `.field` access (pipeline.scanProject, pipeline.deinit, pipeline.indexGraphToVault, etc.) — unchanged, Zig auto-derefs.

    **Do NOT:**
    - Add `&` anywhere — pipeline IS the pointer now
    - Change method calls like .scanProject, .deinit, .indexGraphToVault
    - Touch the catch/return patterns
  </action>
  <verify>
    <automated>zig build --cache-dir /tmp/zigcache 2>&1 | tail -5</automated>
  </verify>
  <done>
    - autopilot.zig: 6 `&pipeline` → `pipeline` changes, all tests compile
    - agent_loop_handler.zig: 5 `&pipeline` → `pipeline` changes, all code paths compile
    - chat.zig: type declaration updated, catch block still valid
    - `zig build` passes clean (excluding TUI which still has disabled code)
  </done>
</task>

<task type="auto">
  <name>Task 3: Re-enable KnowledgePipeline in TUI + update Model struct</name>
  <files>src/tui/chat_tui_app.zig</files>
  <action>
    **Step A — Change Model struct field (line 328):**
    ```zig
    // BEFORE:
    pipeline: ?cognition_mod.KnowledgePipeline = null,
    // AFTER:
    pipeline: ?*cognition_mod.KnowledgePipeline = null,
    ```

    **Step B — Re-enable init block (lines 460-469):**
    Replace the commented-out block with:
    ```zig
    // KnowledgePipeline now heap-allocated — internal vault pointers are stable
    {
        const pl = cognition_mod.KnowledgePipeline.init(model.allocator, model.session_dir) catch null;
        if (pl) |p| {
            model.pipeline = p;
            model.pipeline_initialized = true;
        }
    }
    ```

    **Step C — Update ALL pipeline capture patterns in Model:**
    Every `if (self.pipeline) |*p|` must become `if (self.pipeline) |p|` because `pipeline` is now `?*T` — capturing `|*p|` would give `**T` (pointer-to-pointer).

    Lines to change (search `self.pipeline) |*p|`):
    - Line 628: `if (self.pipeline) |*p| p.deinit();` → `if (self.pipeline) |p| p.deinit();`
    - Line 968: `if (self.pipeline) |*p| {` → `if (self.pipeline) |p| {`
    - Line 1031: `if (self.pipeline) |*p| {` → `if (self.pipeline) |p| {`
    - Lines 2332, 2448, 2486, 2512, 2527: same pattern `|*p|` → `|p|`

    Inside each block, `p.scanProject(...)`, `p.pipeline_stats.files_indexed`, etc. — unchanged (auto-deref from `*KnowledgePipeline`).

    **Step D — Verify destroy() cleanup (line 628):**
    `p.deinit()` now calls `allocator.destroy(self)` internally — this frees the heap allocation. No extra free needed. The Model doesn't need to call `self.allocator.destroy(p)` separately because deinit handles it.

    **Do NOT:**
    - Store the pipeline by value (would re-create dangling pointer)
    - Leave disabled code as comments
    - Forget to update capture patterns (will compile but access wrong memory)
  </action>
  <verify>
    <automated>zig build --cache-dir /tmp/zigcache 2>&1 | tail -5</automated>
  </verify>
  <done>
    - Model.pipeline typed as `?*cognition_mod.KnowledgePipeline`
    - Pipeline initialized in Model.init() — no longer disabled
    - All `|*p|` captures changed to `|p|`
    - destroy() calls `p.deinit()` which frees heap memory
    - `zig build` passes clean
  </done>
</task>

</tasks>

<verification>
**Full build:**
```bash
zig build --cache-dir /tmp/zigcache
```

**Tests:**
```bash
zig build test --cache-dir /tmp/zigcache
```

**Runtime smoke test (manual):**
1. `./zig-out/bin/crushcode tui`
2. Header shows "ctx: N files indexed" (pipeline working)
3. Send a chat message — no crash, no assertion failure
4. Exit cleanly — no segfault on destroy
</verification>

<success_criteria>
- [ ] `KnowledgePipeline.init()` returns `!*KnowledgePipeline` (heap-allocated)
- [ ] Internal vault pointers (`ingester`, `querier`) point to stable heap addresses
- [ ] `deinit()` frees heap memory via `allocator.destroy(self)` after sub-component cleanup
- [ ] All `&pipeline` removed from AutopilotEngine.init() calls (6 in autopilot.zig, 5 in agent_loop_handler.zig)
- [ ] Model.pipeline is `?*cognition_mod.KnowledgePipeline` — all captures use `|p|` not `|*p|`
- [ ] TUI starts with pipeline enabled — no crash
- [ ] `zig build` passes clean
</success_criteria>

<output>
After completion, create `.planning/phases/kp-fix/kp-fix-01-SUMMARY.md`
</output>
