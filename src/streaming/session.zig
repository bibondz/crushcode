const std = @import("std");
const types = @import("types");
const buffer_mod = @import("buffer");
const display_mod = @import("display");
const ndjson_mod = @import("ndjson_mod");
const sse_mod = @import("sse_mod");

const StreamEvent = types.StreamEvent;
const StreamFormat = types.StreamFormat;
const StreamOptions = types.StreamOptions;
const TokenUsage = types.TokenUsage;
const StreamDone = types.StreamDone;
const StreamError = types.StreamError;

/// State of a streaming session
pub const SessionState = enum {
    pending,
    streaming,
    paused,
    completed,
    cancelled,
    failed,
};

/// Result of a completed streaming session
pub const StreamResult = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    finish_reason: []const u8,
    usage: ?TokenUsage,
    token_count: u32,
    duration_ms: u64,

    pub fn deinit(self: *StreamResult) void {
        self.allocator.free(self.content);
        self.allocator.free(self.finish_reason);
    }
};

/// Parser backend selection
const ParserBackend = union(enum) {
    ndjson: ndjson_mod.NDJsonParser,
    sse: sse_mod.SSEParser,
};

/// Unified streaming session across all AI providers
///
/// Usage:
///   var session = try StreamingSession.init(allocator, provider, model, options);
///   defer session.deinit();
///   try session.start(request_body);
///   const result = try session.waitForCompletion();
///   defer result.deinit();
pub const StreamingSession = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    state: SessionState,
    options: StreamOptions,

    // Response accumulation
    response_buffer: buffer_mod.ResponseBuffer,

    // Terminal display
    display: display_mod.StreamDisplay,

    // Parser backend
    parser: ParserBackend,

    // Timing
    start_time: i64,
    end_time: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        options: StreamOptions,
    ) !StreamingSession {
        const format = types.detectStreamFormat(provider);

        return StreamingSession{
            .allocator = allocator,
            .provider = provider,
            .model = model,
            .state = .pending,
            .options = options,
            .response_buffer = buffer_mod.ResponseBuffer.init(allocator),
            .display = display_mod.StreamDisplay.init(allocator, options.show_thinking),
            .parser = switch (format) {
                .ndjson => .{ .ndjson = ndjson_mod.NDJsonParser.init(allocator) },
                .sse => .{ .sse = sse_mod.SSEParser.init(allocator) },
                .jsonrpc => .{ .ndjson = ndjson_mod.NDJsonParser.init(allocator) }, // JSON-RPC falls back to NDJSON
            },
            .start_time = 0,
            .end_time = 0,
        };
    }

    /// Process a raw HTTP chunk through the parser and emit events
    pub fn processChunk(self: *StreamingSession, chunk: []const u8) !void {
        if (self.state == .cancelled) return;

        self.state = .streaming;

        // Parse chunk through provider-specific parser
        const events = switch (self.parser) {
            .ndjson => |*parser| try parser.parse(chunk),
            .sse => |*parser| try parser.parse(chunk),
        };

        // Process each event
        for (events) |event| {
            // Accumulate into buffer
            self.response_buffer.processEvent(event);

            // Display to terminal if enabled
            if (self.options.display_tokens) {
                self.display.displayEvent(event);
            }

            // Call user callback if set
            if (self.options.on_event) |callback| {
                callback(event);
            }

            // Check for completion
            if (event.event_type == .done) {
                self.state = .completed;
                self.end_time = std.time.milliTimestamp();
            }
            if (event.event_type == .stream_error) {
                self.state = .failed;
                self.end_time = std.time.milliTimestamp();
            }
        }

        self.allocator.free(events);
    }

    /// Mark the session as started
    pub fn start(self: *StreamingSession) void {
        self.state = .streaming;
        self.start_time = std.time.milliTimestamp();
        if (self.options.display_tokens) {
            self.display.printHeader(self.provider, self.model);
        }
    }

    /// Cancel the streaming session
    pub fn cancel(self: *StreamingSession) void {
        self.state = .cancelled;
        self.end_time = std.time.milliTimestamp();
    }

    /// Get the full accumulated response content
    pub fn getFullContent(self: *StreamingSession) []const u8 {
        return self.response_buffer.getFullContent();
    }

    /// Get the current session state
    pub fn getState(self: *StreamingSession) SessionState {
        return self.state;
    }

    /// Get token count accumulated so far
    pub fn getTokenCount(self: *StreamingSession) u32 {
        return self.response_buffer.token_count;
    }

    /// Check if session is complete (done or failed)
    pub fn isComplete(self: *StreamingSession) bool {
        return self.state == .completed or self.state == .failed or self.state == .cancelled;
    }

    /// Check if session had an error
    pub fn hasError(self: *StreamingSession) bool {
        return self.state == .failed;
    }

    /// Get the error message if any
    pub fn getError(self: *StreamingSession) ?StreamError {
        return self.response_buffer.stream_error;
    }

    /// Build a final result from the session (call after completion)
    pub fn buildResult(self: *StreamingSession) !StreamResult {
        const content = try self.allocator.dupe(u8, self.response_buffer.getFullContent());
        const finish_reason = try self.allocator.dupe(u8, self.response_buffer.finish_reason orelse "stop");

        var duration_ms: u64 = 0;
        if (self.end_time > self.start_time) {
            duration_ms = @intCast(self.end_time - self.start_time);
        }

        return StreamResult{
            .allocator = self.allocator,
            .content = content,
            .finish_reason = finish_reason,
            .usage = self.response_buffer.usage,
            .token_count = self.response_buffer.token_count,
            .duration_ms = duration_ms,
        };
    }

    pub fn deinit(self: *StreamingSession) void {
        self.response_buffer.deinit();
        switch (self.parser) {
            .ndjson => |*parser| parser.deinit(),
            .sse => |*parser| parser.deinit(),
        }
    }
};
