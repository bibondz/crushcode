# Harness Engineering Research Report

**Date:** 2026-04-26
**Sources:** future-agi, opencode, goose-latest, agentcc-gateway, crushcode current state

## Executive Summary

Harness Engineering for Crushcode means building production-grade infrastructure around AI model calls: structured tracing of every agent action, self-healing retry when tools fail, cost-aware model routing, guardrail enforcement, and observability dashboards. The reference repos (future-agi, opencode, goose) demonstrate mature implementations in Python/TypeScript/Rust. Crushcode already has ~40% of this infrastructure (usage tracking, pricing tables, model router, context compaction). The gap is in structured execution traces, guardrail pipelines, and real-time observability metrics.

---

## 1. Execution Traces

### What others do

**Future-AGI** — OpenTelemetry-native span model with full parent-child hierarchy:
- File: `future-agi/futureagi/tracer/models/observation_span.py`
- Each span has: `id, trace_id, parent_span_id, name, observation_type` (tool|chain|llm|retriever|embedding|agent|reranker|guardrail|evaluator), `start_time, end_time, latency_ms, input (JSON), output (JSON), model, model_parameters, prompt_tokens, completion_tokens, total_tokens, status, status_message, metadata, span_attributes, resource_attributes`
- Stored in PostgreSQL (relational queries) + ClickHouse (time-series analytics)
- Span types: tool, chain, llm, retriever, embedding, agent, reranker, unknown, guardrail, evaluator, conversation

**OpenCode** — Event-sourced session tracing:
- File: `opencode/packages/opencode/src/v2/session-event.ts`
- Event types: `prompt` (user input), `step.started` (LLM call begin with model info), `step.ended` (LLM call end with cost + token breakdown), `tool.called` (tool invocation with input), `tool.success` (tool result with output), `text.delta`, `reasoning.delta` (streaming chunks), `retry` (retry events with attempt count)
- Token tracking per event: `{ input, output, reasoning, cache: { read, write } }`
- Cost attached to every `step.ended` event

**Goose** — Layered tracing with Langfuse integration:
- Files: `goose-latest/crates/goose/src/tracing/observation_layer.rs`, `tracing/langfuse_layer.rs`
- Session model: `{ id, working_dir, name, total_tokens, input_tokens, output_tokens, conversation, provider_name, model_config }`
- Persisted to SQLite with full conversation history
- External observability via Langfuse export layer

### Crushcode gap

- `src/agent/loop.zig` has `ToolResult` with `{ call_id, output, success, duration_ms }` — minimal tracing
- No structured span model with parent-child hierarchy
- No trace ID propagation across tool calls
- No JSON serialization of trace data for export/analysis
- Session data not structured as trace events

### Implementation approach

```zig
// src/trace/span.zig
pub const SpanKind = enum { llm, tool, agent, retriever, chain, guardrail };

pub const Span = struct {
    id: []const u8,              // UUID
    trace_id: []const u8,        // groups all spans in one request chain
    parent_span_id: ?[]const u8, // null = root span
    name: []const u8,            // e.g. "chat.completions" or "tool.read_file"
    kind: SpanKind,
    start_time: i64,             // epoch ms
    end_time: ?i64,              // epoch ms
    latency_ms: ?u64,
    status: SpanStatus,          // .ok, .error, .timeout
    status_message: ?[]const u8,
    input_json: ?[]const u8,     // serialized request
    output_json: ?[]const u8,    // serialized response
    model: ?[]const u8,
    prompt_tokens: ?u32,
    completion_tokens: ?u32,
    total_tokens: ?u32,
    cost_usd: ?f64,
    metadata: std.json.ObjectMap, // arbitrary key-value
};

pub const Trace = struct {
    id: []const u8,
    session_id: []const u8,
    spans: std.ArrayList(Span),
    total_cost_usd: f64,
    total_duration_ms: u64,
};

// Thread-local active span stack for nesting
threadlocal var span_stack: std.ArrayList(*Span) = undefined;

pub fn startSpan(allocator, trace_id, parent_id, name, kind) !*Span;
pub fn endSpan(span: *Span, status, output) void;
pub fn currentTrace() ?*Trace;
pub fn exportJson(trace: *Trace) ![]const u8; // for file/logging output
```

Persist to `~/.crushcode/traces/{session_id}.jsonl` (one JSON per line, append-only).

---

## 2. Self-Healing Loops

### What others do

**Goose** — Two-tier retry system:
- Files: `goose-latest/crates/goose/src/agents/retry.rs`, `providers/retry.rs`
- Agent-level: `RetryManager` with `RetryResult` enum (Skipped, MaxAttemptsReached, SuccessChecksPassed, Retried). Includes repetition inspector to detect LLM looping.
- Provider-level: `RetryConfig { max_retries, initial_interval_ms, backoff_multiplier, max_interval_ms, transient_only }`. Exponential backoff with jitter. Separate auth refresh logic.
- On failure: agent can re-prompt LLM with error context to generate a corrected tool call.

**OpenCode** — Smart error classification:
- File: `opencode/packages/opencode/src/session/retry.ts`
- `retryable(error)` function classifies errors: 5xx always retryable, rate-limit patterns detected, context overflow never retryable
- `delay(attempt, error)` reads `retry-after-ms` and `retry-after` headers for provider-specified backoff
- Falls back to exponential: `min(INITIAL * BACKOFF^attempt, MAX_DELAY)`
- Special handling: "FreeUsageLimitError" → upsell message, "Overloaded" → specific backoff

**Future-AGI** — Context-aware retry policies:
- File: `future-agi/futureagi/simulate/temporal/retry_policies.py`
- Different policies per operation type: DB ops (3 attempts, 1s initial), Provider API (3 attempts, 5s initial), Eval activities (2 attempts, 30s initial)
- `non_retryable_error_types` list per policy (e.g., auth errors, validation errors never retry)
- Uses Temporal for durable execution with automatic retry

### Crushcode gap

- `src/ai/client.zig` has basic HTTP error handling but no structured retry with backoff
- No error classification (retryable vs permanent)
- No LLM-driven self-healing (feeding error back to model for corrected action)
- No repetition detection (agent looping on same failed action)

### Implementation approach

```zig
// src/retry/policy.zig
pub const RetryPolicy = struct {
    max_attempts: u32,
    initial_interval_ms: u64,
    max_interval_ms: u64,
    backoff_multiplier: f64,
    jitter: bool,
    non_retryable_errors: []const []const u8,

    pub fn forProvider() RetryPolicy {
        return .{ .max_attempts = 3, .initial_interval_ms = 1000, .max_interval_ms = 60000, .backoff_multiplier = 2.0, .jitter = true, .non_retryable_errors = &.{"auth", "validation"} };
    }

    pub fn forTool() RetryPolicy {
        return .{ .max_attempts = 2, .initial_interval_ms = 500, .max_interval_ms = 5000, .backoff_multiplier = 1.5, .jitter = true, .non_retryable_errors = &.{} };
    }

    pub fn delayMs(self: *const RetryPolicy, attempt: u32) u64 {
        var base = @floatToInt(u64, @floatFromInt(u64, self.initial_interval_ms) * std.math.pow(f64, self.backoff_multiplier, @floatFromInt(u32, attempt)));
        base = @min(base, self.max_interval_ms);
        if (self.jitter) base = base / 2 + std.crypto.random.intRangeLessThan(u64, 0, base / 2);
        return base;
    }

    pub fn isRetryable(self: *const RetryPolicy, err: anyerror) bool;
};

// src/retry/self_heal.zig
// Feed error context back to LLM for corrected action
pub fn selfHeal(allocator, client, failed_tool_call, error_msg, messages) !?ToolCall {
    // Append error to messages, ask LLM to generate corrected call
    const heal_prompt = try std.fmt.allocPrint(allocator,
        \\The tool call "{s}" failed with error: {s}
        \\Please generate a corrected tool call or respond with a different approach.
    , .{ failed_tool_call.name, error_msg });
    // ... send to LLM, parse corrected tool call
}
```

---

## 3. Cost-Aware Routing

### What others do

**Future-AGI AgentCC Gateway** — 15 routing strategies:
- File: `future-agi/futureagi/agentcc-gateway/internal/routing/`
- Strategies: weighted-round-robin, latency-aware (route to lowest P95), cost-optimized (cheapest meeting SLO), adaptive (online learning), complexity-based (simple→small model, complex→large), conditional (rule-based), provider-lock (compliance), race/hedged (parallel, first wins), mirror/shadow (compare outputs), model-fallback (cascade gpt-4o→sonnet→gemini), failover, circuit-breaker, retry, health-monitor
- Cost tracking: LiteLLM pricing DB with 2,373 models, per-request cost emission as Prometheus metric
- Budget enforcement: dollar cap, token cap, request cap per key/tenant
- Benchmarks: ~29k req/s, P99 ≤ 21ms with 3 guardrails on t3.xlarge

**OpenCode** — Per-model cost calculation:
- File: `opencode/packages/opencode/src/session/session.ts`
- `getUsage()` function: separates input/output/reasoning/cache tokens, handles provider-specific metadata (Anthropic cache, Bedrock, Vertex), uses Decimal precision for cost math
- Cost formula: `(input_tokens * input_price + output_tokens * output_price + cache_read * cache_read_price + cache_write * cache_write_price + reasoning_tokens * output_price) / 1_000_000`
- Supports experimental pricing tiers for large contexts (>200K tokens)

**Goose** — Token counting with caching:
- File: `goose-latest/crates/goose/src/token_counter.rs`
- `TokenCounter` with `CoreBPE` tokenizer and `DashMap` token cache
- `Usage { input_tokens, output_tokens, total_tokens }` per provider response
- Session-level accumulation with persistence

### Crushcode gap

- `src/agent/router.zig` already has `ModelRouter` with `TaskCategory` enum (data_collection, code_analysis, reasoning, file_operations, synthesis, search) → model mapping
- `src/usage/pricing.zig` has `PricingTable` with per-model pricing and cost estimation
- `src/usage/tracker.zig` has `SessionUsage` and `DailyUsage` with per-provider breakdown
- **Missing**: No latency-aware routing, no circuit breaker, no fallback chains, no budget enforcement (budget.zig exists but may be stub), no adaptive routing

### Implementation approach

```zig
// Extend src/agent/router.zig with:
pub const RoutingStrategy = enum {
    weighted_round_robin,
    cost_optimized,      // pick cheapest model that meets quality threshold
    latency_aware,       // pick fastest provider based on recent P95
    fallback_chain,      // gpt-4o → sonnet → gemini on error
    complexity_based,    // route by task complexity
};

pub const RoutingDecision = struct {
    provider: []const u8,
    model: []const u8,
    strategy_used: RoutingStrategy,
    estimated_cost: f64,
    estimated_latency_ms: u64,
};

pub const CircuitBreaker = struct {
    failure_count: std.atomic.Value(u32),
    last_failure_ms: std.atomic.Value(i64),
    threshold: u32,         // trip after N failures
    reset_timeout_ms: u64,  // half-open after this
    state: enum { closed, open, half_open },

    pub fn recordSuccess(self: *CircuitBreaker) void;
    pub fn recordFailure(self: *CircuitBreaker) void;
    pub fn allow(self: *CircuitBreaker) bool;
};

// Budget enforcement in src/usage/budget.zig
pub const Budget = struct {
    daily_limit_usd: f64,
    session_limit_usd: f64,
    spent_today_usd: f64,
    spent_session_usd: f64,

    pub fn check(self: *Budget, estimated_cost: f64) bool;
    pub fn record(self: *Budget, cost: f64) void;
};
```

---

## 4. Guardrails & Safety

### What others do

**Future-AGI** — 18 built-in guardrail scanners + 15 vendor adapters:
- Files: `future-agi/futureagi/agentcc-gateway/internal/guardrails/`
- Scanner types: PII (email, phone, SSN, credit card, IBAN, API key, etc.), prompt injection, secrets detection, hallucination (LLM-as-judge vs context), MCP security, language mismatch, cross-tenant leakage, content moderation (toxicity, hate, NSFW), blocklist, system-prompt tampering, custom policy (CEL expression), tool permissions, topic detection, JSON schema validation, external HTTP callout, webhook, Future-AGI platform evals
- Pipeline: guards run concurrently, short-circuit on first violation
- Policy model: `AgentccGuardrailPolicy { scope: global|project|key, mode: enforce|monitor, checks: JSON, priority: int }`
- PII entity categories: identity (SSN, name, DOB, passport), financial (credit card, bank account), contact (email, phone, address), technical (IP, AWS key, API key), health (medical record)

**OpenCode** — Pattern-based permission system:
- File: `opencode/packages/opencode/src/permission/index.ts`
- Actions: `allow`, `deny`, `ask` (user confirmation)
- Rules: `{ permission: string, pattern: string, action: Action }` with wildcard matching
- Three-tier merge: defaults → user config → agent-specific
- Errors: `RejectedError`, `CorrectedError` (with feedback), `DeniedError`
- Agent-specific permissions: build (full access), plan (read-only), explore (search only)

**Goose** — Multi-inspector tool safety:
- Files: `goose-latest/crates/goose/src/permission/permission_judge.rs`, `tool_inspection.rs`
- `PermissionCheckResult { approved, needs_approval, denied }` — three-bucket classification
- `ToolInspector` trait: `inspect(session_id, tool_requests, messages, mode) -> Vec<InspectionResult>`
- `InspectionAction`: Allow, Deny, RequireApproval(reason)
- LLM-based read-only detection for permission inference

### Crushcode gap

- `src/permission/` directory exists but only basic permission evaluation
- No guardrail pipeline (PII detection, injection detection, content moderation)
- No structured tool safety classification (approve/deny/ask)
- No policy-based configuration (global vs project vs session scope)
- `src/safety/checkpoint.zig` — only checkpoint-based safety, no real-time guards

### Implementation approach

```zig
// src/guardrail/pipeline.zig
pub const GuardrailAction = enum { allow, deny, redact, ask };

pub const GuardrailResult = struct {
    action: GuardrailAction,
    guardrail_name: []const u8,
    reason: ?[]const u8,
    redacted_content: ?[]const u8,
    confidence: f64,
};

pub const Guardrail = struct {
    name: []const u8,
    checkFn: *const fn (allocator, input: []const u8, config: GuardrailConfig) anyerror!GuardrailResult,
};

pub const GuardrailPipeline = struct {
    guardrails: std.ArrayList(Guardrail),
    mode: enum { enforce, monitor },

    pub fn check(self: *GuardrailPipeline, allocator, input: []const u8) !GuardrailResult;
};

// Built-in guardrails to implement (in src/guardrail/scanners/):
// 1. pii_scanner.zig    — regex-based PII detection (email, phone, SSN, credit card, API key)
// 2. injection.zig      — prompt injection pattern matching
// 3. secrets.zig        — API key/secret pattern detection
// 4. schema_validator.zig — JSON schema validation on tool outputs
// 5. length_limiter.zig — token length enforcement
// 6. content_filter.zig — basic content moderation (blocklist)
```

Start with PII + injection + secrets as the critical three (matches future-agi's "3 guardrails add +1.4ms P95" benchmark).

---

## 5. Observability

### What others do

**Future-AGI** — Full observability stack:
- Traces: OTLP ingest → PostgreSQL + ClickHouse, span graphs with parent-child visualization
- Metrics: Prometheus counters/histograms (`agentcc_request_duration_ms`, `agentcc_tokens_{input,output}_total`, `agentcc_cost_microdollars_total`, `agentcc_cache_{hits,misses}_total`)
- Dashboards: `Dashboard` + `DashboardWidget` model with `query_config` (JSON) + `chart_config` (JSON)
- Monitors: `UserAlertMonitor` with 9 metric types (error count, error rates, response time, token usage, eval metrics), threshold operators, critical/warning levels, notification channels (email, Slack)
- Response headers: `x-agentcc-provider`, `x-agentcc-cost`, `x-agentcc-cache`, `x-agentcc-latency`

**OpenCode** — Effect-based telemetry:
- Built-in tracing through Effect framework's telemetry layer
- Optional OpenTelemetry support
- Session events as structured logs with streaming deltas

**Goose** — Observation layer + Langfuse:
- `ObservationLayer` for internal tracing
- `LangfuseLayer` for external observability export
- Session metrics persisted to SQLite

### Crushcode gap

- No structured metrics emission (no Prometheus counters, no histogram)
- No dashboard/monitoring UI (TUI exists but no metrics display)
- No real-time alerting on cost/latency/error thresholds
- No trace export format (OTLP, JSON, etc.)
- `src/analytics/` directory exists but scope unknown

### Implementation approach

```zig
// src/metrics/collector.zig
pub const MetricType = enum { counter, gauge, histogram };

pub const Metric = struct {
    name: []const u8,
    metric_type: MetricType,
    value: f64,
    labels: std.StringHashMap([]const u8), // e.g. { "provider": "openai", "model": "gpt-4o" }
    timestamp: i64,
};

pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    metrics: std.ArrayList(Metric),

    pub fn counter(self: *MetricsCollector, name: []const u8, value: f64, labels: ...) void;
    pub fn histogram(self: *MetricsCollector, name: []const u8, value: f64, labels: ...) void;
    pub fn gauge(self: *MetricsCollector, name: []const u8, value: f64, labels: ...) void;

    // Output formats
    pub fn exportPrometheus(self: *MetricsCollector) ![]const u8;
    pub fn exportJson(self: *MetricsCollector) ![]const u8;
    pub fn writeToFile(self: *MetricsCollector, path: []const u8) !void;
};

// Built-in metrics to emit:
// crushcode_requests_total{provider, model, status}
// crushcode_request_duration_ms{provider, model}        — histogram
// crushcode_tokens_input_total{provider, model}
// crushcode_tokens_output_total{provider, model}
// crushcode_cost_microdollars_total{provider, model}
// crushcode_tool_calls_total{tool, status}
// crushcode_tool_duration_ms{tool}                      — histogram
// crushcode_cache_hits_total{type}
// crushcode_guardrail_blocks_total{guardrail}
```

Emit to `~/.crushcode/metrics/{date}.jsonl` + optional Prometheus exposition format on localhost.

---

## 6. Memory Management

### What others do

**Goose** — Automatic context compaction:
- File: `goose-latest/crates/goose/src/context_mgmt/mod.rs`
- `compact_messages(provider, session_id, conversation, manual_compact)` — uses LLM to summarize
- `check_if_compaction_needed(provider, conversation, threshold_override, session)` — threshold-based trigger
- Progressive tool response removal, summarization of older messages
- Preserves user messages and maintains conversation continuity

**OpenCode** — Token-aware truncation + cache optimization:
- File: `opencode/packages/opencode/src/session/session.ts`
- Context overflow detection with specific error handling
- Cache token separation (cache read vs write tokens tracked separately for Anthropic)
- `ContextOverflowError` — non-retryable, triggers compaction

**Future-AGI** — Span-based memory with eval feedback:
- Traces serve as memory for evaluation feedback loops
- Simulation runs generate synthetic memories for agent testing

### Crushcode gap

- `src/agent/memory.zig` — basic `Memory` struct with `max_messages` trim (FIFO eviction)
- `src/agent/compaction.zig` — `ContextCompactor` with 4 tiers (none, light, heavy, full), threshold at 80%, recent window of 10 messages, preserved topics, agent metadata preservation
- **Missing**: No LLM-based summarization (current compaction is token-estimation only), no progressive tool response truncation, no cache-aware prompt construction (Anthropic `cache_control`), no session-level memory persistence across restarts

### Implementation approach

```zig
// Extend src/agent/compaction.zig with LLM-based summarization
pub fn compactWithLLM(
    allocator: std.mem.Allocator,
    client: *AIClient,
    messages: []const ChatMessage,
    config: CompactionConfig,
) !CompactionResult {
    // 1. Split into recent_window (preserve) + older (summarize)
    // 2. Send older messages to LLM with summary prompt
    // 3. Build new message list: [system summary] + [recent messages]
    // 4. Return compacted messages + summary text
}

pub const CompactionConfig = struct {
    max_tokens: u64,
    compact_threshold: f64,     // 0.8 = compact at 80% of context
    recent_window: u32,          // preserve last N messages at full fidelity
    preserve_tool_outputs: bool, // keep tool results or summarize them
    max_summary_tokens: u32,    // limit summary length
};

// Cache-aware prompt construction for Anthropic
pub fn buildCacheAwarePrompt(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    messages: []const ChatMessage,
    provider: ProviderType,
) ![]const CacheMarkedMessage {
    // For Anthropic: mark system prompt as cacheable breakpoint
    // For OpenAI: no-op (automatic caching)
}
```

---

## 7. Tool Orchestration

### What others do

**OpenCode** — Schema-validated tool framework:
- File: `opencode/packages/opencode/src/tool/tool.ts`
- `Def<Parameters>` interface: `id, description, parameters (Schema), execute(args, ctx) -> Effect<ExecuteResult>`
- `Context`: sessionID, messageID, agent, abort signal, messages, permission ask, metadata output
- `ExecuteResult`: title, metadata, output, file attachments
- MCP integration: `packages/opencode/src/mcp/index.ts` — full MCP with HTTP/SSE/stdio transports, OAuth, tool/resource/prompt discovery

**Goose** — Inspection-based tool system:
- Files: `goose-latest/crates/goose/src/agents/extension_manager.rs`, `tool_inspection.rs`
- `ToolInspector` trait for pre/post execution hooks
- `ToolInspectionManager` chains multiple inspectors (security, permission, repetition)
- MCP extensions via `crates/goose-mcp/`
- Tool categorization: frontend (UI-facing) vs backend (internal)

**Future-AGI** — MCP + A2A + batch + realtime:
- Gateway supports MCP, A2A (agent-to-agent), Batch API, Realtime WebSocket
- Tool-call governance per virtual key: `allowed_tools` / `denied_tools`
- MCP security guardrail scanner

### Crushcode gap

- `src/mcp/` — MCP client and discovery exist
- `src/plugin/` — JSON-RPC 2.0 plugin system exists
- `src/hybrid_bridge.zig` — routes between built-in plugins and MCP servers
- `src/tools/` — tool implementations exist
- **Missing**: No tool schema validation on inputs/outputs, no tool inspection pipeline (pre/post hooks), no parallel tool execution, no tool governance (allowed/denied lists per session/profile)

### Implementation approach

```zig
// src/tool/registry.zig — enhanced tool registry
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,   // JSON schema string
    output_schema: ?[]const u8, // optional output validation
    danger_level: DangerLevel,  // .safe, .moderate, .dangerous
    requires_approval: bool,
};

pub const DangerLevel = enum { safe, moderate, dangerous };

pub const ToolExecutor = struct {
    schema: ToolSchema,
    executeFn: *const fn (allocator, args: []const u8) anyerror!ToolResult,

    pub fn execute(self: *ToolExecutor, allocator, args: []const u8, inspectors: []ToolInspector) !ToolResult {
        // 1. Validate input against schema
        // 2. Run pre-execution inspectors (permission, safety)
        // 3. Execute with timing
        // 4. Run post-execution inspectors (output validation)
        // 5. Return result with timing + metadata
    }
};

// Tool inspection pipeline
pub const ToolInspector = struct {
    name: []const u8,
    inspectFn: *const fn (allocator, call: *ToolCall, phase: InspectionPhase) anyerror!?InspectionAction,

    pub const InspectionPhase = enum { pre, post };
    pub const InspectionAction = enum { allow, deny, ask, modify };
};

// Parallel tool execution
pub fn executeToolsParallel(
    allocator: std.mem.Allocator,
    executors: []const *ToolExecutor,
    calls: []const ToolCall,
    max_concurrency: u32,
) ![]ToolResult;
```

---

## Priority Matrix

| Pattern | Impact | Effort | Priority |
|---------|--------|--------|----------|
| Execution Traces | HIGH — foundation for everything else | Medium — new module but well-defined | **P0** |
| Self-Healing Retry | HIGH — reliability foundation | Low — extend existing error handling | **P0** |
| Cost-Aware Routing | MEDIUM — cost savings grow with usage | Low — router.zig already exists | **P1** |
| Guardrails (PII + Injection) | HIGH — safety critical | Medium — regex-based scanners | **P1** |
| Observability Metrics | MEDIUM — operational visibility | Medium — new metrics module | **P1** |
| Memory/Compaction | MEDIUM — enables long sessions | Medium — LLM-based summarization | **P2** |
| Guardrails (Full Pipeline) | MEDIUM — extends P1 guards | High — policy engine + vendor adapters | **P2** |
| Tool Inspection Pipeline | LOW — nice-to-have safety layer | Medium — new interface + plumbing | **P3** |
| Circuit Breaker | LOW — for multi-provider reliability | Low — atomic counter + timer | **P3** |
| Parallel Tool Execution | LOW — performance optimization | Medium — thread pool in Zig | **P3** |

## Recommended Implementation Order

1. **Execution Traces** (`src/trace/`) — Build the Span/Trace data model first. Everything else (metrics, guardrails, retry) instruments into traces. Write JSONL to `~/.crushcode/traces/`. ~2-3 days.

2. **Self-Healing Retry** (`src/retry/`) — Extend `AIClient.sendChat()` with `RetryPolicy`, exponential backoff with jitter, error classification (retryable vs permanent), and LLM-based self-heal for tool failures. ~1-2 days.

3. **Cost-Aware Routing Enhancement** (`src/agent/router.zig`) — Add circuit breaker, fallback chains (model A → model B → model C), latency tracking per provider, budget enforcement. ~1-2 days.

4. **Guardrail Pipeline** (`src/guardrail/`) — Implement `GuardrailPipeline` with three critical scanners: PII (regex), prompt injection (pattern matching), secrets detection (API key patterns). Enforce/monitor modes. ~2-3 days.

5. **Observability Metrics** (`src/metrics/`) — `MetricsCollector` with counter/histogram/gauge types, Prometheus export format, JSONL file persistence. Emit standard metrics on every request/tool call. ~2 days.

6. **Memory Enhancement** (`src/agent/compaction.zig`) — Add LLM-based summarization to existing `ContextCompactor`, progressive tool response truncation, cache-aware prompt construction for Anthropic. ~2 days.

7. **Tool Inspection Pipeline** (`src/tool/`) — `ToolInspector` trait for pre/post hooks, danger level classification, parallel execution. ~2-3 days.

---

## Key Reference File Index

### Future-AGI
| Pattern | File |
|---------|------|
| Span model | `future-agi/futureagi/tracer/models/observation_span.py` |
| Trace model | `future-agi/futureagi/tracer/models/trace.py` |
| Cost tracking | `future-agi/futureagi/agentic_eval/core_evals/fi_utils/token_count_helper.py` |
| Guardrail policy | `future-agi/futureagi/agentcc/models/guardrail_policy.py` |
| Guardrail scanners (Go) | `future-agi/futureagi/agentcc-gateway/internal/guardrails/` |
| Routing policy | `future-agi/futureagi/agentcc/models/routing_policy.py` |
| Routing strategies (Go) | `future-agi/futureagi/agentcc-gateway/internal/routing/` |
| Dashboard model | `future-agi/futureagi/tracer/models/dashboard.py` |
| Monitor model | `future-agi/futureagi/tracer/models/monitor.py` |
| Retry policies | `future-agi/futureagi/simulate/temporal/retry_policies.py` |
| Eval metrics | `future-agi/futureagi/agentic_eval/core_evals/fi_metrics/metric.py` |
| Gateway benchmarks | `future-agi/futureagi/agentcc-gateway/README.md` |

### OpenCode
| Pattern | File |
|---------|------|
| Session events (traces) | `opencode/packages/opencode/src/v2/session-event.ts` |
| Retry logic | `opencode/packages/opencode/src/session/retry.ts` |
| Cost calculation | `opencode/packages/opencode/src/session/session.ts` |
| Permission system | `opencode/packages/opencode/src/permission/index.ts` |
| Tool framework | `opencode/packages/opencode/src/tool/tool.ts` |
| MCP integration | `opencode/packages/opencode/src/mcp/index.ts` |
| Agent architecture | `opencode/packages/opencode/src/agent/agent.ts` |
| LLM session | `opencode/packages/opencode/src/session/llm.ts` |

### Goose
| Pattern | File |
|---------|------|
| Agent loop | `goose-latest/crates/goose/src/agents/agent.rs` |
| Tool execution | `goose-latest/crates/goose/src/agents/tool_execution.rs` |
| Agent retry | `goose-latest/crates/goose/src/agents/retry.rs` |
| Provider retry | `goose-latest/crates/goose/src/providers/retry.rs` |
| Token counter | `goose-latest/crates/goose/src/token_counter.rs` |
| Usage estimator | `goose-latest/crates/goose/src/providers/usage_estimator.rs` |
| Provider trait | `goose-latest/crates/goose/src/providers/base.rs` |
| Permission judge | `goose-latest/crates/goose/src/permission/permission_judge.rs` |
| Tool inspection | `goose-latest/crates/goose/src/tool_inspection.rs` |
| Context management | `goose-latest/crates/goose/src/context_mgmt/mod.rs` |
| Tracing layer | `goose-latest/crates/goose/src/tracing/observation_layer.rs` |
| Session manager | `goose-latest/crates/goose/src/session/session_manager.rs` |

### Crushcode (current state)
| Pattern | File | Status |
|---------|------|--------|
| Usage tracking | `src/usage/tracker.zig` | **Exists** — per-session + daily |
| Pricing tables | `src/usage/pricing.zig` | **Exists** — 22 providers priced |
| Model router | `src/agent/router.zig` | **Exists** — 6 task categories |
| Agent loop | `src/agent/loop.zig` | **Exists** — tool call + result |
| Memory | `src/agent/memory.zig` | **Exists** — FIFO with max_messages |
| Compaction | `src/agent/compaction.zig` | **Exists** — 4 tiers, 80% threshold |
| Permission | `src/permission/` | **Partial** — basic evaluation |
| Safety | `src/safety/checkpoint.zig` | **Partial** — checkpoint only |
| MCP client | `src/mcp/` | **Exists** — full MCP support |
| Plugin system | `src/plugin/` | **Exists** — JSON-RPC 2.0 |

---

## Supplementary Findings: Tier 2 Repos

### OpenHarness (`/mnt/d/crushcode-references/OpenHarness/`)
- **Stream-based event tracing**: `StreamEvent` types (AssistantTextDelta, ToolExecutionStarted, ToolExecutionCompleted, ErrorEvent, StatusEvent) with usage tracking baked into the event stream
- **Reactive compaction**: When `_is_prompt_too_long_error` fires, automatically triggers reactive compaction → retry, separate from proactive compaction
- **Tool-aware query loop**: `QueryContext` struct carries api_client, tool_registry, permission_checker, cwd, model, max_turns (default 200)
- **Task-focused memory**: `_task_focus_state` tracks goal, recent_goals, active_artifacts, verified_state, next_step per tool invocation
- Key file: `OpenHarness/src/openharness/engine/query.py`

### Codex CLI (`/mnt/d/crushcode-references/codex/`)
- **Type-safe retry in Rust**: `RetryPolicy { max_attempts, base_delay, retry_on: RetryOn { retry_429, retry_5xx, retry_transport } }` with exponential backoff `2^(attempt-1)` and 0.9-1.1 jitter
- **Sandbox modes**: `enum SandboxMode { ReadOnly, WorkspaceWrite, DangerFullAccess }` — platform-specific (macOS Seatbelt, Linux Landlock)
- **Request telemetry**: `RequestTelemetry { request_id, start_time, end_time, tokens_used, cost_estimate }`
- Key file: `codex/codex-rs/codex-client/src/retry.rs`

### Deep Agents (`/mnt/d/crushcode-references/deepagents-deepagents-0.5.3/`)
- **AGENTS.md memory middleware**: `MemoryMiddleware` loads hierarchical AGENTS.md files as system prompt context
- **Ordered middleware stack**: TodoList → Skills → Filesystem → SubAgent → Summarization → PatchToolCalls → ToolExclusion → PromptCaching → Memory → Permission (always last)
- **LangGraph checkpointing**: `checkpointer + store + cache` three-layer persistence with `recursion_limit: 9999`
- Key file: `deepagents/libs/deepagents/deepagents/middleware/memory.py`

### Oh My OpenAgent (`/mnt/d/crushcode-references/oh-my-openagent/`)
- **52-hook 5-tier system**: 24 session hooks + 14 tool-guard hooks + 5 transform hooks + 7 continuation hooks + 2 skill hooks
- **Fallback state machine**: `FallbackState { originalModel, currentModel, fallbackIndex, failedModels: Map<string, timestamp>, attemptCount }` with 60s cooldown per failed model
- **Hash-anchored edit validation**: Every line tagged with content hash on read; edits rejected if hash mismatched (prevents stale-line errors)
- **Checkpoint/restore after compaction**: `CompactionAgentConfigCheckpoint { agent, model, tools }` captured pre-compaction, restored post-compaction with validation
- Key file: `oh-my-openagent/src/hooks/runtime-fallback/message-update-handler.ts`

### Cross-Repo Validation

The same core patterns appeared across all repos, confirming their importance:

| Pattern | Tier 1 Confirmation | Tier 2 Confirmation |
|---------|-------------------|-------------------|
| Structured tracing | future-agi (OTel spans), opencode (session events) | OpenHarness (StreamEvent), Codex (RequestTelemetry) |
| Retry with backoff | goose (2-tier retry), opencode (smart classification) | Codex (typed Rust policy), oh-my-openagent (fallback state machine) |
| Context compaction | goose (LLM-based), crushcode (4-tier) | OpenHarness (reactive compaction), oh-my-openagent (checkpoint/restore) |
| Permission system | opencode (pattern rules), goose (inspector trait) | OpenHarness (PermissionChecker), Codex (SandboxMode) |
| Cost tracking | future-agi (2373 models), opencode (Decimal precision) | OpenHarness (UsageSnapshot), Codex (cost_estimate) |
| Tool registry | goose (MCP extensions), opencode (schema tools) | OpenHarness (ToolRegistry), Deep Agents (middleware stack) |
