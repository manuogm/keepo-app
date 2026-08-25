import KeepoCore
import SwiftUI
import UniformTypeIdentifiers

/// The widget catalogue's presentation, and everything that happens to a
/// widget dragged out of it. Split from `DashboardCanvasView` to keep that
/// file under the project's length lint — the canvas owns the grid and the
/// tiles already on it; this owns arrival.
extension DashboardCanvasView {

    /// A widget on its way in from the catalogue. Its id is minted once, on
    /// arrival, so the tile previewed under the finger and the tile finally
    /// stored are the same object — rather than one being swapped for the
    /// other on drop, which would re-animate it in from nowhere.
    struct DashboardIncomingWidget: Equatable {
        let kind: DashboardWidgetKind
        let id = UUID()
    }

    // MARK: - Catalogue

    @ViewBuilder
    var catalogueBackdrop: some View {
        if isPickingWidget {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { isPickingWidget = false }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    func cataloguePanel(_ geometry: DashboardGeometry, viewportHeight: CGFloat) -> some View {
        if isPickingWidget {
            DashboardCatalogView(
                geometry: geometry,
                maxHeight: max(viewportHeight * 0.72, 280),
                unavailable: unavailableWidgets,
                onSelect: { kind in
                    isPickingWidget = false
                    add(kind)
                },
                onClose: { isPickingWidget = false },
                onLift: { kind in liftedKind = kind }
            )
            .ignoresSafeArea(edges: .bottom)
            .transition(.move(edge: .bottom))
        }
    }

    /// Why each widget can't be added right now.
    ///
    /// Two reasons, and they are deliberately different sentences. "Already
    /// on your dashboard" is a rule — one of each, until user-built template
    /// widgets make each configuration its own kind and the rule stops
    /// applying. The others are missing *data*, and each says what to do
    /// about it, because "FX Rate is unavailable" tells a user nothing they
    /// can act on.
    var unavailableWidgets: [DashboardWidgetKind: String] {
        var reasons: [DashboardWidgetKind: String] = [:]
        for kind in DashboardWidgetKind.allCases {
            if store.arrangement.contains(kind: kind) {
                reasons[kind] = "Already on your dashboard."
            } else if let reason = data.capabilities?.unavailability(for: kind) {
                reasons[kind] = reason
            }
        }
        return reasons
    }

    // MARK: - The bar under the grid

    /// One slot under the grid, showing whichever end of an *add* the user
    /// is currently at: the way into the catalogue, or — while a widget is
    /// being carried — the way to change your mind about it.
    ///
    /// One control rather than two, at one size, and that is load-bearing.
    /// A trash bar that appeared *beside* the add button, or under it, would
    /// grow the content and slide the grid out from under a finger that is
    /// mid-drag; swapping in place is the only version whose arrival moves
    /// nothing. It is also the honest shape of the interaction — you cannot
    /// be adding and discarding at the same time.
    @ViewBuilder
    func bottomSlot(_ geometry: DashboardGeometry) -> some View {
        let size = geometry.size(rows: 1, columns: DashboardLayout.columnCount)
        Group {
            if incoming != nil {
                DashboardTrashSlot(isTargeted: isOverTrash)
                    .transition(.opacity)
            } else {
                AddWidgetTile { isPickingWidget = true }
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.18), value: incoming == nil)
        // Measured in canvas space, like the grid, because that is the space
        // the drop delegate reports finger positions in.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(DashboardSpace.canvas))
        } action: { frame in
            trashFrame = frame
        }
    }

    /// Empty space held open under the grid while a widget is in hand.
    ///
    /// The bar below the grid is the drag's one escape hatch, and it sits at
    /// the end of the scrolling content — so it moves whenever the content's
    /// height does. It does: previewing the widget into the last row makes
    /// the grid a whole widget taller, previewing it into a hole makes it no
    /// taller at all, and the finger travelling between those two answers
    /// watched the bar slide up and down under it. Instrumented, a finger
    /// holding still on the trash lost it entirely that way.
    ///
    /// So the content is held at the height it would have at its *tallest* —
    /// the widget's own height, less however much of it the preview is
    /// already using — and the difference is reserved as empty space. The
    /// grid still reflows freely under the drag; the bar simply stops
    /// hearing about it.
    func carriedReserve(_ geometry: DashboardGeometry) -> CGFloat {
        guard let incoming else { return 0 }
        let grown = layout.rowCount - store.arrangement.rowCount
        let rows = max(incoming.kind.baseSize.rows - grown, 0)
        guard rows > 0 else { return 0 }
        return geometry.height(rows: rows) + geometry.spacing
    }

    // MARK: - Dropping in from the catalogue

    /// The dashboard as a drop target. Reflows live under the drag, using
    /// the same preview arrangement a tile already on the grid uses while
    /// being moved, so arriving and rearranging look like one mechanism.
    ///
    /// The target is the **whole canvas**, not the grid, and that is not a
    /// generosity about where you may let go. Attached to the grid — even
    /// with every content type accepted — the delegate was never consulted
    /// at all: not `validateDrop`, not `dropEntered`, nothing. Moved out to
    /// the canvas, the identical delegate receives the session immediately.
    /// Measured, twice, before believing it. The cost is that locations
    /// arrive in the canvas's space rather than the grid's, which
    /// `gridPoint(_:)` undoes.
    func widgetDrop(_ geometry: DashboardGeometry) -> some DropDelegate {
        DashboardWidgetDrop(
            arrived: beginArrival,
            moved: { point in previewIncoming(at: point, geometry: geometry) },
            exited: clearDrag,
            dropped: {
                guard incoming != nil else { return false }
                // Accepted, not refused, even though nothing is added: a
                // refused drop flies the carried preview back to its source,
                // and the catalogue it came from is no longer on screen. The
                // widget should die where it was dropped.
                guard !isOverTrash else {
                    discardArrival()
                    return true
                }
                guard previewCell != nil else { return false }
                drop()
                return true
            }
        )
    }

    /// A widget has reached the dashboard. Mints the arriving tile from the
    /// kind the catalogue noted on lift-off, and gets the catalogue out of
    /// the way — the widget is in the window's hands rather than the panel's
    /// (the whole reason the drag out is a system session), so dismissing it
    /// leaves what the user is carrying untouched.
    ///
    /// The kind cannot come from the drag payload, tempting as that is: a
    /// drop session releases its item data only in `performDrop`, and the
    /// grid has to reflow around the widget long before then. Loading it
    /// here simply never calls back.
    private func beginArrival() {
        guard incoming == nil, let liftedKind else { return }
        incoming = DashboardIncomingWidget(kind: liftedKind)
        isPickingWidget = false
        beginEditing()
    }

    /// The cell the **finger** is over — not a corner derived from it.
    ///
    /// This used to assume the carried preview was centred on the touch and
    /// work back to the tile's top-left corner from there. It isn't: a drag
    /// session lifts the preview under the point you actually pressed, so a
    /// widget grabbed near its left edge is carried to the right of the
    /// finger, and the slot came out a column to the left of where the user
    /// was plainly pointing. Only on square widgets, because a full-width
    /// one clamps to column 0 and hid the bug. The finger is the one anchor
    /// that means the same thing however the widget was picked up.
    func previewIncoming(at point: CGPoint, geometry: DashboardGeometry) {
        guard incoming != nil else { return }
        lastDropPoint = point
        updateAutoScroll(canvasY: point.y, geometry: geometry)
        isOverTrash = isAimedAtTrash(point, geometry: geometry)
        // Over the trash the preview deliberately **freezes** rather than
        // being torn down. Removing the landing slot would shorten the grid,
        // slide the trash bar up out from under the finger, put the slot
        // straight back, and slide the bar down again — a flicker loop at
        // 60Hz, because the hit test and the thing it tests against would be
        // feeding each other. The layout holds still and the slot fades
        // instead (see `tile(_:geometry:)`).
        guard !isOverTrash else { return }
        previewDrop(at: geometry.cell(containing: gridPoint(point)))
    }

    /// Whether a point is aimed at the trash, in canvas space.
    ///
    /// Not `trashFrame.contains(point)`, for a measured reason: the bar is
    /// the last thing in the scrolling content, so every preview that changes
    /// the grid's height slides it — a whole row at a time — under a finger
    /// that has not moved. Instrumented, a finger resting on the bar watched
    /// its bottom edge climb past it and cancel its own target.
    ///
    /// The region is therefore deliberately lopsided. It runs a row past the
    /// bar below and to the sides, which is nothing but padding and is where
    /// an overshooting finger lands anyway; and, only once the trash is
    /// already the target, a little past the top edge as well, so that
    /// leaving takes a deliberate move rather than a slide. On approach it
    /// never reaches above the bar: that strip is where "put it at the end of
    /// the dashboard" lands, and the trash has no claim on it.
    private func isAimedAtTrash(_ point: CGPoint, geometry: DashboardGeometry) -> Bool {
        guard trashFrame != .zero else { return false }
        let overshoot = geometry.rowHeight
        let slack = isOverTrash ? geometry.spacing * 2 : 0
        return CGRect(
            x: trashFrame.minX - overshoot,
            y: trashFrame.minY - slack,
            width: trashFrame.width + overshoot * 2,
            height: trashFrame.height + slack + overshoot
        ).contains(point)
    }

    /// Dropped on the trash: the widget is simply never added.
    ///
    /// Nothing has to be undone, and that is the point of previewing a drag
    /// against a copy of the arrangement — the store was never written to,
    /// so cancelling is throwing the preview away rather than reversing a
    /// change the user watched happen.
    func discardArrival() {
        withAnimation(.snappy(duration: 0.3)) {
            clearDrag()
            // Cancelling the first widget onto an empty dashboard leaves
            // nothing to arrange, so edit mode ends with it — the same rule
            // removing the last widget follows.
            if store.arrangement.isEmpty { isEditing = false }
        }
        bumpEditModeTimeout()
    }

    /// Canvas space → grid space, through the grid's own measured frame
    /// rather than by re-deriving the padding and scroll offset that
    /// separate them. Those are numbers that would then have to keep
    /// agreeing with `grid(_:)` forever; the frame simply reports itself.
    private func gridPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - gridFrame.minX, y: point.y - gridFrame.minY)
    }
}

/// Live tracking for a drag coming in from the catalogue.
///
/// `DropDelegate` rather than the newer `dropDestination(for:action:)`
/// because only this one reports **where** the finger is while it moves
/// (`dropUpdated`). The newer API offers a location on the drop and a bare
/// "is it over me" flag before that, which cannot drive a grid reflowing
/// under the widget as it travels.
struct DashboardWidgetDrop: DropDelegate {
    let arrived: () -> Void
    let moved: (CGPoint) -> Void
    let exited: () -> Void
    let dropped: () -> Bool

    func dropEntered(info: DropInfo) {
        arrived()
        moved(info.location)
    }

    /// `.copy`, and deliberately: the operation is what UIKit badges the
    /// carried preview with, and the green plus it draws for a copy is the
    /// counterpart to edit mode's red minus — one says a widget is arriving,
    /// the other that one is leaving. `.move` would drop the badge entirely.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        moved(info.location)
        return DropProposal(operation: .copy)
    }

    /// Leaving the dashboard takes the preview with it, so the grid is not
    /// left reflowed around a widget the user has carried off somewhere
    /// else — and a drag abandoned outside never needs a cancel hook the
    /// delegate does not have.
    func dropExited(info: DropInfo) { exited() }

    func performDrop(info: DropInfo) -> Bool { dropped() }
}
