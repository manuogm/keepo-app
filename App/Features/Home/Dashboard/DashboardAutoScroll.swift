import KeepoCore
import SwiftUI

/// What the dashboard's scroll view currently looks like, sampled through
/// `onScrollGeometryChange`. Auto-scroll needs all three: where we are, how
/// much viewport there is to decide "near the edge", and where the content
/// ends so a drag at the bottom doesn't scroll into empty space.
struct DashboardScrollGeometry: Equatable {
    var offsetY: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    /// The largest legal `offsetY`. Clamping to this is what stops the
    /// auto-scroll from running past the end of the dashboard and leaving
    /// the dragged tile hovering over nothing.
    var maximumOffsetY: CGFloat { max(contentHeight - viewportHeight, 0) }
}

/// Edge auto-scroll while a tile is being dragged.
///
/// Without it a dashboard taller than one screen simply can't be
/// rearranged past the fold: the drag gesture owns the touch, so the user
/// cannot scroll and drag at the same time, and a tile picked up at the top
/// has no way to reach the bottom. This is the other half of the fix for
/// that — the tile now carries the view with it.
extension DashboardCanvasView {
    /// How close to an edge the finger has to get, and how fast the view
    /// follows. The zone is deliberately larger than a fingertip so the
    /// scroll starts before the tile is jammed against the bezel.
    private var autoScrollZone: CGFloat { 96 }
    private var autoScrollStep: CGFloat { 7 }

    /// Called on every drag change. Starts, redirects, or stops the scroll
    /// depending on where the finger is in the *viewport* — not in the grid,
    /// whose coordinates move with the content being scrolled.
    func updateAutoScroll(gridY: CGFloat, geometry: DashboardGeometry) {
        let viewportY = gridY - scrollGeometry.offsetY
        let direction: CGFloat

        if viewportY < autoScrollZone {
            direction = -1
        } else if viewportY > scrollGeometry.viewportHeight - autoScrollZone {
            direction = 1
        } else {
            direction = 0
        }

        guard direction != autoScrollDirection else { return }
        autoScrollDirection = direction
        autoScrollTask?.cancel()
        guard direction != 0 else {
            autoScrollTask = nil
            return
        }
        autoScrollTask = Task { @MainActor in
            await runAutoScroll(direction: direction, geometry: geometry)
        }
    }

    /// Steps the offset on a timer rather than reacting to finger movement,
    /// because the case that matters most is a finger held *still* against
    /// the edge — `onChanged` stops firing then, and a movement-driven
    /// scroll would stall exactly when the user is waiting for it.
    ///
    /// Tracks its own `offset` instead of re-reading `scrollGeometry` each
    /// tick: that value arrives asynchronously from `onScrollGeometryChange`
    /// and lags a frame or two behind, so feeding it back in would make the
    /// scroll stutter and drift.
    private func runAutoScroll(direction: CGFloat, geometry: DashboardGeometry) async {
        var offset = scrollGeometry.offsetY
        while !Task.isCancelled {
            let next = min(max(offset + direction * autoScrollStep, 0), scrollGeometry.maximumOffsetY)
            let travelled = next - offset
            // Hit the top or the bottom — nothing further to give.
            guard abs(travelled) > 0.5 else { break }
            offset = next
            scrollPosition.scrollTo(y: offset)

            // The finger hasn't moved, but the grid underneath it has, so its
            // position in grid coordinates changed by exactly what we just
            // scrolled. Without this the drop target would freeze while the
            // dashboard slid past behind the tile.
            if var current = drag {
                current.location.y += travelled
                drag = current
                updatePreview(for: current.id, at: current.location, geometry: geometry)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollDirection = 0
    }
}
