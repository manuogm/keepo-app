import KeepoCore
import SwiftUI

/// Picking a tile up, carrying it, and putting it down — every step of a
/// drag on the dashboard, for a tile already on the grid and for one
/// arriving from the catalogue alike. Split from `DashboardCanvasView` to
/// keep that file under the project's length lint; it is one mechanism, and
/// this is all of it.
extension DashboardCanvasView {
    /// Edit mode's drag. The brief press in front of it is what separates
    /// "pick this tile up" from "flick the list" once scrolling and dragging
    /// are both live on the same surface.
    ///
    /// It is the **distance** tolerance doing that work, not the duration.
    /// A `LongPressGesture` at its default 10pt tolerance fails the moment
    /// the finger slides, so picking a tile up meant pressing *and holding
    /// still* first — the thing that made edit mode feel sticky. Allowing
    /// 40pt of travel inside the window means an ordinary grab-and-move
    /// succeeds straight away, while a flick — which covers far more than
    /// that in a tenth of a second — still fails out to the scroll view.
    func pressAndDrag(_ tile: DashboardResolvedTile, geometry: DashboardGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.1, maximumDistance: 40)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(DashboardSpace.grid)))
            .onChanged { value in
                guard case .second(true, let movement?) = value else { return }
                // The grab offset is measured once, against the tile's
                // position before anything reflowed — recomputing it each
                // frame would chase the preview and drift.
                let grabOffset = drag?.grabOffset ?? grabOffset(
                    for: tile, startLocation: movement.startLocation, geometry: geometry
                )
                let lifted = DashboardDragState(
                    id: tile.id, location: movement.location, grabOffset: grabOffset
                )
                drag = lifted
                previewDrop(at: dropCell(for: lifted, geometry: geometry))
                updateAutoScroll(canvasY: gridFrame.minY + movement.location.y, geometry: geometry)
            }
            .onEnded { _ in drop() }
    }

    private func grabOffset(
        for tile: DashboardResolvedTile, startLocation: CGPoint, geometry: DashboardGeometry
    ) -> CGSize {
        let origin = geometry.origin(row: tile.row, column: tile.column)
        return CGSize(width: startLocation.x - origin.x, height: startLocation.y - origin.y)
    }

    /// How far to shift the dragged tile from wherever the layout has just
    /// put it, so it stays pinned under the finger.
    func dragOffset(for tile: DashboardResolvedTile, geometry: DashboardGeometry) -> CGSize {
        guard let drag, drag.id == tile.id else { return .zero }
        let origin = geometry.origin(row: tile.row, column: tile.column)
        return CGSize(
            width: drag.location.x - drag.grabOffset.width - origin.x,
            height: drag.location.y - drag.grabOffset.height - origin.y
        )
    }

    /// Where a drag would land: the **tile's own top-left corner**, snapped
    /// to the nearest cell. Not the finger's cell — see
    /// `DashboardGeometry.cell(originAt:)` for why that distinction is the
    /// difference between a tile landing where it looks like it will and
    /// landing a row off, depending on where it happened to be grabbed.
    func dropCell(for drag: DashboardDragState, geometry: DashboardGeometry) -> DashboardGridCell {
        geometry.cell(originAt: CGPoint(
            x: drag.location.x - drag.grabOffset.width,
            y: drag.location.y - drag.grabOffset.height
        ))
    }

    /// Rebuilds the would-be arrangement as the finger moves, but only when
    /// the drop target actually changes — rebuilding per frame would restart
    /// the reflow animation on every touch event and leave the grid
    /// permanently mid-transition.
    ///
    /// One entry point for both kinds of drag: a tile already on the
    /// dashboard *moves*, a widget arriving from the catalogue *inserts*
    /// (two genuinely different rules — see `DashboardArrangement.insert`).
    /// Everything either side of that one line is shared, so arriving and
    /// rearranging can never drift into behaving differently.
    func previewDrop(at target: DashboardGridCell) {
        // Aiming below the dashboard is aiming at nothing: every row past
        // the last occupied one is empty, and normalization closes empty
        // rows, so the tile would silently land far above the finger and
        // stop tracking it. Clamping to one row past the end means the
        // deepest cell you can aim at is the deepest one that survives.
        let cell = DashboardGridCell(
            row: min(target.row, store.arrangement.rowCount), column: target.column
        )
        guard cell != previewCell else { return }
        var preview = store.arrangement
        if let incoming {
            preview.insert(kind: incoming.kind, id: incoming.id, atRow: cell.row, column: cell.column)
        } else if let drag {
            preview.move(id: drag.id, toRow: cell.row, column: cell.column)
        } else {
            return
        }
        previewCell = cell
        withAnimation(.snappy(duration: 0.25)) { dragPreview = preview }
    }

    /// Commits whatever is in hand at the cell the preview last settled on.
    /// Everything on screen is already in its final position — the preview
    /// put it there while the finger was still down — so this only makes it
    /// real and drops the tile back into the grid from under the finger.
    func drop() {
        guard let cell = previewCell else {
            clearDrag()
            return
        }
        withAnimation(.snappy(duration: 0.3)) {
            if let incoming {
                store.insert(kind: incoming.kind, id: incoming.id, atRow: cell.row, column: cell.column)
            } else if let drag {
                store.move(id: drag.id, toRow: cell.row, column: cell.column)
            }
            clearDrag()
        }
        bumpEditModeTimeout()
    }

    func clearDrag() {
        stopAutoScroll()
        drag = nil
        dragPreview = nil
        previewCell = nil
        incoming = nil
        lastDropPoint = nil
        isOverTrash = false
    }
}
