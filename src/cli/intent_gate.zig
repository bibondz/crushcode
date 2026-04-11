const std = @import("std");

/// User intent classification — routes commands to appropriate handlers
///
/// Reference: oh-my-openagent IntentGate hook
pub const IntentType = enum {
    research, // "explain X", "how does Y work", "what is..."
    implementation, // "implement X", "add Y", "create Z", "fix W"
    investigation, // "look into X", "check Y", "investigate", "why does..."
    evaluation, // "what do you think about X?", "is Y good?"
    fix, // "I'm seeing error X", "Y is broken", "fix Z"
    open_ended, // "improve", "refactor", "clean up", "optimize"
    chat, // General conversation, greetings
};

/// Classified intent with confidence score
pub const IntentResult = struct {
    intent_type: IntentType,
    confidence: f64, // 0.0 to 1.0
    keywords_matched: []const []const u8,
    suggested_action: []const u8,
};

/// IntentGate — classifies user messages to route to appropriate handlers
///
/// Uses keyword matching and pattern detection to determine user intent
/// before dispatching to the correct processing pipeline.
pub const IntentGate = struct {
    allocator: std.mem.Allocator,

    // Keyword patterns for each intent type
    implementation_keywords: []const []const u8,
    research_keywords: []const []const u8,
    investigation_keywords: []const []const u8,
    evaluation_keywords: []const []const u8,
    fix_keywords: []const []const u8,

    pub fn init(allocator: std.mem.Allocator) IntentGate {
        return IntentGate{
            .allocator = allocator,
            .implementation_keywords = &.{
                "implement", "add",    "create",   "write",   "build",
                "make",      "set up", "generate", "install", "configure",
            },
            .research_keywords = &.{
                "explain",       "how does", "what is",  "describe",
                "tell me about", "show me",  "docs for", "documentation",
            },
            .investigation_keywords = &.{
                "look into",  "check",    "investigate", "find",
                "search for", "where is", "debug",       "trace",
            },
            .evaluation_keywords = &.{
                "what do you think", "is it good",      "should i",
                "compare",           "which is better", "opinion",
            },
            .fix_keywords = &.{
                "error",       "broken",  "fix",   "crash",   "bug",
                "not working", "failing", "issue", "problem",
            },
        };
    }

    /// Classify a user message into an intent type
    pub fn classify(self: *IntentGate, message: []const u8) IntentResult {
        const lower = self.toLower(message) catch return IntentResult{
            .intent_type = .chat,
            .confidence = 0.5,
            .keywords_matched = &.{},
            .suggested_action = "process as general chat",
        };

        // Score each intent type
        var best_intent: IntentType = .chat;
        var best_score: f64 = 0.0;
        var best_keywords: []const []const u8 = &.{};
        var best_action: []const u8 = "process as general chat";

        // Check fix keywords first (high priority — errors are urgent)
        const fix_score = self.scoreKeywords(lower, self.fix_keywords);
        if (fix_score > best_score) {
            best_intent = .fix;
            best_score = fix_score;
            best_keywords = self.fix_keywords;
            best_action = "diagnose and fix the issue";
        }

        // Check implementation keywords
        const impl_score = self.scoreKeywords(lower, self.implementation_keywords);
        if (impl_score > best_score) {
            best_intent = .implementation;
            best_score = impl_score;
            best_keywords = self.implementation_keywords;
            best_action = "plan and implement the requested feature";
        }

        // Check research keywords
        const research_score = self.scoreKeywords(lower, self.research_keywords);
        if (research_score > best_score) {
            best_intent = .research;
            best_score = research_score;
            best_keywords = self.research_keywords;
            best_action = "research and explain the topic";
        }

        // Check investigation keywords
        const invest_score = self.scoreKeywords(lower, self.investigation_keywords);
        if (invest_score > best_score) {
            best_intent = .investigation;
            best_score = invest_score;
            best_keywords = self.investigation_keywords;
            best_action = "investigate and report findings";
        }

        // Check evaluation keywords
        const eval_score = self.scoreKeywords(lower, self.evaluation_keywords);
        if (eval_score > best_score) {
            best_intent = .evaluation;
            best_score = eval_score;
            best_keywords = self.evaluation_keywords;
            best_action = "evaluate and propose alternatives";
        }

        // Check for open-ended patterns
        if (self.containsAny(lower, &.{ "improve", "refactor", "clean up", "optimize", "enhance" })) {
            const open_score = 0.6;
            if (open_score > best_score) {
                best_intent = .open_ended;
                best_score = open_score;
                best_keywords = &.{ "improve", "refactor", "clean up" };
                best_action = "assess codebase and propose approach";
            }
        }

        // Normalize confidence
        const confidence = @min(best_score, 1.0);

        return IntentResult{
            .intent_type = best_intent,
            .confidence = confidence,
            .keywords_matched = best_keywords,
            .suggested_action = best_action,
        };
    }

    /// Get a human-readable label for an intent type
    pub fn intentLabel(intent: IntentType) []const u8 {
        return switch (intent) {
            .research => "🔍 Research",
            .implementation => "🔨 Implementation",
            .investigation => "🔎 Investigation",
            .evaluation => "⚖️  Evaluation",
            .fix => "🐛 Fix",
            .open_ended => "🔄 Open-ended",
            .chat => "💬 Chat",
        };
    }

    /// Score how many keywords match the message
    fn scoreKeywords(self: *IntentGate, message: []const u8, keywords: []const []const u8) f64 {
        _ = self;
        var matches: u32 = 0;
        for (keywords) |keyword| {
            if (std.mem.indexOf(u8, message, keyword) != null) {
                matches += 1;
            }
        }
        if (keywords.len == 0) return 0.0;
        return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(keywords.len)) * 1.5;
    }

    /// Check if message contains any of the given patterns
    fn containsAny(self: *IntentGate, message: []const u8, patterns: []const []const u8) bool {
        _ = self;
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, message, pattern) != null) return true;
        }
        return false;
    }

    /// Convert string to lowercase (for case-insensitive matching)
    fn toLower(self: *IntentGate, input: []const u8) ![]const u8 {
        const lower = try self.allocator.alloc(u8, input.len);
        for (input, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }
        return lower;
    }

    pub fn deinit(self: *IntentGate) void {
        _ = self;
    }
};
