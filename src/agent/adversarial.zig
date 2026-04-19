const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;

// ── ThinkingMode ──────────────────────────────────────────────────────────────

pub const ThinkingMode = enum {
    challenge,
    emerge,
    connect,
    graduate,
};

// ── ThinkingResult ────────────────────────────────────────────────────────────

pub const ThinkingResult = struct {
    allocator: Allocator,
    mode: ThinkingMode,
    input: []const u8,
    output: []const u8,
    confidence: f64,
    perspectives: [][]const u8,
    timestamp: i64,

    pub fn deinit(self: *const ThinkingResult) void {
        self.allocator.free(self.input);
        self.allocator.free(self.output);
        for (self.perspectives) |p| {
            self.allocator.free(p);
        }
        self.allocator.free(self.perspectives);
    }
};

// ── ThinkingEngine ────────────────────────────────────────────────────────────

pub const ThinkingEngine = struct {
    allocator: Allocator,
    history: ArrayList(ThinkingResult),
    max_history: u32,
    knowledge_facts: ArrayList([]const u8),

    pub fn init(allocator: Allocator) ThinkingEngine {
        return .{
            .allocator = allocator,
            .history = ArrayList(ThinkingResult).init(allocator),
            .max_history = 50,
            .knowledge_facts = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ThinkingEngine) void {
        // Free history items
        for (self.history.items) |*item| {
            item.deinit();
        }
        self.history.deinit();

        // Free knowledge facts
        for (self.knowledge_facts.items) |fact| {
            self.allocator.free(fact);
        }
        self.knowledge_facts.deinit();
    }

    /// Add a knowledge fact (dupe'd)
    pub fn addFact(self: *ThinkingEngine, fact: []const u8) !void {
        const owned = try self.allocator.dupe(u8, fact);
        try self.knowledge_facts.append(owned);
    }

    /// Get recent history up to `limit`
    pub fn getHistory(self: *const ThinkingEngine, limit: u32) []ThinkingResult {
        const len = @min(limit, @as(u32, @intCast(self.history.items.len)));
        if (len == 0) return &[_]ThinkingResult{};
        const start = self.history.items.len - len;
        return self.history.items[start..];
    }

    /// Clear all history
    pub fn clearHistory(self: *ThinkingEngine) void {
        for (self.history.items) |*item| {
            item.deinit();
        }
        self.history.clearRetainingCapacity();
    }

    /// Store a result and trim to max_history
    fn storeResult(self: *ThinkingEngine, result: ThinkingResult) !void {
        try self.history.append(result);
        // Trim oldest if over limit
        while (self.history.items.len > self.max_history) {
            var old = self.history.orderedRemove(0);
            old.deinit();
        }
    }

    // ── Challenge ──────────────────────────────────────────────────────────

    /// Generate counter-arguments against an idea using knowledge and history
    pub fn challenge(self: *ThinkingEngine, idea: []const u8) !ThinkingResult {
        var perspectives = ArrayList([]const u8).init(self.allocator);
        var output_buf = ArrayList(u8).init(self.allocator);
        const writer = output_buf.writer();

        try writer.print("=== Adversarial Challenge: \"{s}\" ===\n\n", .{idea});

        // Strategy 1: Invert core assumptions
        const inverted = try self.invertAssumptions(idea);
        try writer.print("1. Inverted Assumptions:\n   {s}\n\n", .{inverted});
        self.allocator.free(inverted);
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Assumption inversion of '{s}'", .{idea}));

        // Strategy 2: Edge case detection
        const edge_cases = try self.findEdgeCases(idea);
        try writer.print("2. Edge Cases:\n   {s}\n\n", .{edge_cases});
        self.allocator.free(edge_cases);
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Edge case analysis for '{s}'", .{idea}));

        // Strategy 3: Historical contradictions
        const contradictions = try self.findContradictions(idea);
        try writer.print("3. Historical Contradictions:\n   {s}\n\n", .{contradictions});
        self.allocator.free(contradictions);
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Historical contradiction check", .{}));

        // Strategy 4: Fact-based challenges
        const fact_challenges = try self.factBasedChallenges(idea);
        try writer.print("4. Knowledge-Based Challenges:\n   {s}\n\n", .{fact_challenges});
        self.allocator.free(fact_challenges);
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Knowledge base challenge", .{}));

        // Strategy 5: Scope and feasibility
        try writer.print("5. Scope & Feasibility:\n   Consider whether \"{s}\" is achievable with current constraints. What resources, time, and expertise are required?\n", .{idea});
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Scope/feasibility assessment", .{}));

        // Confidence based on history size and facts
        const confidence = self.computeConfidence();

        const result = ThinkingResult{
            .allocator = self.allocator,
            .mode = .challenge,
            .input = try self.allocator.dupe(u8, idea),
            .output = try output_buf.toOwnedSlice(),
            .confidence = confidence,
            .perspectives = try perspectives.toOwnedSlice(),
            .timestamp = std.time.milliTimestamp(),
        };
        try self.storeResult(result);
        return result;
    }

    // ── Emerge ────────────────────────────────────────────────────────────

    /// Surface hidden patterns across accumulated knowledge and history
    pub fn emerge(self: *ThinkingEngine) !ThinkingResult {
        var perspectives = ArrayList([]const u8).init(self.allocator);
        var output_buf = ArrayList(u8).init(self.allocator);
        const writer = output_buf.writer();

        try writer.print("=== Emerging Patterns ===\n\n", .{});

        if (self.history.items.len == 0 and self.knowledge_facts.items.len == 0) {
            try writer.print("Insufficient data for pattern detection.\n", .{});
            try writer.print("Add thinking results and knowledge facts first.\n", .{});

            const result = ThinkingResult{
                .allocator = self.allocator,
                .mode = .emerge,
                .input = try self.allocator.dupe(u8, "emerge"),
                .output = try output_buf.toOwnedSlice(),
                .confidence = 0.0,
                .perspectives = try perspectives.toOwnedSlice(),
                .timestamp = std.time.milliTimestamp(),
            };
            try self.storeResult(result);
            return result;
        }

        // Find keyword clusters across history
        const clusters = try self.findKeywordClusters();
        defer {
            for (clusters) |c| self.allocator.free(c);
            self.allocator.free(clusters);
        }

        if (clusters.len > 0) {
            try writer.print("Keyword Clusters ({d} found):\n", .{clusters.len});
            for (clusters, 0..) |cluster, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, cluster });
            }
            try writer.print("\n", .{});
            try perspectives.append(try std.fmt.allocPrint(self.allocator, "Found {d} keyword clusters", .{clusters.len}));
        } else {
            try writer.print("No significant keyword clusters detected.\n\n", .{});
        }

        // Cross-reference facts with history
        const cross_refs = try self.crossReferenceFacts();
        defer {
            for (cross_refs) |c| self.allocator.free(c);
            self.allocator.free(cross_refs);
        }

        if (cross_refs.len > 0) {
            try writer.print("Cross-References ({d} connections):\n", .{cross_refs.len});
            for (cross_refs, 0..) |ref, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, ref });
            }
            try writer.print("\n", .{});
            try perspectives.append(try std.fmt.allocPrint(self.allocator, "Found {d} cross-references", .{cross_refs.len}));
        } else {
            try writer.print("No cross-references between facts and history.\n\n", .{});
        }

        // Detect recurring themes
        const themes = try self.detectThemes();
        defer {
            for (themes) |t| self.allocator.free(t);
            self.allocator.free(themes);
        }

        if (themes.len > 0) {
            try writer.print("Recurring Themes:\n", .{});
            for (themes, 0..) |theme, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, theme });
            }
            try perspectives.append(try std.fmt.allocPrint(self.allocator, "Detected {d} recurring themes", .{themes.len}));
        }

        const confidence = self.computeConfidence();

        const result = ThinkingResult{
            .allocator = self.allocator,
            .mode = .emerge,
            .input = try self.allocator.dupe(u8, "emerge"),
            .output = try output_buf.toOwnedSlice(),
            .confidence = confidence,
            .perspectives = try perspectives.toOwnedSlice(),
            .timestamp = std.time.milliTimestamp(),
        };
        try self.storeResult(result);
        return result;
    }

    // ── Connect ───────────────────────────────────────────────────────────

    /// Bridge two unrelated topics by finding shared concepts
    pub fn connect(self: *ThinkingEngine, topic_a: []const u8, topic_b: []const u8) !ThinkingResult {
        var perspectives = ArrayList([]const u8).init(self.allocator);
        var output_buf = ArrayList(u8).init(self.allocator);
        const writer = output_buf.writer();

        try writer.print("=== Connecting: \"{s}\" <-> \"{s}\" ===\n\n", .{ topic_a, topic_b });

        // Find shared vocabulary words
        const shared = try self.findSharedVocabulary(topic_a, topic_b);
        defer {
            for (shared.words) |w| self.allocator.free(w);
            self.allocator.free(shared.words);
        }

        if (shared.words.len > 0) {
            try writer.print("Shared Concepts ({d}):\n", .{shared.words.len});
            for (shared.words, 0..) |word, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, word });
            }
            try writer.print("\n", .{});
            try perspectives.append(try std.fmt.allocPrint(self.allocator, "Found {d} shared concepts between topics", .{shared.words.len}));
        } else {
            try writer.print("No direct vocabulary overlap. Exploring analogies...\n\n", .{});
        }

        // Generate analogies
        const analogies = try self.generateAnalogies(topic_a, topic_b);
        defer {
            for (analogies) |a| self.allocator.free(a);
            self.allocator.free(analogies);
        }

        try writer.print("Analogies & Metaphors:\n", .{});
        for (analogies, 0..) |analogy, i| {
            try writer.print("  {d}. {s}\n", .{ i + 1, analogy });
        }
        try writer.print("\n", .{});
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Generated {d} analogies", .{analogies.len}));

        // Find shared principles
        const principles = try self.findSharedPrinciples(topic_a, topic_b);
        defer {
            for (principles) |p| self.allocator.free(p);
            self.allocator.free(principles);
        }

        try writer.print("Shared Principles:\n", .{});
        for (principles, 0..) |principle, i| {
            try writer.print("  {d}. {s}\n", .{ i + 1, principle });
        }
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Identified {d} shared principles", .{principles.len}));

        // Cross-reference with knowledge
        if (self.knowledge_facts.items.len > 0) {
            const a_refs = self.countFactMatches(topic_a);
            const b_refs = self.countFactMatches(topic_b);
            try writer.print("\nKnowledge Base Overlap: topic_a={d} facts, topic_b={d} facts\n", .{ a_refs, b_refs });
        }

        const confidence = 0.4 + 0.1 * @min(@as(f64, @floatFromInt(shared.words.len)), 5.0) + 0.1 * @min(@as(f64, @floatFromInt(analogies.len)), 3.0);

        const result = ThinkingResult{
            .allocator = self.allocator,
            .mode = .connect,
            .input = try std.fmt.allocPrint(self.allocator, "{s} <-> {s}", .{ topic_a, topic_b }),
            .output = try output_buf.toOwnedSlice(),
            .confidence = @min(confidence, 1.0),
            .perspectives = try perspectives.toOwnedSlice(),
            .timestamp = std.time.milliTimestamp(),
        };
        try self.storeResult(result);
        return result;
    }

    // ── Graduate ──────────────────────────────────────────────────────────

    /// Turn an idea into a structured project plan
    pub fn graduate(self: *ThinkingEngine, idea: []const u8) !ThinkingResult {
        var perspectives = ArrayList([]const u8).init(self.allocator);
        var output_buf = ArrayList(u8).init(self.allocator);
        const writer = output_buf.writer();

        try writer.print("=== Project Graduation: \"{s}\" ===\n\n", .{idea});

        // Phase breakdown
        try writer.print("## Phases\n\n", .{});
        try writer.print("Phase 1: Discovery & Research\n", .{});
        try writer.print("  - Validate core assumptions behind \"{s}\"\n", .{idea});
        try writer.print("  - Survey existing solutions and prior art\n", .{});
        try writer.print("  - Identify key stakeholders and dependencies\n\n", .{});

        try writer.print("Phase 2: Design & Architecture\n", .{});
        try writer.print("  - Define system boundaries and interfaces\n", .{});
        try writer.print("  - Create technical specification\n", .{});
        try writer.print("  - Map \"{s}\" to concrete deliverables\n\n", .{idea});

        try writer.print("Phase 3: Implementation\n", .{});
        try writer.print("  - Build core functionality incrementally\n", .{});
        try writer.print("  - Set up testing and CI pipeline\n", .{});
        try writer.print("  - Document decisions and rationale\n\n", .{});

        try writer.print("Phase 4: Validation & Polish\n", .{});
        try writer.print("  - End-to-end testing against requirements\n", .{});
        try writer.print("  - Performance and security review\n", .{});
        try writer.print("  - User acceptance criteria verification\n\n", .{});

        try perspectives.append(try std.fmt.allocPrint(self.allocator, "4-phase breakdown for '{s}'", .{idea}));

        // Success criteria
        try writer.print("## Success Criteria\n\n", .{});
        try writer.print("1. Core idea validates against real-world constraints\n", .{});
        try writer.print("2. MVP delivers value within first iteration\n", .{});
        try writer.print("3. Architecture supports expected growth\n", .{});
        try writer.print("4. All critical paths have test coverage\n\n", .{});
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "4 success criteria defined", .{}));

        // Risks
        try writer.print("## Risks\n\n", .{});
        const risks = try self.identifyRisks(idea);
        defer {
            for (risks) |r| self.allocator.free(r);
            self.allocator.free(risks);
        }
        for (risks, 0..) |risk, i| {
            try writer.print("{d}. {s}\n", .{ i + 1, risk });
        }
        try writer.print("\n", .{});
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "Identified {d} risks", .{risks.len}));

        // Milestones
        try writer.print("## Milestones\n\n", .{});
        try writer.print("M1: Research complete — assumptions validated\n", .{});
        try writer.print("M2: Design approved — spec reviewed\n", .{});
        try writer.print("M3: Core shipped — MVP functional\n", .{});
        try writer.print("M4: Release ready — all criteria met\n", .{});
        try perspectives.append(try std.fmt.allocPrint(self.allocator, "4 milestones defined", .{}));

        const confidence = self.computeConfidence();

        const result = ThinkingResult{
            .allocator = self.allocator,
            .mode = .graduate,
            .input = try self.allocator.dupe(u8, idea),
            .output = try output_buf.toOwnedSlice(),
            .confidence = confidence,
            .perspectives = try perspectives.toOwnedSlice(),
            .timestamp = std.time.milliTimestamp(),
        };
        try self.storeResult(result);
        return result;
    }

    // ── Internal Helpers ──────────────────────────────────────────────────

    fn computeConfidence(self: *const ThinkingEngine) f64 {
        const history_weight = @min(@as(f64, @floatFromInt(self.history.items.len)) / 20.0, 0.4);
        const facts_weight = @min(@as(f64, @floatFromInt(self.knowledge_facts.items.len)) / 10.0, 0.3);
        return 0.3 + history_weight + facts_weight;
    }

    fn invertAssumptions(self: *ThinkingEngine, idea: []const u8) ![]const u8 {
        // Look for assumption-indicating words and invert them
        const assumption_words = [_][]const u8{ "will", "should", "always", "never", "must", "can", "only", "best", "simple", "easy", "fast", "safe", "secure", "reliable" };
        var buf = ArrayList(u8).init(self.allocator);
        const w = buf.writer();

        try w.print("What if the opposite were true? ", .{});
        var found = false;
        for (assumption_words) |word| {
            if (std.mem.indexOf(u8, idea, word)) |_| {
                if (found) try w.print(" Also, ", .{});
                try w.print("\"{s}\" in the premise may not hold. ", .{word});
                found = true;
            }
        }
        if (!found) {
            try w.print("The core premise of \"{s}\" should be questioned — what evidence supports it?", .{idea});
        }

        return try buf.toOwnedSlice();
    }

    fn findEdgeCases(self: *ThinkingEngine, idea: []const u8) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        const w = buf.writer();

        var count: u32 = 0;

        // Scale edge case
        try w.print("- What happens at 10x or 100x scale?\n", .{});
        count += 1;

        // Empty input edge case
        try w.print("- What if the input is empty, null, or malformed?\n", .{});
        count += 1;

        // Concurrency edge case
        try w.print("- What if multiple agents act on this simultaneously?\n", .{});
        count += 1;

        // Check for specific keywords
        if (std.mem.indexOf(u8, idea, "data") != null or std.mem.indexOf(u8, idea, "information") != null) {
            try w.print("- What about data privacy and regulatory compliance?\n", .{});
            count += 1;
        }
        if (std.mem.indexOf(u8, idea, "user") != null or std.mem.indexOf(u8, idea, "client") != null) {
            try w.print("- What if users behave unpredictably or maliciously?\n", .{});
            count += 1;
        }

        // Always add at least one general case
        if (count < 3) {
            try w.print("- What are the failure modes and recovery paths?\n", .{});
        }

        // Cross-reference with knowledge facts for domain-specific edge cases
        for (self.knowledge_facts.items) |fact| {
            if (std.mem.indexOf(u8, fact, idea) != null) {
                try w.print("- Related knowledge: {s}\n", .{fact});
            }
        }

        return try buf.toOwnedSlice();
    }

    fn findContradictions(self: *ThinkingEngine, idea: []const u8) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        const w = buf.writer();

        var found = false;
        for (self.history.items) |item| {
            // Check for keyword overlap with opposing modes
            if (item.mode == .challenge) {
                if (std.mem.indexOf(u8, item.input, idea) != null or std.mem.indexOf(u8, idea, item.input) != null) {
                    if (!found) {
                        try w.print("Previous challenges against similar ideas:\n", .{});
                        found = true;
                    }
                    const snippet = if (item.output.len > 100) item.output[0..100] else item.output;
                    try w.print("  - [{s}] {s}...\n", .{ @tagName(item.mode), snippet });
                }
            }
        }

        if (!found) {
            try w.print("No direct contradictions found in history. This is either novel or unchallenged.\n", .{});
        }

        return try buf.toOwnedSlice();
    }

    fn factBasedChallenges(self: *ThinkingEngine, idea: []const u8) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        const w = buf.writer();

        if (self.knowledge_facts.items.len == 0) {
            try w.print("No knowledge facts accumulated. Add facts to enable evidence-based challenges.\n", .{});
            return try buf.toOwnedSlice();
        }

        var matches: u32 = 0;
        for (self.knowledge_facts.items) |fact| {
            // Simple overlap check
            if (self.hasOverlap(idea, fact)) {
                try w.print("  Fact: \"{s}\" may contradict or constrain the idea.\n", .{fact});
                matches += 1;
                if (matches >= 3) break;
            }
        }

        if (matches == 0) {
            try w.print("No relevant facts found to challenge this idea. Consider adding domain knowledge.\n", .{});
        }

        return try buf.toOwnedSlice();
    }

    fn hasOverlap(self: *const ThinkingEngine, a: []const u8, b: []const u8) bool {
        _ = self;
        // Check if any 4+ char substring of the shorter appears in the longer
        const shorter = if (a.len < b.len) a else b;
        const longer = if (a.len < b.len) b else a;
        if (shorter.len < 4) return false;

        var i: usize = 0;
        while (i + 4 <= shorter.len) : (i += 1) {
            const substr = shorter[i .. i + 4];
            if (std.mem.indexOf(u8, longer, substr) != null) return true;
        }
        return false;
    }

    const SharedVocabulary = struct {
        words: [][]const u8,
    };

    fn findSharedVocabulary(self: *ThinkingEngine, topic_a: []const u8, topic_b: []const u8) !SharedVocabulary {
        var shared = ArrayList([]const u8).init(self.allocator);

        // Extract words from both topics
        const words_a = try self.extractWords(topic_a);
        defer self.allocator.free(words_a);
        const words_b = try self.extractWords(topic_b);
        defer self.allocator.free(words_b);

        // Find common words (4+ chars)
        for (words_a) |word_a| {
            if (word_a.len < 4) continue;
            for (words_b) |word_b| {
                if (std.mem.eql(u8, word_a, word_b)) {
                    // Check if already added
                    var already = false;
                    for (shared.items) |s| {
                        if (std.mem.eql(u8, s, word_a)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try shared.append(try self.allocator.dupe(u8, word_a));
                    }
                }
            }
        }

        // Also check for semantic bridges from knowledge facts
        for (self.knowledge_facts.items) |fact| {
            const has_a = std.mem.indexOf(u8, fact, topic_a) != null or self.hasWordOverlap(topic_a, fact);
            const has_b = std.mem.indexOf(u8, fact, topic_b) != null or self.hasWordOverlap(topic_b, fact);
            if (has_a and has_b) {
                // Extract bridging word from the fact
                const bridge = try std.fmt.allocPrint(self.allocator, "via: {s}", .{if (fact.len > 60) fact[0..60] else fact});
                try shared.append(bridge);
            }
        }

        return .{ .words = try shared.toOwnedSlice() };
    }

    fn hasWordOverlap(self: *const ThinkingEngine, topic: []const u8, text: []const u8) bool {
        _ = self;
        var words = std.mem.splitScalar(u8, topic, ' ');
        var count: u32 = 0;
        while (words.next()) |word| {
            if (word.len >= 4 and std.mem.indexOf(u8, text, word) != null) {
                count += 1;
                if (count >= 2) return true;
            }
        }
        return false;
    }

    fn extractWords(self: *ThinkingEngine, text: []const u8) ![][]const u8 {
        var words = ArrayList([]const u8).init(self.allocator);
        var iter = std.mem.splitScalar(u8, text, ' ');
        while (iter.next()) |word| {
            // Trim punctuation
            var start: usize = 0;
            while (start < word.len and (word[start] < 'a' or word[start] > 'z') and (word[start] < 'A' or word[start] > 'Z')) {
                start += 1;
            }
            var end = word.len;
            while (end > start and (word[end - 1] < 'a' or word[end - 1] > 'z') and (word[end - 1] < 'A' or word[end - 1] > 'Z')) {
                end -= 1;
            }
            if (start < end) {
                try words.append(word[start..end]);
            }
        }
        return try words.toOwnedSlice();
    }

    fn generateAnalogies(self: *ThinkingEngine, topic_a: []const u8, topic_b: []const u8) ![][]const u8 {
        var analogies = ArrayList([]const u8).init(self.allocator);

        // Template-based analogy generation
        try analogies.append(try std.fmt.allocPrint(self.allocator, "\"{s}\" is to \"{s}\" as structure is to flow — both essential, different in nature.", .{ topic_a, topic_b }));
        try analogies.append(try std.fmt.allocPrint(self.allocator, "Think of \"{s}\" as the foundation and \"{s}\" as the architecture built on top.", .{ topic_a, topic_b }));
        try analogies.append(try std.fmt.allocPrint(self.allocator, "If \"{s}\" is a seed, \"{s}\" might be the ecosystem it grows in.", .{ topic_a, topic_b }));

        // Knowledge-enriched analogies
        for (self.knowledge_facts.items, 0..) |fact, i| {
            if (i >= 2) break;
            if (self.hasOverlap(topic_a, fact) or self.hasOverlap(topic_b, fact)) {
                try analogies.append(try std.fmt.allocPrint(self.allocator, "Knowledge bridge: {s}", .{if (fact.len > 80) fact[0..80] else fact}));
            }
        }

        return try analogies.toOwnedSlice();
    }

    fn findSharedPrinciples(self: *ThinkingEngine, topic_a: []const u8, topic_b: []const u8) ![][]const u8 {
        var principles = ArrayList([]const u8).init(self.allocator);

        // Universal principles that often apply
        try principles.append(try std.fmt.allocPrint(self.allocator, "Both \"{s}\" and \"{s}\" benefit from iteration and refinement.", .{ topic_a, topic_b }));
        try principles.append(try std.fmt.allocPrint(self.allocator, "Measurement and feedback loops apply equally to both domains.", .{}));
        try principles.append(try std.fmt.allocPrint(self.allocator, "Trade-offs between simplicity and completeness exist in both contexts.", .{}));

        return try principles.toOwnedSlice();
    }

    fn countFactMatches(self: *const ThinkingEngine, topic: []const u8) u32 {
        var count: u32 = 0;
        for (self.knowledge_facts.items) |fact| {
            if (std.mem.indexOf(u8, fact, topic) != null) {
                count += 1;
            }
        }
        return count;
    }

    fn identifyRisks(self: *ThinkingEngine, idea: []const u8) ![][]const u8 {
        var risks = ArrayList([]const u8).init(self.allocator);

        try risks.append(try std.fmt.allocPrint(self.allocator, "Scope creep: \"{s}\" may expand beyond initial boundaries", .{idea}));
        try risks.append(try std.fmt.allocPrint(self.allocator, "Technical debt: rapid iteration may compromise quality", .{}));
        try risks.append(try std.fmt.allocPrint(self.allocator, "Resource constraints: insufficient time, expertise, or budget", .{}));

        // Knowledge-informed risks
        if (self.knowledge_facts.items.len > 0) {
            for (self.knowledge_facts.items, 0..) |fact, i| {
                if (i >= 2) break;
                if (self.hasOverlap(idea, fact)) {
                    try risks.append(try std.fmt.allocPrint(self.allocator, "Known constraint: {s}", .{if (fact.len > 60) fact[0..60] else fact}));
                }
            }
        }

        try risks.append(try std.fmt.allocPrint(self.allocator, "Adoption risk: users may resist change from current approach", .{}));

        return try risks.toOwnedSlice();
    }

    fn findKeywordClusters(self: *ThinkingEngine) ![][]const u8 {
        var clusters = ArrayList([]const u8).init(self.allocator);

        // Collect all significant words from history
        var word_counts = std.StringHashMap(u32).init(self.allocator);
        defer {
            var iter = word_counts.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            word_counts.deinit();
        }

        for (self.history.items) |item| {
            const text = item.output;
            var word_iter = std.mem.splitScalar(u8, text, ' ');
            while (word_iter.next()) |word| {
                // Clean word
                var start: usize = 0;
                while (start < word.len and !isAlpha(word[start])) start += 1;
                var end = word.len;
                while (end > start and !isAlpha(word[end - 1])) end -= 1;
                if (end - start < 4) continue;

                const cleaned = word[start..end];
                const owned = try self.allocator.dupe(u8, cleaned);

                const entry = try word_counts.getOrPut(owned);
                if (entry.found_existing) {
                    self.allocator.free(owned);
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }
        }

        // Find words that appear 2+ times
        var cluster_buf = ArrayList(u8).init(self.allocator);
        const cw = cluster_buf.writer();
        var cluster_count: u32 = 0;

        var counts_iter = word_counts.iterator();
        while (counts_iter.next()) |entry| {
            if (entry.value_ptr.* >= 2) {
                try cw.print("'{s}' (appears {d}x) ", .{ entry.key_ptr.*, entry.value_ptr.* });
                cluster_count += 1;
                if (cluster_count >= 5) break;
            }
        }

        if (cluster_buf.items.len > 0) {
            try clusters.append(try cluster_buf.toOwnedSlice());
        } else {
            cluster_buf.deinit();
        }

        return try clusters.toOwnedSlice();
    }

    fn crossReferenceFacts(self: *ThinkingEngine) ![][]const u8 {
        var refs = ArrayList([]const u8).init(self.allocator);

        for (self.knowledge_facts.items, 0..) |fact, fi| {
            for (self.history.items, 0..) |item, hi| {
                if (self.hasOverlap(fact, item.input)) {
                    try refs.append(try std.fmt.allocPrint(self.allocator, "Fact #{d} connects to {s} result #{d}", .{ fi, @tagName(item.mode), hi }));
                    break; // One ref per fact
                }
            }
        }

        return try refs.toOwnedSlice();
    }

    fn detectThemes(self: *ThinkingEngine) ![][]const u8 {
        var themes = ArrayList([]const u8).init(self.allocator);

        // Count modes
        var challenge_count: u32 = 0;
        var emerge_count: u32 = 0;
        var connect_count: u32 = 0;
        var graduate_count: u32 = 0;

        for (self.history.items) |item| {
            switch (item.mode) {
                .challenge => challenge_count += 1,
                .emerge => emerge_count += 1,
                .connect => connect_count += 1,
                .graduate => graduate_count += 1,
            }
        }

        if (challenge_count > 1) {
            try themes.append(try std.fmt.allocPrint(self.allocator, "Heavy emphasis on challenging ideas ({d} challenges)", .{challenge_count}));
        }
        if (connect_count > 1) {
            try themes.append(try std.fmt.allocPrint(self.allocator, "Pattern of connecting disparate domains ({d} connections)", .{connect_count}));
        }
        if (graduate_count > 0) {
            try themes.append(try std.fmt.allocPrint(self.allocator, "Active project planning tendency ({d} graduations)", .{graduate_count}));
        }
        if (self.knowledge_facts.items.len > 5) {
            try themes.append(try std.fmt.allocPrint(self.allocator, "Rich knowledge base ({d} facts accumulated)", .{self.knowledge_facts.items.len}));
        }

        return try themes.toOwnedSlice();
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "ThinkingResult creation and deinit" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.challenge("test idea");
    defer result.deinit();

    try std.testing.expect(result.mode == .challenge);
    try std.testing.expect(result.confidence >= 0.0);
    try std.testing.expect(result.confidence <= 1.0);
    try std.testing.expect(result.input.len > 0);
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.timestamp > 0);
}

test "Challenge generates counter-arguments" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.challenge("machine learning will solve everything");
    defer result.deinit();

    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Inverted") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Edge") != null);
    try std.testing.expect(result.perspectives.len >= 3);
}

test "Emerge with empty history returns insufficient data" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.emerge();
    defer result.deinit();

    try std.testing.expect(result.mode == .emerge);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Insufficient data") != null);
    try std.testing.expect(result.confidence == 0.0);
}

test "Emerge with data finds patterns" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    // Add some history first
    const r1 = try engine.challenge("machine learning optimization");
    r1.deinit();
    const r2 = try engine.challenge("machine learning deployment");
    r2.deinit();

    try engine.addFact("Machine learning requires training data");

    const result = try engine.emerge();
    defer result.deinit();

    try std.testing.expect(result.mode == .emerge);
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.confidence > 0.0);
}

test "Connect bridges two topics with shared concepts" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.connect("machine learning", "reinforcement learning");
    defer result.deinit();

    try std.testing.expect(result.mode == .connect);
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Analogies") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Shared") != null);
    try std.testing.expect(result.perspectives.len >= 2);

    // "learning" appears in both, so shared vocabulary should find it
    try std.testing.expect(std.mem.indexOf(u8, result.output, "learning") != null);
}

test "Connect with unrelated topics still produces output" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.connect("quantum physics", "baking bread");
    defer result.deinit();

    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Analogies") != null);
}

test "Graduate creates structured output" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.graduate("Build an AI-powered code review tool");
    defer result.deinit();

    try std.testing.expect(result.mode == .graduate);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Phases") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Success Criteria") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Risks") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Milestones") != null);
    try std.testing.expect(result.perspectives.len >= 3);
}

test "History tracking" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expect(engine.history.items.len == 0);

    const r1 = try engine.challenge("idea 1");
    r1.deinit();
    try std.testing.expect(engine.history.items.len == 1);

    const r2 = try engine.emerge();
    r2.deinit();
    try std.testing.expect(engine.history.items.len == 2);

    const history = engine.getHistory(1);
    try std.testing.expect(history.len == 1);
    try std.testing.expect(history[0].mode == .emerge);
}

test "History max limit" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    engine.max_history = 3;

    const r1 = try engine.challenge("idea 1");
    r1.deinit();
    const r2 = try engine.challenge("idea 2");
    r2.deinit();
    const r3 = try engine.challenge("idea 3");
    r3.deinit();
    const r4 = try engine.challenge("idea 4");
    r4.deinit();

    try std.testing.expect(engine.history.items.len == 3);
    // Oldest should have been evicted
    try std.testing.expect(std.mem.eql(u8, engine.history.items[0].input, "idea 2"));
}

test "Fact accumulation" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expect(engine.knowledge_facts.items.len == 0);

    try engine.addFact("The sky is blue");
    try engine.addFact("Water is wet");
    try std.testing.expect(engine.knowledge_facts.items.len == 2);
}

test "Clear history" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    const r1 = try engine.challenge("idea");
    r1.deinit();
    try std.testing.expect(engine.history.items.len == 1);

    engine.clearHistory();
    try std.testing.expect(engine.history.items.len == 0);
}

test "Challenge with knowledge facts" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    try engine.addFact("Neural networks require large datasets to generalize");
    try engine.addFact("Overfitting is a common problem in small data regimes");

    const result = try engine.challenge("We can build accurate models with minimal data");
    defer result.deinit();

    try std.testing.expect(result.output.len > 0);
}

test "Connect with knowledge facts" {
    const allocator = std.testing.allocator;
    var engine = ThinkingEngine.init(allocator);
    defer engine.deinit();

    try engine.addFact("Testing and validation share principles with quality assurance");

    const result = try engine.connect("testing", "validation");
    defer result.deinit();

    try std.testing.expect(result.output.len > 0);
}
