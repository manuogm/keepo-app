import KeepoCore
import SwiftUI

/// Cell arithmetic for the dashboard grid — the only place points and grid
/// coordinates are converted into one another, in either direction. `cell(at:)`
/// is the inverse of `origin(row:column:)`, and edit-mode drags depend on
/// that being literally true rather than approximately true.
struct DashboardGeometry: Equatable {
    let cellSize: CGFloat
    let spacing: CGFloat

    /// A row is exactly as tall as a column is wide — the grid is square
    /// cells, per the design. Everything else here follows from that.
    init(availableWidth: CGFloat, spacing: CGFloat = 12) {
        self.spacing = spacing
        let columns = CGFloat(DashboardLayout.columnCount)
        self.cellSize = max((availableWidth - spacing * (columns - 1)) / columns, 1)
    }

    private var stride: CGFloat { cellSize + spacing }

    /// Spanning tiles absorb the gaps they cover, so a 2-wide tile is wider
    /// than two cells by exactly one spacing — otherwise a full-width tile
    /// would sit narrower than the two tiles above it.
    private func extent(_ count: Int) -> CGFloat {
        CGFloat(count) * cellSize + CGFloat(max(count - 1, 0)) * spacing
    }

    func size(rows: Int, columns: Int) -> CGSize {
        CGSize(width: extent(columns), height: extent(rows))
    }

    func origin(row: Int, column: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * stride, y: CGFloat(row) * stride)
    }

    func height(rows: Int) -> CGFloat { extent(rows) }

    /// The cell a point falls in, clamped into the grid. Used to turn a
    /// drag's live location into the drop target `DashboardArrangement.move`
    /// expects; a point in a gutter resolves to the cell it is nearest,
    /// which is what keeps a drop between two tiles from doing nothing.
    func cell(at point: CGPoint) -> (row: Int, column: Int) {
        let column = Int((point.x / stride).rounded(.down))
        let row = Int((point.y / stride).rounded(.down))
        return (
            row: max(row, 0),
            column: min(max(column, 0), DashboardLayout.columnCount - 1)
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
        let travel = geometry.size(rows: 1, columns: DashboardLayout.columnCount).width + geometry.spacing
        return tile.column == 0 ? -travel : travel
    }
}
