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
    /// The scroll view's top content inset — the safe area and header the
    /// content passes under. Only carried so `scrollTarget(for:)` can undo
    /// it; nothing else should need it.
    var insetTop: CGFloat = 0

    /// The largest legal `offsetY`. Clamping to this is what stops the
    /// auto-scroll from running past the end of the dashboard and leaving
    /// the dragged tile hovering over nothing.
    var maximumOffsetY: CGFloat { max(contentHeight - viewportHeight, 0) }

    /// An `offsetY` translated into the number `ScrollPosition.scrollTo(y:)`
    /// actually wants.
    ///
    /// **They are not the same coordinate space, and nothing says so.**
    /// `ScrollGeometry.contentOffset` is measured from the top of the
    /// *content area*, inside the insets; `scrollTo(y:)` is measured from
    /// the top of the content itself. On this screen they differ by the
    /// 116pt the header and status bar take, so reading an offset and
    /// writing it straight back moved the dashboard 116pt upwards.
    ///
    /// It never looked like a coordinate bug. The expansion scroll moved,
    /// and moved roughly the right way — it just always stopped one header
    /// short, so an expanded widget sat lower on the screen than asked and
    /// the tallest one (Cashflow) came to rest against the tab bar. Measured
    /// by asking for 652 and watching `contentOffset` settle at 536.
    ///
    /// Every programmatic scroll goes through here, so the two spaces can
    /// only ever be reconciled in one place.
    func scrollTarget(for offsetY: CGFloat) -> CGFloat { offsetY + insetTop }
}

/// Edge auto-scroll while a tile is being dragged.
///
/// Without it a dashboard taller than one screen simply can't be
/// rearranged past the fold: the drag gesture owns the touch, so the user
/// cannot scroll and drag at the same time, and a tile picked up at the top
/// has no way to reach the bottom. This is the other half of the fix for
/// that — the tile now carries the view with it.
extension DashboardCanvasView {
    /// How close to an edge the finger has to get before the dashboard
    /// starts following it. Deliberately larger than a fingertip, so the
    /// scroll begins before the tile is jammed against the bezel — and, now
    /// that speed ramps across it, so there is room to ramp *in*.
    private var autoScrollZone: CGFloat { 110 }

    /// Points per second at the inner edge of the zone and at the bezel.
    ///
    /// A single constant speed is what made this feel out of control: the
    /// view lurched the instant the finger crossed the line, the user
    /// overshot, pulled back, and it stopped dead. Ramping between these two
    /// makes *how far into the zone the finger sits* the speed control — a
    /// crawl for fine positioning near the boundary, a brisk travel speed
    /// held right against the edge — and even the top speed here is well
    /// under half what it used to run at.
    private var autoScrollMinSpeed: CGFloat { 26 }
    private var autoScrollMaxSpeed: CGFloat { 240 }

    /// One display frame, in both the units the loop needs.
    private var autoScrollTick: Duration { .milliseconds(16) }
    private var autoScrollTickSeconds: CGFloat { 0.016 }

    /// Called on every drag change. Sets the speed the view should be
    /// travelling at, from where the finger is on the *canvas* — not in the
    /// grid, whose coordinates move with the content being scrolled.
    func updateAutoScroll(canvasY: CGFloat, geometry: DashboardGeometry) {
        autoScrollVelocity = autoScrollVelocity(atViewportY: canvasY)
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in await runAutoScroll(geometry: geometry) }
    }

    /// Signed points per second: negative scrolls the dashboard up toward
    /// the top, positive down, zero anywhere in the middle of the viewport.
    /// Squared easing, so the near half of the zone is genuinely slow rather
    /// than merely slower — that half is where the user is placing a tile,
    /// not travelling.
    private func autoScrollVelocity(atViewportY viewportY: CGFloat) -> CGFloat {
        let direction: CGFloat
        let depth: CGFloat
        if viewportY < autoScrollZone {
            direction = -1
            depth = autoScrollZone - viewportY
        } else if viewportY > scrollGeometry.viewportHeight - autoScrollZone {
            direction = 1
            depth = viewportY - (scrollGeometry.viewportHeight - autoScrollZone)
        } else {
            return 0
        }
        let ramp = min(max(depth / autoScrollZone, 0), 1)
        return direction * (autoScrollMinSpeed + (autoScrollMaxSpeed - autoScrollMinSpeed) * ramp * ramp)
    }

    /// Steps the offset on a timer rather than reacting to finger movement,
    /// because the case that matters most is a finger held *still* against
    /// the edge — `onChanged` stops firing then, and a movement-driven
    /// scroll would stall exactly when the user is waiting for it.
    ///
    /// Runs for the whole drag — either kind of drag: a tile being moved
    /// around the grid, or a widget arriving from the catalogue, which the
    /// system carries but which still has to be able to reach a row below
    /// the fold. Re-reads `autoScrollVelocity` each tick,
    /// so changing speed or direction — or hitting the end of the content
    /// and coming back off it — needs no restart, and there is no window in
    /// which the finger is in the zone but nothing is ticking.
    ///
    /// Tracks its own `offset` instead of re-reading `scrollGeometry` each
    /// tick: that value arrives asynchronously from `onScrollGeometryChange`
    /// and lags a frame or two behind, so feeding it back in would make the
    /// scroll stutter and drift.
    private func runAutoScroll(geometry: DashboardGeometry) async {
        var offset = scrollGeometry.offsetY
        // `drag` is the loop's real lifetime: every ordinary exit cancels
        // the task, and this catches the one that doesn't — a gesture the
        // system interrupts without an `onEnded`, which would otherwise
        // leave the dashboard scrolling on its own with nothing in hand.
        while !Task.isCancelled, drag != nil || incoming != nil {
            let step = autoScrollVelocity * autoScrollTickSeconds
            let next = min(max(offset + step, 0), scrollGeometry.maximumOffsetY)
            let travelled = next - offset
            offset = next

            // Zero when the finger is nowhere near an edge, and also at the
            // very top or bottom, where there is nothing further to give.
            if travelled != 0 {
                scrollPosition.scrollTo(y: scrollGeometry.scrollTarget(for: offset))
                // The finger hasn't moved, but the grid underneath it has,
                // so its position in grid coordinates changed by exactly
                // what we just scrolled. Without this the drop target would
                // freeze while the dashboard slid past behind the tile.
                if var current = drag {
                    current.location.y += travelled
                    drag = current
                    previewDrop(at: dropCell(for: current, geometry: geometry))
                } else if let point = lastDropPoint {
                    // An arriving widget's location is already in canvas
                    // space, which the scroll doesn't move — but the grid
                    // under it did, and `gridFrame` has just said so, so
                    // re-asking the same point gives a new cell.
                    previewIncoming(at: point, geometry: geometry)
                }
            }
            try? await Task.sleep(for: autoScrollTick)
        }
    }

    func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollVelocity = 0
    }
}
