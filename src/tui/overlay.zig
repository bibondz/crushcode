/// OverlayManager — unified overlay state tracking for the TUI.
///
/// Replaces 6+ ad-hoc boolean fields with a single enum tracking which
/// overlay is currently active. Provides isActive(), setActive(), clear(),
/// and anyActive() for centralized overlay management.
const std = @import("std");

/// All possible overlay types in the TUI.
pub const OverlayType = enum {
    palette,
    session_list,
    help,
    diff_preview,
    permission_prompt,
    setup,
};

/// Manages overlay state — at most one overlay active at a time.
pub const OverlayManager = struct {
    active: ?OverlayType = null,

    /// Returns true if any overlay is currently active.
    pub fn anyActive(self: *const OverlayManager) bool {
        return self.active != null;
    }

    /// Returns true if the specified overlay type is currently active.
    pub fn isActive(self: *const OverlayManager, overlay: OverlayType) bool {
        return self.active == overlay;
    }

    /// Activate the specified overlay, deactivating any previous one.
    pub fn setActive(self: *OverlayManager, overlay: OverlayType) void {
        self.active = overlay;
    }

    /// Deactivate the specified overlay. If a different overlay is active, does nothing.
    pub fn clearOne(self: *OverlayManager, overlay: OverlayType) void {
        if (self.active == overlay) {
            self.active = null;
        }
    }

    /// Deactivate whatever overlay is currently active.
    pub fn clear(self: *OverlayManager) void {
        self.active = null;
    }

    /// Toggle the specified overlay on/off.
    pub fn toggle(self: *OverlayManager, overlay: OverlayType) void {
        if (self.active == overlay) {
            self.active = null;
        } else {
            self.active = overlay;
        }
    }
};
