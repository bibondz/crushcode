const std = @import("std");
const file_compat = @import("file_compat");

/// Output intensity level — controls verbosity of AI responses
///
/// Inspired by Caveman's compression modes:
/// - lite: drops filler words, keeps grammar → ~40% token savings
/// - normal: standard output (default)
/// - full: caveman fragments, drops articles/prepositions → ~65% savings
/// - ultra: maximum compression, arrows for causality → ~75% savings
///
/// Reference: caveman skills/caveman/SKILL.md
pub const Intensity = enum {
    lite,
    normal,
    full,
    ultra,

    /// Parse from CLI string
    pub fn parse(s: []const u8) ?Intensity {
        if (std.mem.eql(u8, s, "lite") or std.mem.eql(u8, s, "1")) return .lite;
        if (std.mem.eql(u8, s, "normal") or std.mem.eql(u8, s, "default") or std.mem.eql(u8, s, "0")) return .normal;
        if (std.mem.eql(u8, s, "full") or std.mem.eql(u8, s, "2")) return .full;
        if (std.mem.eql(u8, s, "ultra") or std.mem.eql(u8, s, "3")) return .ultra;
        return null;
    }

    /// Get system prompt modifier for the AI
    /// This is appended to the system prompt to control output verbosity
    pub fn systemPromptMod(self: Intensity) []const u8 {
        return switch (self) {
            .lite => "Respond concisely. Remove filler words and hedging phrases. Keep technical accuracy.",
            .normal => "",
            .full => "Respond in compressed format. Drop articles (a, an, the) and filler. Use fragments. Keep technical precision. Example: 'Func validates input, returns error on null' instead of 'The function validates the input and returns an error when the value is null'.",
            .ultra => "Maximum compression. Use symbols: → for causality, | for alternatives, & for conjunction. Drop all filler. Example: 'validate input → error on null | default to empty'. Use imperative mood only.",
        };
    }

    /// Get human-readable name
    pub fn label(self: Intensity) []const u8 {
        return switch (self) {
            .lite => "lite (~40% reduction)",
            .normal => "normal",
            .full => "full (~65% reduction)",
            .ultra => "ultra (~75% reduction)",
        };
    }
};

/// Print intensity level info
pub fn printIntensityHelp() void {
    const stdout = file_compat.File.stdout().writer();
    stdout.print("Output Intensity Levels:\n", .{}) catch {};
    stdout.print("  lite    - Concise, drops filler (~40% token savings)\n", .{}) catch {};
    stdout.print("  normal  - Standard output (default)\n", .{}) catch {};
    stdout.print("  full    - Compressed fragments (~65% savings)\n", .{}) catch {};
    stdout.print("  ultra   - Maximum compression (~75% savings)\n", .{}) catch {};
    stdout.print("\nUsage: crushcode chat --intensity ultra \"fix the bug\"\n", .{}) catch {};
}
