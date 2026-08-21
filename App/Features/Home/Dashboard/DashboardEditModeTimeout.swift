import SwiftUI

/// Edit mode leaves on its own after a stretch of no activity.
///
/// Jiggling tiles are a *mode*, and a mode the user forgot they were in is
/// a trap — the next tap does nothing, or removes a widget. Every real
/// interaction (a drag, a removal, an addition) restarts the clock, so this
/// only ever fires on a dashboard genuinely left alone.
extension DashboardCanvasView {
    /// Long enough to look at the dashboard and decide what to move, short
    /// enough that walking away leaves it tidy. Tuned by feel, not derived
    /// from anything.
    private var editModeIdleSeconds: Int { 15 }

    /// Restarts the idle clock. Safe to call on every interaction — it
    /// cancels the previous timer rather than stacking them up.
    func bumpEditModeTimeout() {
        editModeTimeoutTask?.cancel()
        guard isEditing else {
            editModeTimeoutTask = nil
            return
        }
        editModeTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(editModeIdleSeconds))
            // A drag still in progress is activity even though nothing has
            // landed yet — dropping out of edit mode mid-gesture would strand
            // a tile under the finger.
            guard !Task.isCancelled, isEditing, drag == nil else { return }
            withAnimation(.snappy(duration: 0.24)) { isEditing = false }
        }
    }

    func cancelEditModeTimeout() {
        editModeTimeoutTask?.cancel()
        editModeTimeoutTask = nil
    }
}
