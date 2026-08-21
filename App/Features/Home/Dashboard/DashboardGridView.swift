import KeepoCore
import SwiftUI

/// The dashboard's two coordinate spaces, named once so nothing has to
/// guess which one a point is in.
///
/// They are genuinely different and both are needed: a tile drag reports its
/// location inside the **grid**, which scrolls with the content, while a drop
/// coming in from the catalogue reports its location on the **canvas**, which
/// does not. `DashboardCanvasView.gridFrame` is the bridge between them.
enum DashboardSpace {
    static let grid = "dashboardGrid"
    static let canvas = "dashboardCanvas"
}

/// A cell the finger is over. A named `Equatable` type rather than the
/// `(row:column:)` tuple this used to return: the drag needs to hold "the
/// cell the preview was last built for" in an `Optional` and compare it
/// frame to frame, and Swift tuples are not `Equatable`, so they cannot be
/// compared through an `Optional` at all.
struct DashboardGridCell: Equatable {
    let row: Int
    let column: Int
}

/// Cell arithmetic for the dashboard grid — the only place points and grid
/// coordinates are converted into one another, in either direction.
/// `cell(originAt:)` is the inverse of `origin(row:column:)`, and edit-mode
/// drags depend on that being literally true rather than approximately true.
struct DashboardGeometry: Equatable {
    /// A column's width.
    let cellSize: CGFloat
    /// One grid row — **half a widget**, less the gap two of them absorb
    /// between. Sized this way, `DashboardLayout.rowsPerWidget` rows measure
    /// exactly `cellSize`, so every widget kept the square it had before the
    /// row was split and only a one-row tile (a spacer) can be shorter.
    let rowHeight: CGFloat
    let spacing: CGFloat

    init(availableWidth: CGFloat, spacing: CGFloat = 12) {
        self.spacing = spacing
        let columns = CGFloat(DashboardLayout.columnCount)
        let width = max((availableWidth - spacing * (columns - 1)) / columns, 1)
        let rows = CGFloat(DashboardLayout.rowsPerWidget)
        self.cellSize = width
        self.rowHeight = max((width - spacing * (rows - 1)) / rows, 1)
    }

    private var columnStride: CGFloat { cellSize + spacing }
    private var rowStride: CGFloat { rowHeight + spacing }

    /// Spanning tiles absorb the gaps they cover, so a 2-wide tile is wider
    /// than two cells by exactly one spacing — otherwise a full-width tile
    /// would sit narrower than the two tiles above it.
    private func extent(_ count: Int, unit: CGFloat) -> CGFloat {
        CGFloat(count) * unit + CGFloat(max(count - 1, 0)) * spacing
    }

    func size(rows: Int, columns: Int) -> CGSize {
        CGSize(width: extent(columns, unit: cellSize), height: extent(rows, unit: rowHeight))
    }

    func origin(row: Int, column: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * columnStride, y: CGFloat(row) * rowStride)
    }

    func height(rows: Int) -> CGFloat { extent(rows, unit: rowHeight) }

    /// The cell a point falls inside, clamped into the grid. Used to target
    /// a drop from the finger itself, where a corner cannot be derived —
    /// see `previewIncoming(at:geometry:)`.
    func cell(containing point: CGPoint) -> DashboardGridCell {
        DashboardGridCell(
            row: max(Int((point.y / rowStride).rounded(.down)), 0),
            column: min(max(Int((point.x / columnStride).rounded(.down)), 0), DashboardLayout.columnCount - 1)
        )
    }

    /// The cell a dragged tile's **top-left corner** snaps to, clamped into
    /// the grid — the drop target `DashboardArrangement.move` expects.
    ///
    /// Deliberately the corner and not the finger. A widget covers two rows
    /// now, so "the cell the finger is in" answers differently depending on
    /// which half of the tile the user happened to grab, and a tile picked
    /// up by its bottom edge would drop a row below where it is plainly
    /// sitting. Rounding the corner to the nearest cell instead means the
    /// tile lands where it looks like it will, whatever the grip.
    func cell(originAt point: CGPoint) -> DashboardGridCell {
        DashboardGridCell(
            row: max(Int((point.y / rowStride).rounded()), 0),
            column: min(max(Int((point.x / columnStride).rounded()), 0), DashboardLayout.columnCount - 1)
        )
    }
}

/// Draws a resolved layout. Deliberately dumb: it knows where tiles go and
/// nothing about what they contain or why they moved — the caller supplies
/// the content, `DashboardArrangement` supplies the positions.
///
/// A `ZStack` with explicit frames and offsets, not a `LazyVGrid`: the grid
/// containers can't express a row span, and more importantly they give no
/// stable rects to hit-test a drag against. Every position here is a plain
/// number, so expansion and reorder animate by interpolating it.
struct DashboardGridView<TileContent: View>: View {
    let layout: DashboardResolvedLayout
    let geometry: DashboardGeometry
    @ViewBuilder let tile: (DashboardResolvedTile) -> TileContent

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.tiles) { resolved in
                let size = geometry.size(rows: resolved.size.rows, columns: resolved.size.columns)
                let origin = geometry.origin(row: resolved.row, column: resolved.column)
                tile(resolved)
                    .frame(width: size.width, height: size.height)
                    .offset(x: origin.x + displacement(of: resolved), y: origin.y)
                    .opacity(resolved.isDisplaced ? 0 : 1)
                    // The expanding tile draws over its displaced neighbour
                    // on the way out, never under it.
                    .zIndex(resolved.isDisplaced ? 0 : 1)
            }
        }
        .frame(height: geometry.height(rows: layout.rowCount), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A displaced tile leaves through the nearer edge — the one it is
    /// already against — so it reads as being pushed aside by the tile
    /// expanding beside it rather than flying across the screen.
    private func displacement(of tile: DashboardResolvedTile) -> CGFloat {
        guard tile.isDisplaced else { return 0 }
        let travel = geometry.size(rows: tile.size.rows, columns: DashboardLayout.columnCount).width
            + geometry.spacing
        return tile.column == 0 ? -travel : travel
    }
}
