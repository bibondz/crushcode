# Graph Report - src  (2026-04-29)

## Corpus Check
- 297 files · ~447,877 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 4794 nodes · 13647 edges · 54 communities detected
- Extraction: 57% EXTRACTED · 43% INFERRED · 0% AMBIGUOUS · INFERRED: 5808 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 54|Community 54]]

## God Nodes (most connected - your core abstractions)
1. `ArrayList()` - 533 edges
2. `toOwnedSlice()` - 305 edges
3. `handleInteractiveChat()` - 146 edges
4. `readFileAlloc()` - 56 edges
5. `adaptToolExecution()` - 53 edges
6. `handleChat()` - 53 edges
7. `AIClient` - 49 edges
8. `LSPClient` - 46 edges
9. `Model` - 37 edges
10. `GitSkill` - 34 edges

## Surprising Connections (you probably didn't know these)
- `wrapHelp()` --calls--> `printHelp()`  [INFERRED]
  cli/registry.zig → commands/handlers/system.zig
- `handleSkillSync()` --calls--> `handleSkillSync()`  [INFERRED]
  commands/handlers/memory_handler.zig → skills/sync.zig
- `handleTemplate()` --calls--> `handleTemplate()`  [INFERRED]
  commands/handlers/memory_handler.zig → marketplace/template.zig
- `handleProfile()` --calls--> `handleProfile()`  [INFERRED]
  commands/handlers/system.zig → config/profile.zig
- `handleGrep()` --calls--> `parseLanguage()`  [INFERRED]
  commands/handlers/tools.zig → edit/pattern_search.zig

## Communities

### Community 0 - "Community 0"
Cohesion: 0.01
Nodes (142): SharedVocabulary, ThinkingEngine, ThinkingMode, ThinkingResult, Checkpoint, CheckpointManager, CheckpointMessage, CapabilityCatalog (+134 more)

### Community 1 - "Community 1"
Cohesion: 0.01
Nodes (163): ClusterInfo, GraphInsights, KnowledgePipeline, PipelineStats, RankedNode, SimilarityResult, formatContextSummary(), out() (+155 more)

### Community 2 - "Community 2"
Cohesion: 0.01
Nodes (126): Capability, CapabilityPhase, CompactionConfig, CompactionTier, CompactMessage, CompactResult, ContextCompactor, mockSendToLLM() (+118 more)

### Community 3 - "Community 3"
Cohesion: 0.01
Nodes (241): RetryConfig, RateLimiter, adaptToolExecution(), analyzeImageExecutor(), applyPatchExecutor(), buildToolFailure(), buildValidationError(), BuiltinDispatchEntry (+233 more)

### Community 4 - "Community 4"
Cohesion: 0.02
Nodes (135): Memory, Message, AgentSlot, AgentStatus, LiveAgentTeam, TeamResult, ThreadContext, workerThread() (+127 more)

### Community 5 - "Community 5"
Cohesion: 0.01
Nodes (124): classifyQueryType(), containsWord(), ContextSelection, detectLanguage(), determineSource(), extractFilePaths(), extractKeywords(), extractQueryIntent() (+116 more)

### Community 6 - "Community 6"
Cohesion: 0.02
Nodes (68): AgentDefinition, AgentMessage, AgentStatus, AgentTeam, EffortLevel, MemoryScope, MessageType, PermissionMode (+60 more)

### Community 7 - "Community 7"
Cohesion: 0.01
Nodes (95): ContextBudget, ModelBudget, LoopConfig, defaultConfig(), failingMockSendFn(), MoAConfig, MoAEngine, MoAResult (+87 more)

### Community 8 - "Community 8"
Cohesion: 0.03
Nodes (56): AgentCategory, CompletedWork, CompletionQueue, ParallelExecutor, ParallelTask, parseCategory(), workerThreadMain(), FallbackChain (+48 more)

### Community 9 - "Community 9"
Cohesion: 0.03
Nodes (48): registerCoreChatHooks(), absolutePathToFileUri(), detectLSPLanguage(), diagnosticSeverityName(), freeLSPCompletionItems(), freeLSPDiagnostics(), freeLSPLocations(), handleLSP() (+40 more)

### Community 10 - "Community 10"
Cohesion: 0.04
Nodes (64): isInterrupted(), CostDashboard, cleanSessions(), deleteSessionCmd(), findSessionByIdPrefix(), handleSessions(), listSessions(), printHelp() (+56 more)

### Community 11 - "Community 11"
Cohesion: 0.03
Nodes (53): PreferenceSource, UserModel, UserPreference, Auth, Credential, Action, Keymap, httpPost() (+45 more)

### Community 12 - "Community 12"
Cohesion: 0.03
Nodes (43): Command, contains(), dispatch(), wrapHelp(), KnowledgeEntry, KnowledgeLintConfig, KnowledgeLinter, LintFinding (+35 more)

### Community 13 - "Community 13"
Cohesion: 0.03
Nodes (36): WorkerResult, WorkerRunner, WorkerAgent, WorkerPool, WorkerSpecialty, WorkerStatus, handleJobs(), getManager() (+28 more)

### Community 14 - "Community 14"
Cohesion: 0.03
Nodes (42): AuthConfig, AuthType, ErrorHandlingConfig, ExtendedConfig, FallbackConfig, PerformanceConfig, ProviderConfig, ProviderType (+34 more)

### Community 15 - "Community 15"
Cohesion: 0.04
Nodes (43): getCurrentRef(), rollbackTo(), executeTaskPipeline(), GateVerdictSummary, PhaseRunConfig, PhaseRunner, PhaseRunResult, PipelineStepResult (+35 more)

### Community 16 - "Community 16"
Cohesion: 0.04
Nodes (89): check(), findCI(), InjectionPattern, startsWithCI(), toLower(), check(), isAlnum(), isAlpha() (+81 more)

### Community 17 - "Community 17"
Cohesion: 0.04
Nodes (46): FeedbackEntry, FeedbackStore, JsonEntry, TaskOutcome, TypeStats, handleCompare(), handleExport(), handleList() (+38 more)

### Community 18 - "Community 18"
Cohesion: 0.04
Nodes (22): getProjectHooksPath(), getUserHooksPath(), HookConfigEntry, HookFileConfig, loadAllHooks(), HookConfig, HookContext, HookRegistry (+14 more)

### Community 19 - "Community 19"
Cohesion: 0.06
Nodes (27): WorktreeInfo, WorktreeManager, getAllSkills(), getSkillExecutor(), handleSkill(), Skill, skillDate(), skillHostname() (+19 more)

### Community 20 - "Community 20"
Cohesion: 0.05
Nodes (32): LoopDetector, LoopDetectorConfig, boldColor(), clearScreen(), Color, cursorDown(), cursorHome(), cursorUp() (+24 more)

### Community 21 - "Community 21"
Cohesion: 0.05
Nodes (23): ByteResult, ConfidenceLevel, DetectionMethod, DetectionResult, FileContentType, FileDetector, MagicSignature, getOrCreatePipelineRunner() (+15 more)

### Community 22 - "Community 22"
Cohesion: 0.05
Nodes (19): handleKnowledge(), computeNameSimilarity(), KnowledgeLinter, LintFinding, LintRule, LintSeverity, CitationResult, IngestResult (+11 more)

### Community 23 - "Community 23"
Cohesion: 0.07
Nodes (48): executeEditBatchTool(), ContextFile, ContextFileSet, detectNodeFramework(), detectProject(), escapeXml(), getProjectConfigPath(), loadAgentsMd() (+40 more)

### Community 24 - "Community 24"
Cohesion: 0.06
Nodes (35): tryHandlePluginCommand(), executeCommand(), findCommand(), freeCommandFields(), freeCommands(), getCommandsValue(), getStringField(), getUserCommandsDir() (+27 more)

### Community 25 - "Community 25"
Cohesion: 0.09
Nodes (36): InputWidget, MultiLineInputWidget, acceptSuggestion(), checkChanged(), currentDisplayRows(), cursorDown(), cursorLeft(), CursorPos (+28 more)

### Community 26 - "Community 26"
Cohesion: 0.07
Nodes (14): handleUsage(), loadBudgetConfig(), resolvedPricingModel(), finishRequestSuccess(), resolvedPricingModel(), BudgetConfig, BudgetManager, BudgetStatus (+6 more)

### Community 27 - "Community 27"
Cohesion: 0.07
Nodes (31): checkConfigPermissions(), checkConfiguration(), checkCrushcodeBinary(), checkEnvironment(), checkGit(), checkInstallation(), checkNode(), checkProjectPermissions() (+23 more)

### Community 28 - "Community 28"
Cohesion: 0.09
Nodes (8): DistillationTrigger, LayeredMemory, MemoryEntry, MemoryLayer, MemoryStats, handleMemory(), HistoryEntry, ShellHistory

### Community 29 - "Community 29"
Cohesion: 0.08
Nodes (13): buildPTYArgs(), BuiltInPlugin, ExternalPlugin, Plugin, PluginConfig, PluginInfo, PluginResponse, PluginStatus (+5 more)

### Community 30 - "Community 30"
Cohesion: 0.1
Nodes (9): HashCache, HashIndex, HashlineEntry, StaleLineInfo, ValidationResult, Hashline, EditOperation, EditResult (+1 more)

### Community 31 - "Community 31"
Cohesion: 0.08
Nodes (10): Capability, ExternalPluginManager, HealthStatus, PluginError, Request, Response, RuntimePlugin, Status (+2 more)

### Community 32 - "Community 32"
Cohesion: 0.1
Nodes (9): HighlightedCode, HighlightedSegment, Language, SyntaxHighlighter, TokenType, VaxisColors, Options, RenderContext (+1 more)

### Community 33 - "Community 33"
Cohesion: 0.11
Nodes (19): cmdBudget(), cmdClear(), cmdCompact(), cmdCost(), cmdExit(), cmdExport(), cmdHelp(), cmdLspRestart() (+11 more)

### Community 34 - "Community 34"
Cohesion: 0.15
Nodes (7): commandExists(), detectNotifier(), EventType, NotifierEvent, NotifierPlugin, NotifierType, Severity

### Community 35 - "Community 35"
Cohesion: 0.13
Nodes (6): BackgroundAgent, BackgroundAgentKind, BackgroundAgentManager, BackgroundResult, BackgroundStatus, ScheduleConfig

### Community 36 - "Community 36"
Cohesion: 0.16
Nodes (11): CompressionLevel, CompressionResult, countPubFunctions(), countTypes(), FileInfo, FilesByLevel, isDocComment(), isImportLine() (+3 more)

### Community 37 - "Community 37"
Cohesion: 0.26
Nodes (6): Alignment, DataTable, renderDataTable(), renderDataTableBorderRow(), renderDataTablePlain(), TableColumn

### Community 38 - "Community 38"
Cohesion: 0.12
Nodes (6): RevisionConfig, RevisionLoop, RevisionOutcome, RevisionResult, RevisionState, RevisionSummary

### Community 39 - "Community 39"
Cohesion: 0.14
Nodes (7): AgentCategory, classifyTool(), DelegationConfig, DelegationResult, DepthToolPolicy, SubAgentDelegator, ToolRiskTier

### Community 40 - "Community 40"
Cohesion: 0.19
Nodes (5): ChatMessageLike, SideChain, SideChainManager, SideChainMessage, SideChainStatus

### Community 41 - "Community 41"
Cohesion: 0.2
Nodes (4): DesktopNotifier, NotifyConfig, Platform, Urgency

### Community 42 - "Community 42"
Cohesion: 0.25
Nodes (3): CustomCommand, CustomCommandLoader, splitFrontmatter()

### Community 43 - "Community 43"
Cohesion: 0.15
Nodes (4): CircuitBreaker, CircuitState, Color, Style

### Community 44 - "Community 44"
Cohesion: 0.26
Nodes (10): compareTraces(), computeVerdict(), countTools(), deltaPercent(), MetricDelta, toF(), ToolUsageDiff, totalTokens() (+2 more)

### Community 45 - "Community 45"
Cohesion: 0.24
Nodes (1): ScrollPanel

### Community 46 - "Community 46"
Cohesion: 0.26
Nodes (4): FilesWidget, MCPServerStatus, SidebarContext, SidebarWidget

### Community 47 - "Community 47"
Cohesion: 0.29
Nodes (2): AuditEntry, PermissionAuditLogger

### Community 48 - "Community 48"
Cohesion: 0.29
Nodes (2): CodeViewWidget, numDigits()

### Community 49 - "Community 49"
Cohesion: 0.24
Nodes (4): Conflict, ConflictResolver, Resolution, ResolutionStrategy

### Community 50 - "Community 50"
Cohesion: 0.25
Nodes (4): Recipe, RecipeStep, ResolvedRecipe, VariableDef

### Community 51 - "Community 51"
Cohesion: 0.22
Nodes (8): ChatChoice, ChatMessage, ChatRequest, ChatResponse, ExtendedUsage, ParsedToolCall, ToolCallInfo, Usage

### Community 52 - "Community 52"
Cohesion: 0.29
Nodes (5): BackgroundContext, ExecutionContext, RunState, TaskResult, WorktreeContext

### Community 54 - "Community 54"
Cohesion: 1.0
Nodes (1): ToolSchema

## Knowledge Gaps
- **438 isolated node(s):** `Stats`, `Session`, `ThinkingMode`, `SharedVocabulary`, `BackgroundAgentKind` (+433 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 45`** (13 nodes): `scroll_panel.zig`, `ScrollPanel`, `.deinit()`, `.init()`, `.maxScrollOffset()`, `.render()`, `.scrollDown()`, `.scrollPercent()`, `.scrollToBottom()`, `.scrollToTop()`, `.scrollUp()`, `.setContent()`, `.totalLines()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 47`** (12 nodes): `AuditEntry`, `.deinit()`, `.fromJson()`, `.toJson()`, `PermissionAuditLogger`, `.deinit()`, `.getFilePath()`, `.init()`, `.log()`, `.logDecision()`, `.recent()`, `audit.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 48`** (11 nodes): `code_view.zig`, `CodeViewWidget`, `.deinit()`, `.goToLine()`, `.init()`, `.maxScrollOffset()`, `.render()`, `.scrollDown()`, `.scrollUp()`, `.totalLines()`, `numDigits()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 54`** (2 nodes): `ToolSchema`, `tool_types.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ArrayList()` connect `Community 0` to `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 7`, `Community 8`, `Community 9`, `Community 10`, `Community 11`, `Community 12`, `Community 13`, `Community 14`, `Community 15`, `Community 16`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 24`, `Community 26`, `Community 27`, `Community 28`, `Community 29`, `Community 30`, `Community 32`, `Community 33`, `Community 35`, `Community 36`, `Community 37`, `Community 38`, `Community 39`, `Community 40`, `Community 42`, `Community 44`, `Community 45`, `Community 46`, `Community 47`?**
  _High betweenness centrality (0.164) - this node is a cross-community bridge._
- **Why does `handleInteractiveChat()` connect `Community 7` to `Community 0`, `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 8`, `Community 9`, `Community 10`, `Community 12`, `Community 13`, `Community 14`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 21`, `Community 24`, `Community 26`, `Community 31`, `Community 33`, `Community 34`, `Community 47`?**
  _High betweenness centrality (0.058) - this node is a cross-community bridge._
- **Why does `toOwnedSlice()` connect `Community 0` to `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 7`, `Community 8`, `Community 9`, `Community 10`, `Community 11`, `Community 13`, `Community 14`, `Community 15`, `Community 16`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 24`, `Community 25`, `Community 27`, `Community 28`, `Community 29`, `Community 32`, `Community 35`, `Community 36`, `Community 37`, `Community 40`, `Community 42`, `Community 44`, `Community 45`, `Community 46`, `Community 47`?**
  _High betweenness centrality (0.048) - this node is a cross-community bridge._
- **Are the 532 inferred relationships involving `ArrayList()` (e.g. with `.getAllToolSchemas()` and `listSessionsJson()`) actually correct?**
  _`ArrayList()` has 532 INFERRED edges - model-reasoned connections that need verification._
- **Are the 302 inferred relationships involving `toOwnedSlice()` (e.g. with `.getAllToolSchemas()` and `listSessionsJson()`) actually correct?**
  _`toOwnedSlice()` has 302 INFERRED edges - model-reasoned connections that need verification._
- **Are the 134 inferred relationships involving `handleInteractiveChat()` (e.g. with `loadProfileByName()` and `loadCurrentProfile()`) actually correct?**
  _`handleInteractiveChat()` has 134 INFERRED edges - model-reasoned connections that need verification._
- **Are the 49 inferred relationships involving `readFileAlloc()` (e.g. with `loadSessionJson()` and `.load()`) actually correct?**
  _`readFileAlloc()` has 49 INFERRED edges - model-reasoned connections that need verification._