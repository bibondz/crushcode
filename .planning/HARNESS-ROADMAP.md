# Harness Engineering Implementation Roadmap
**Version:** 1.0
**Date:** 2026-04-26
**Target:** Crushcode v1.4.0–v2.0.0

## Overview

Production-grade infrastructure around AI model calls: structured tracing, self-healing retry, cost-aware routing, guardrail enforcement, observability, memory enhancement, and tool inspection. Crushcode has ~40% of this already (usage tracking, pricing, model router, compaction, permissions). This roadmap closes the remaining 60%.

## Architecture Overview

```
Module dependency graph:

  ┌──────────┐     ┌───────────┐     ┌──────────┐
  │  Trace    │◄────│  Retry     │     │ Metrics  │
  │  (P0)     │     │  (P0)      │     │ (P1)     │
  └────┬─────┘     └─────┬─────┘     └────┬─────┘
       │                 │                 │
       ▼                 ▼                 ▼
  ┌──────────┐     ┌───────────┐     ┌──────────┐
  │  Router   │     │  Client    │     │ Guardrail│
  │  (extend) │     │  (extend)  │     │ (P1)     │
  └──────────┘     └───────────┘     └──────────┘
       │                 │
       ▼                 ▼
  ┌──────────┐     ┌───────────┐     ┌──────────┐
  │  Memory   │     │  Loop      │     │ Tool     │
  │  (P2)     │     │  (extend)  │     │ Insp.(P3)│
  └──────────┘     └───────────┘     └──────────┘
```

**Data flow:** Every request enters `AIClient.sendChat*()` → trace span starts → guardrail checks input → retry policy wraps the HTTP call → on success: emit metrics, record trace, update budget → on failure: classify error, retry or self-heal.

---

## Phase 1: Execution Traces (P0)

### Goal
Structured span-based tracing for every LLM call and tool execution. Foundation for metrics, guardrails, and debug.

### Files to Create
| File | Purpose |
|------|---------|
| `src/trace/span.zig` | Span, Trace, SpanKind, SpanStatus types |
| `src/trace/writer.zig` | JSONL append-only writer to `~/.crushcode/traces/` |
| `src/trace/context.zig` | Thread-local span stack for nesting |

### Files to Modify
| File | Change |
|------|--------|
| `src/agent/loop.zig` | Wrap `executeTool()` and `run()` with span start/end |
| `src/ai/client.zig` | Wrap `sendChatWithOptions()` and `sendChatStreaming()` with LLM span |
| `build.zig` | Add `trace_mod`, `trace_writer_mod`, `trace_context_mod` modules |

### Data Model

```zig
// src/trace/span.zig
pub const SpanKind = enum { llm, tool, agent, chain, guardrail };

pub const SpanStatus = enum { ok, error, timeout };

pub const Span = struct {
    id: [16]u8,                    // random bytes, hex-encoded for display
    trace_id: [16]u8,              // groups all spans in one request chain
    parent_span_id: ?[16]u8,       // null = root span
    name: []const u8,              // "chat.completions" or "tool.read_file"
    kind: SpanKind,
    start_time_ns: i64,            // std.time.nanoTimestamp()
    end_time_ns: ?i64,
    latency_ms: ?u64,
    status: SpanStatus,
    status_message: ?[]const u8,
    input_json: ?[]const u8,       // serialized request (truncated to 4KB)
    output_json: ?[]const u8,      // serialized response (truncated to 4KB)
    model: ?[]const u8,
    provider: ?[]const u8,
    prompt_tokens: ?u32,
    completion_tokens: ?u32,
    total_tokens: ?u32,
    cost_usd: ?f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator, trace_id, parent_id, name, kind) !*Span;
    pub fn end(self: *Span, status: SpanStatus, output: ?[]const u8) void;
    pub fn deinit(self: *Span) void;
};

pub const Trace = struct {
    id: [16]u8,
    session_id: []const u8,
    spans: std.ArrayList(*Span),
    total_cost_usd: f64,
    total_duration_ms: u64,
    start_time_ns: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator, session_id) !*Trace;
    pub fn rootSpan(self: *Trace, name: []const u8, kind: SpanKind) !*Span;
    pub fn childSpan(self: *Trace, parent: *Span, name: []const u8, kind: SpanKind) !*Span;
    pub fn finish(self: *Trace) void;
    pub fn deinit(self: *Trace) void;
};
```

```zig
// src/trace/context.zig — thread-local active trace
threadlocal var active_trace: ?*Trace = null;
threadlocal var active_span: ?*Span = null;

pub fn setCurrentTrace(trace: ?*Trace) void;
pub fn currentTrace() ?*Trace;
pub fn currentSpan() ?*Span;
pub fn setCurrentSpan(span: ?*Span) void;
```

### JSONL Persistence Format
Path: `~/.crushcode/traces/{session_id}.jsonl`
```json
{"ts":"2026-04-26T10:30:00Z","trace_id":"a1b2c3","span_id":"d4e5f6","parent":null,"name":"chat.completions","kind":"llm","status":"ok","latency_ms":2340,"model":"gpt-4o","tokens":{"prompt":1500,"completion":800,"total":2300},"cost_usd":0.0175}
{"ts":"2026-04-26T10:30:02Z","trace_id":"a1b2c3","span_id":"g7h8i9","parent":"d4e5f6","name":"tool.read_file","kind":"tool","status":"ok","latency_ms":12,"input":"src/main.zig","output":"<truncated>"}
```

### Integration Points
1. **`AgentLoop.run()`** — Create trace at start, root span per iteration, child span per tool call
2. **`AIClient.sendChatWithOptions()`** — Wrap HTTP call in LLM span, capture tokens/cost
3. **`AIClient.sendChatStreaming()`** — Same, with stream start/end span markers

### Commands to Add
- `/trace` — Show current session's trace summary (span count, total cost, total time)
- `/trace <id>` — Show detailed trace with span tree
- `/timeline` — Show chronological span list with durations

### Tests
- Span init/end lifecycle, latency calculation
- Trace with nested spans (root → child → grandchild)
- JSONL serialization round-trip
- Thread-local context push/pop

### Estimated Effort
2–3 days

### Success Criteria
- Every `sendChat*()` call produces an LLM span with tokens + cost
- Every tool execution produces a tool span
- Traces persist to JSONL and survive process restart
- `/trace` command displays structured output

---

## Phase 2: Self-Healing Retry (P0)

### Goal
Structured retry with exponential backoff, error classification, and LLM-driven self-healing for tool failures.

### Files to Create
| File | Purpose |
|------|---------|
| `src/retry/policy.zig` | RetryPolicy, ErrorClassifier |
| `src/retry/self_heal.zig` | LLM-based self-heal for failed tool calls |

### Files to Modify
| File | Change |
|------|--------|
| `src/ai/client.zig` | Replace inline retry in `sendChatWithOptions()` with `RetryPolicy` |
| `src/ai/error_handler.zig` | Add `ErrorClassifier` with retryable/permanent classification |
| `src/agent/loop.zig` | Add self-heal loop in `executeTool()` on failure |
| `build.zig` | Add `retry_policy_mod`, `retry_self_heal_mod` |

### Data Model

```zig
// src/retry/policy.zig
pub const ErrorClass = enum {
    retryable_transient,    // 429, 500, 502, 503, network timeout
    retryable_rate_limit,   // 429 with retry-after header
    non_retryable_auth,     // 401, 403
    non_retryable_input,    // 400, context overflow
    non_retryable_not_found, // 404
    unknown,
};

pub const RetryPolicy = struct {
    max_attempts: u32,
    initial_interval_ms: u64,
    max_interval_ms: u64,
    backoff_multiplier: f64,
    jitter: bool,

    pub fn forProvider() RetryPolicy {
        return .{ .max_attempts = 3, .initial_interval_ms = 1000, .max_interval_ms = 60000, .backoff_multiplier = 2.0, .jitter = true };
    }
    pub fn forTool() RetryPolicy {
        return .{ .max_attempts = 2, .initial_interval_ms = 500, .max_interval_ms = 5000, .backoff_multiplier = 1.5, .jitter = true };
    }
    pub fn delayMs(self: *const RetryPolicy, attempt: u32) u64;
    pub fn classifyError(http_status: u16, body: []const u8) ErrorClass;
    pub fn isRetryable(class: ErrorClass) bool {
        return class == .retryable_transient or class == .retryable_rate_limit;
    }
};

pub const RetryResult = enum { success, max_attempts_reached, non_retryable_error, self_heal_success };

pub const RetryState = struct {
    policy: RetryPolicy,
    current_attempt: u32,
    last_error: ?ErrorClass,
    total_wait_ms: u64,

    pub fn init(policy: RetryPolicy) RetryState;
    pub fn nextAttempt(self: *RetryState) ?u64;  // returns delay_ms or null if exhausted
    pub fn recordError(self: *RetryState, class: ErrorClass) void;
    pub fn recordSuccess(self: *RetryState) void;
};
```

### Self-Heal Prompt Template
```zig
// src/retry/self_heal.zig
pub const SELF_HEAL_PROMPT =
    \\The tool call "{s}" failed with error: {s}
    \\
    \\Tool arguments were: {s}
    \\
    \\Generate a corrected tool call or explain why the task cannot be completed.
    \\Respond with a JSON tool call in the same format, or explain the alternative approach.
;
```

### Integration Points
1. **`AIClient.sendChatWithOptions()`** — Replace inline `while (attempt < retry_config.max_attempts)` with `RetryState`. Use `ErrorClassifier` instead of `isRetryableError()`. Honor `retry-after` headers.
2. **`AgentLoop.executeTool()`** — On tool failure after max retries, call `selfHeal()` which feeds error back to LLM for corrected action. Track repetition (same tool+args failing twice = break loop).

### Retry Policy Per Provider
| Provider | max_attempts | initial_ms | max_ms | multiplier |
|----------|-------------|-----------|--------|------------|
| OpenAI | 3 | 1000 | 60000 | 2.0 |
| Anthropic | 3 | 1000 | 60000 | 2.0 |
| Ollama (local) | 2 | 500 | 5000 | 1.5 |
| OpenRouter | 3 | 2000 | 60000 | 2.0 |

### Tests
- RetryPolicy delay calculation with jitter
- ErrorClass classification for all HTTP status codes
- RetryState attempt exhaustion
- Self-heal prompt construction
- Integration: mock executor that fails then succeeds

### Estimated Effort
1–2 days

### Success Criteria
- 5xx and 429 errors retry with backoff + jitter
- 401/403/400 errors never retry
- `retry-after` header honored when present
- Tool failures trigger LLM self-heal attempt (configurable)
- Repetition detection breaks infinite tool retry loops

---

## Phase 3: Cost-Aware Routing Enhancement (P1)

### Goal
Add circuit breaker, fallback chains, latency-aware routing, and budget enforcement to existing `ModelRouter`.

### Files to Create
| File | Purpose |
|------|---------|
| `src/agent/circuit_breaker.zig` | CircuitBreaker per provider |

### Files to Modify
| File | Change |
|------|---------|
| `src/agent/router.zig` | Add `RoutingStrategy`, `FallbackChain`, latency tracking |
| `src/usage/budget.zig` | Add `checkBeforeRequest()` with estimated cost gate |
| `build.zig` | Add `circuit_breaker_mod` |

### Data Model

```zig
// src/agent/circuit_breaker.zig
pub const CircuitState = enum { closed, open, half_open };

pub const CircuitBreaker = struct {
    failure_count: u32,
    success_count: u32,
    last_failure_ns: i64,
    threshold: u32,            // trip after N consecutive failures
    reset_timeout_ns: u64,     // try half-open after this
    state: CircuitState,
    provider_name: []const u8,

    pub fn init(provider_name: []const u8, threshold: u32, reset_timeout_ns: u64) CircuitBreaker;
    pub fn allow(self: *CircuitBreaker) bool;    // false if open
    pub fn recordSuccess(self: *CircuitBreaker) void;
    pub fn recordFailure(self: *CircuitBreaker) void;
};
```

```zig
// Extensions to src/agent/router.zig
pub const RoutingStrategy = enum {
    default,           // current category→model mapping
    cost_optimized,    // pick cheapest model meeting quality threshold
    latency_aware,     // pick provider with lowest recent P95
    fallback_chain,    // gpt-4o → sonnet → gemini on circuit open
};

pub const FallbackChain = struct {
    models: []const []const u8,      // ordered list, e.g. ["gpt-4o", "sonnet", "gemini-flash"]
    circuit_breakers: std.StringHashMap(*CircuitBreaker),

    pub fn next(self: *FallbackChain) ?[]const u8;  // returns first model with closed circuit
};

pub const ProviderLatency = struct {
    provider: []const u8,
    model: []const u8,
    p50_ms: u64,
    p95_ms: u64,
    sample_count: u32,
    last_updated_ns: i64,
};

// New field on ModelRouter:
// latency_history: std.StringHashMap(ProviderLatency),
// circuit_breakers: std.StringHashMap(CircuitBreaker),
// fallback_chains: std.StringHashMap(FallbackChain),
```

```zig
// Extension to src/usage/budget.zig
pub fn checkBeforeRequest(self: *BudgetManager, estimated_cost_usd: f64) !void {
    if (self.isOverBudget()) return error.OverBudget;
    const projected = self.session_spent + estimated_cost_usd;
    if (self.config.per_session_limit_usd > 0 and projected > self.config.per_session_limit_usd)
        return error.OverBudget;
}
```

### Integration Points
1. **`ModelRouter.routeForTask()`** → extend to accept `RoutingStrategy` parameter, check circuit breakers before returning model
2. **`AIClient.sendChatWithOptions()`** → on failure, call `circuit_breaker.recordFailure()`, router tries fallback model
3. **`BudgetManager.checkBeforeRequest()`** → call before every LLM request, return error if over budget

### Tests
- CircuitBreaker state transitions: closed → open → half_open → closed
- FallbackChain skips open circuits
- Budget enforcement blocks requests over limit
- Latency tracking updates P95 on each request

### Estimated Effort
1–2 days

### Success Criteria
- Circuit breaker trips after N failures, recovers after timeout
- Fallback chain provides alternative models on provider failure
- Budget check blocks requests when over limit
- Latency tracking influences routing decisions

---

## Phase 4: Guardrail Pipeline (P1)

### Goal
Pre/post-request guardrail pipeline with PII, injection, and secrets detection.

### Files to Create
| File | Purpose |
|------|---------|
| `src/guardrail/pipeline.zig` | GuardrailPipeline, GuardrailResult, execution flow |
| `src/guardrail/pii_scanner.zig` | Regex-based PII detection (email, phone, SSN, CC, API key) |
| `src/guardrail/injection.zig` | Prompt injection pattern matching |
| `src/guardrail/secrets.zig` | API key/secret/token pattern detection |

### Data Model

```zig
// src/guardrail/pipeline.zig
pub const GuardrailAction = enum { allow, deny, redact, ask };

pub const GuardrailResult = struct {
    action: GuardrailAction,
    scanner_name: []const u8,
    reason: ?[]const u8,
    redacted_content: ?[]const u8,
    confidence: f64,
    detections: []const Detection,

    pub const Detection = struct {
        entity_type: []const u8,    // "email", "ssn", "api_key", "injection"
        value: []const u8,          // the matched text (or redacted)
        start_pos: usize,
        end_pos: usize,
    };
};

pub const GuardrailConfig = struct {
    mode: enum { enforce, monitor },  // enforce = block on deny, monitor = log only
    max_input_bytes: usize,           // reject inputs over this size
};

pub const GuardrailFn = *const fn (allocator: std.mem.Allocator, input: []const u8, config: *const GuardrailConfig) anyerror!GuardrailResult;

pub const Guardrail = struct {
    name: []const u8,
    check: GuardrailFn,
    priority: u32,  // lower = runs first
};

pub const GuardrailPipeline = struct {
    allocator: std.mem.Allocator,
    guardrails: std.ArrayList(Guardrail),
    config: GuardrailConfig,

    pub fn init(allocator, config) GuardrailPipeline;
    pub fn addGuardrail(self: *GuardrailPipeline, guardrail: Guardrail) !void;
    pub fn check(self: *GuardrailPipeline, input: []const u8) !GuardrailResult;
    pub fn deinit(self: *GuardrailPipeline) void;
};
```

```zig
// src/guardrail/pii_scanner.zig — pattern definitions
pub const PII_PATTERNS = [_]struct { name: []const u8, pattern: []const u8 }{
    .{ .name = "email", .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}" },
    .{ .name = "phone_us", .pattern = "\\+?1?[\\s.-]?\\(?\\d{3}\\)?[\\s.-]?\\d{3}[\\s.-]?\\d{4}" },
    .{ .name = "ssn", .pattern = "\\d{3}-\\d{2}-\\d{4}" },
    .{ .name = "credit_card", .pattern = "\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4}" },
    .{ .name = "aws_key", .pattern = "AKIA[0-9A-Z]{16}" },
    .{ .name = "generic_api_key", .pattern = "(?i)(api[_-]?key|secret[_-]?key|token)[\"']?\\s*[:=]\\s*[\"']?[a-zA-Z0-9]{20,}" },
};

pub fn scan(allocator: std.mem.Allocator, input: []const u8, config: *const GuardrailConfig) !GuardrailResult;
```

### Pipeline Execution Flow
```
Input → [PII Scanner] → [Injection Scanner] → [Secrets Scanner]
                ↓                ↓                    ↓
          GuardrailResult   GuardrailResult     GuardrailResult
                ↓                ↓                    ↓
            ───────────── aggregate ──────────────────
                              ↓
                    Final GuardrailResult
                    (highest severity wins)
```
- Short-circuit on first `deny` in enforce mode
- All scanners run in monitor mode (log warnings)

### Integration Points
1. **`AIClient.sendChat*()`** — Check guardrail pipeline on user input before sending to LLM
2. **`AgentLoop.executeTool()`** — Check guardrail on tool arguments
3. **Trace system** — Record guardrail results as guardrail spans

### Tests
- PII scanner detects email, phone, SSN, credit card in sample text
- Injection scanner detects common injection patterns ("ignore previous", "system prompt")
- Secrets scanner detects AWS keys, generic API keys
- Pipeline short-circuits on deny in enforce mode
- Pipeline runs all scanners in monitor mode
- Redaction replaces detected values with `[REDACTED]`

### Estimated Effort
2–3 days

### Success Criteria
- All three scanners detect their target patterns with >95% recall
- False positive rate <5% on normal code text
- Pipeline adds <2ms P95 latency (regex-only, no LLM calls)
- Guardrail results appear in trace spans

---

## Phase 5: Observability Metrics (P1)

### Goal
Metrics collection with counter/gauge/histogram types, JSONL persistence, Prometheus exposition format.

### Files to Create
| File | Purpose |
|------|---------|
| `src/metrics/collector.zig` | MetricsCollector, Metric, MetricType |
| `src/metrics/registry.zig` | Named metric registration, built-in metric definitions |

### Data Model

```zig
// src/metrics/collector.zig
pub const MetricType = enum { counter, gauge, histogram };

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const Metric = struct {
    name: []const u8,
    metric_type: MetricType,
    value: f64,
    labels: []const Label,
    timestamp_ns: i64,
};

pub const Histogram = struct {
    name: []const u8,
    buckets: []f64,           // e.g. [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
    counts: []u32,            // count per bucket
    sum: f64,
    count: u32,
    labels: []const Label,

    pub fn observe(self: *Histogram, value: f64) void;
};

pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(f64),
    gauges: std.StringHashMap(f64),
    histograms: std.StringHashMap(Histogram),
    metric_log: std.ArrayList(Metric),

    pub fn init(allocator) MetricsCollector;
    pub fn increment(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) void;
    pub fn gauge(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) void;
    pub fn observe(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) void;

    // Export
    pub fn exportPrometheus(self: *MetricsCollector, writer: anytype) !void;
    pub fn exportJsonl(self: *MetricsCollector, writer: anytype) !void;
    pub fn writeToFile(self: *MetricsCollector, path: []const u8) !void;
    pub fn deinit(self: *MetricsCollector) void;
};
```

### Built-in Metrics
| Name | Type | Labels | Description |
|------|------|--------|-------------|
| `crushcode_requests_total` | counter | provider, model, status | Total LLM requests |
| `crushcode_request_duration_ms` | histogram | provider, model | Request latency |
| `crushcode_tokens_input_total` | counter | provider, model | Input tokens consumed |
| `crushcode_tokens_output_total` | counter | provider, model | Output tokens generated |
| `crushcode_cost_microdollars_total` | counter | provider, model | Cumulative cost |
| `crushcode_tool_calls_total` | counter | tool, status | Tool invocations |
| `crushcode_tool_duration_ms` | histogram | tool | Tool execution time |
| `crushcode_guardrail_blocks_total` | counter | guardrail, action | Guardrail interventions |
| `crushcode_retry_attempts_total` | counter | provider, error_class | Retry attempts |
| `crushcode_cache_hits_total` | counter | type | Prompt cache hits |

### Export Formats
**JSONL** — `~/.crushcode/metrics/{YYYY-MM-DD}.jsonl`:
```json
{"ts":1714123800,"name":"crushcode_requests_total","type":"counter","value":1,"labels":{"provider":"openai","model":"gpt-4o","status":"ok"}}
{"ts":1714123800,"name":"crushcode_request_duration_ms","type":"histogram","value":2340,"labels":{"provider":"openai","model":"gpt-4o"}}
```

**Prometheus** — `GET localhost:9898/metrics`:
```
crushcode_requests_total{provider="openai",model="gpt-4o",status="ok"} 42
crushcode_request_duration_ms_bucket{provider="openai",model="gpt-4o",le="100"} 5
crushcode_request_duration_ms_bucket{provider="openai",model="gpt-4o",le="500"} 28
crushcode_request_duration_ms_sum 42000
crushcode_request_duration_ms_count 42
```

### TUI Integration
- `/metrics` command — Show summary: total requests, cost, avg latency, token usage
- TUI sidebar — Live gauge showing session cost and request count

### Tests
- Counter increment and accumulation
- Histogram bucket assignment and sum
- Prometheus format output validation
- JSONL round-trip
- Concurrent metric recording

### Estimated Effort
2 days

### Success Criteria
- Every LLM request emits request_total + duration + tokens + cost metrics
- Every tool call emits tool_calls_total + duration metrics
- `/metrics` shows readable summary
- JSONL files append correctly across sessions

---

## Phase 6: Memory Enhancement (P2)

### Goal
LLM-based summarization for context compaction, cache-aware prompt construction for Anthropic, progressive tool response truncation.

### Files to Modify
| File | Change |
|------|--------|
| `src/agent/compaction.zig` | Add `compactWithLLM()`, progressive truncation |
| `src/ai/client.zig` | Add cache breakpoint markers for Anthropic requests |

### Data Model Extensions

```zig
// Extensions to src/agent/compaction.zig
pub const CompactionConfig = struct {
    max_tokens: u64,
    compact_threshold: f64,       // 0.8
    recent_window: u32,           // 10
    preserve_tool_outputs: bool,  // false = summarize tool results
    max_summary_tokens: u32,     // 512
    max_tool_output_chars: u32,  // 2000 — truncate tool outputs beyond this
    llm_compaction_model: []const u8, // "haiku" — use cheap model for summarization
};

// New method on ContextCompactor:
pub fn compactWithLLM(
    self: *ContextCompactor,
    client: *AIClient,
    messages: []const CompactMessage,
    config: CompactionConfig,
) !CompactResult {
    // 1. Split into recent_window (preserve) + older (summarize)
    // 2. Use existing buildSummarizationPrompt() to create prompt
    // 3. Send to LLM via client.sendChat(summary_prompt) using cheap model
    // 4. Build new message list: [system summary] + [recent messages]
    // 5. Return CompactResult with summary from LLM
}

pub fn truncateToolOutputs(
    self: *ContextCompactor,
    messages: []const CompactMessage,
    max_chars: u32,
) []CompactMessage {
    // For tool-role messages, truncate content to max_chars + "\n... (truncated)"
}
```

```zig
// Cache-aware prompt construction in src/ai/client.zig
// For Anthropic: inject cache_control breakpoints
pub fn buildCacheAwareMessages(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    messages: []const ChatMessage,
    provider_name: []const u8,
) ![]CacheMarkedMessage {
    // Only active for anthropic/bedrock providers
    // Mark system prompt as cacheable breakpoint
    // Mark last 2 tool results as cacheable
    // Return messages with cache_control fields injected
}

pub const CacheMarkedMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_calls: ?[]const ToolCallInfo,
    cache_control: ?CacheControl,
};

pub const CacheControl = struct {
    type: []const u8, // "ephemeral"
};
```

### Integration Points
1. **`AgentLoop.run()`** — After each iteration, check `ContextCompactor.needsCompaction()`. If yes, call `compactWithLLM()` instead of heuristic-only `compact()`.
2. **`AIClient.sendChatStreaming()`** — Use `buildCacheAwareMessages()` for Anthropic providers to enable prompt caching.
3. **`ContextCompactor.compactHeuristic()`** — Add `truncateToolOutputs()` step before summary generation.

### Tests
- LLM-based compaction produces valid summary from mock messages
- Tool output truncation respects max_chars limit
- Cache-aware message construction adds breakpoints only for Anthropic
- Compaction preserves recent_window messages unchanged
- Progressive truncation: heavy tier truncates more aggressively than light

### Estimated Effort
2 days

### Success Criteria
- Long sessions (50+ messages) auto-compact via LLM summarization
- Anthropic requests include cache breakpoints, reducing input token costs
- Tool outputs truncated progressively (longer = more truncation)
- Compaction preserves all messages in recent_window at full fidelity

---

## Phase 7: Tool Inspection Pipeline (P3)

### Goal
Pre/post-execution hooks for tools with danger classification and parallel execution support.

### Files to Create
| File | Purpose |
|------|---------|
| `src/tool/inspection.zig` | ToolInspector, InspectionPhase, InspectionAction |
| `src/tool/parallel.zig` | Parallel tool execution with max concurrency |

### Files to Modify
| File | Change |
|------|--------|
| `src/agent/loop.zig` | Add inspection pipeline to `executeTool()`, support parallel tool calls |
| `build.zig` | Add `tool_inspection_mod`, `tool_parallel_mod` |

### Data Model

```zig
// src/tool/inspection.zig
pub const DangerLevel = enum { safe, moderate, dangerous };

pub const InspectionPhase = enum { pre, post };
pub const InspectionAction = enum { allow, deny, ask, modify };

pub const InspectionResult = struct {
    action: InspectionAction,
    inspector_name: []const u8,
    reason: ?[]const u8,
    modified_args: ?[]const u8,  // for modify action
};

pub const ToolInspector = struct {
    name: []const u8,
    inspectFn: *const fn (
        allocator: std.mem.Allocator,
        tool_name: []const u8,
        args: []const u8,
        phase: InspectionPhase,
    ) anyerror!?InspectionResult,
};

pub const ToolInspectionPipeline = struct {
    allocator: std.mem.Allocator,
    inspectors: std.ArrayList(ToolInspector),

    pub fn init(allocator) ToolInspectionPipeline;
    pub fn addInspector(self: *ToolInspectionPipeline, inspector: ToolInspector) !void;
    pub fn inspectPre(self: *ToolInspectionPipeline, tool_name: []const u8, args: []const u8) !InspectionResult;
    pub fn inspectPost(self: *ToolInspectionPipeline, tool_name: []const u8, result: []const u8) !InspectionResult;
    pub fn deinit(self: *ToolInspectionPipeline) void;
};
```

```zig
// src/tool/parallel.zig
pub fn executeToolsParallel(
    allocator: std.mem.Allocator,
    executors: []const ToolExecutor,
    calls: []const ToolCall,
    max_concurrency: u32,
) ![]ToolResult {
    // Use std.Thread pool for parallel execution
    // Collect results, maintain ordering by call_id
    // Respect max_concurrency limit
}
```

### Danger Level Classification
| Tool | Danger Level | Auto-Approve |
|------|-------------|--------------|
| `read_file` | safe | yes |
| `glob`, `grep` | safe | yes |
| `web_fetch` | safe | yes |
| `write_file` | moderate | depends on agent mode |
| `edit` | moderate | depends on agent mode |
| `shell` | dangerous | requires approval |

### Integration Points
1. **`AgentLoop.executeTool()`** — Run pre-inspection before execution, post-inspection after
2. **`AgentLoop.run()`** — When multiple tool calls in one response, execute safe ones in parallel
3. **`AgentMode.isToolAllowed()`** — Refactored to use danger level + inspection pipeline

### Tests
- Pre-inspection allow/deny for safe/dangerous tools
- Post-inspection validates tool output
- Parallel execution produces correct results for independent calls
- Concurrency limit respected

### Estimated Effort
2–3 days

### Success Criteria
- Every tool call goes through inspection pipeline
- Dangerous tools require explicit approval
- Multiple independent tool calls execute in parallel
- Inspection results recorded in trace spans

---

## Dependency Graph

```
Phase 1 (Traces) ──────────┐
                            ├─► Phase 3 (Routing)
Phase 2 (Retry) ───────────┤
                            ├─► Phase 4 (Guardrails)
Phase 5 (Metrics) ─────────┤     (needs traces for integration)
                            ├─► Phase 6 (Memory)
Phase 1+2 can run in        │     (standalone, extends compaction)
parallel. Phases 3,4,5      │
need Phase 1 traces.        └─► Phase 7 (Tool Inspection)
Phase 6 is independent.          (needs traces + retry)
Phase 7 needs 1+2.

Sequential: Phase 1 → Phase 3 → Phase 5
Sequential: Phase 1 → Phase 4
Sequential: Phase 2 → Phase 7
Parallel:   Phase 6 (independent)
```

**Parallelism opportunities:**
- Phases 1 + 2: Fully parallel (no shared files except build.zig)
- Phase 3 + 4: Mostly parallel (Phase 3 touches router.zig, Phase 4 creates new guardrail/)
- Phase 5: Can start once Phase 1 traces exist (needs Metric recording in trace emission points)
- Phase 6: Independent, can start anytime

---

## Version Targets

| Phase | Target Version | Key Deliverable | Effort |
|-------|---------------|-----------------|--------|
| Phase 1 | v1.4.0 | Execution traces + JSONL export | 2–3 days |
| Phase 2 | v1.4.0 | Self-healing retry + error classification | 1–2 days |
| Phase 3 | v1.5.0 | Circuit breaker + fallback chains + budget enforcement | 1–2 days |
| Phase 4 | v1.5.0 | Guardrail pipeline (PII + injection + secrets) | 2–3 days |
| Phase 5 | v1.6.0 | Metrics collector + JSONL + Prometheus export | 2 days |
| Phase 6 | v1.7.0 | LLM-based compaction + cache-aware prompts | 2 days |
| Phase 7 | v2.0.0 | Tool inspection + parallel execution | 2–3 days |

**Total estimated effort:** 12–17 days

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| JSONL files grow unbounded | High | Low | Implement log rotation (keep last 7 days, max 50MB per file) |
| Regex-based guardrails have false positives | Medium | Medium | Start in monitor mode by default, tune patterns before switching to enforce |
| LLM-based compaction adds latency/cost | Medium | Medium | Use cheapest model (haiku), only trigger at 80% threshold, cache summaries |
| Zig `std.crypto.random` insufficient for UUID generation | Low | Low | Use `std.time.nanoTimestamp()` XOR'd with counter for 128-bit IDs |
| Circuit breaker false trips on transient provider issues | Medium | Medium | Set threshold to 5 failures, reset timeout to 30s, log all state transitions |
| Parallel tool execution with shared state | Medium | High | Only parallelize independent tool calls (no file write overlap), sequential for same-file ops |
| `std.http.Client` doesn't expose retry-after headers | Medium | Low | Parse response headers manually from raw response, fallback to exponential backoff |

---

## Build.zig Integration Plan

New modules to add to `build.zig`:

```zig
// Phase 1
const trace_span_mod = simpleMod(b, "src/trace/span.zig", target, optimize);
const trace_writer_mod = createMod(b, "src/trace/writer.zig", target, optimize, &.{
    imp("trace_span", trace_span_mod),
});
const trace_context_mod = createMod(b, "src/trace/context.zig", target, optimize, &.{
    imp("trace_span", trace_span_mod),
});

// Phase 2
const retry_policy_mod = simpleMod(b, "src/retry/policy.zig", target, optimize);
const retry_self_heal_mod = createMod(b, "src/retry/self_heal.zig", target, optimize, &.{
    imp("retry_policy", retry_policy_mod),
});

// Phase 3
const circuit_breaker_mod = simpleMod(b, "src/agent/circuit_breaker.zig", target, optimize);

// Phase 4
const guardrail_pipeline_mod = createMod(b, "src/guardrail/pipeline.zig", target, optimize, &.{});
const guardrail_pii_mod = simpleMod(b, "src/guardrail/pii_scanner.zig", target, optimize);
const guardrail_injection_mod = simpleMod(b, "src/guardrail/injection.zig", target, optimize);
const guardrail_secrets_mod = simpleMod(b, "src/guardrail/secrets.zig", target, optimize);

// Phase 5
const metrics_collector_mod = simpleMod(b, "src/metrics/collector.zig", target, optimize);
const metrics_registry_mod = createMod(b, "src/metrics/registry.zig", target, optimize, &.{
    imp("metrics_collector", metrics_collector_mod),
});

// Phase 7
const tool_inspection_mod = simpleMod(b, "src/tool/inspection.zig", target, optimize);
const tool_parallel_mod = simpleMod(b, "src/tool/parallel.zig", target, optimize);
```
