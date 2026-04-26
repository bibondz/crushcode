const std = @import("std");
const span_mod = @import("span.zig");

const Span = span_mod.Span;
const Trace = span_mod.Trace;

/// Thread-local active trace for the current request chain
threadlocal var active_trace: ?*Trace = null;

/// Thread-local active span for nested span creation
threadlocal var active_span: ?*Span = null;

/// Set the current active trace (null to clear)
pub fn setCurrentTrace(trace: ?*Trace) void {
    active_trace = trace;
}

/// Get the current active trace, or null if none is set
pub fn currentTrace() ?*Trace {
    return active_trace;
}

/// Get the current active span, or null if none is set
pub fn currentSpan() ?*Span {
    return active_span;
}

/// Set the current active span (null to clear)
pub fn setCurrentSpan(s: ?*Span) void {
    active_span = s;
}
