import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The gutter between two tiles must be one number, everywhere.
///
/// This is a real report, not a hypothetical: the dashboard looked like it
/// had a tighter gap around the one half-height widget. The arithmetic here
/// was innocent — the cause was that tile's *content* overflowing its card
/// and drawing through the gutter — but the arithmetic is the part that can
/// silently rot, because `rowHeight` is derived by subtracting a spacing out
/// of the cell size and `extent` adds spacings back in for a spanning tile.
/// Get either wrong and the gap starts depending on how tall a widget is.
@Suite("Dashboard grid spacing")
struct DashboardGeometryTests {
    private let widths: [CGFloat] = [320, 358, 390, 402, 440]

    /// A tile spanning `rows` rows must leave exactly `spacing` before the
    /// tile that starts on the row after it — for every span, at every
    /// position, on every screen width.
    @Test("The vertical gap is the same whatever a tile's height")
    func verticalGapIsConstant() {
        for width in widths {
            let geometry = DashboardGeometry(availableWidth: width)
            for row in 0 ... 6 {
                for span in 1 ... 6 {
                    let bottom = geometry.origin(row: row, column: 0).y
                        + geometry.size(rows: span, columns: 1).height
                    let next = geometry.origin(row: row + span, column: 0).y
                    #expect(
                        abs((next - bottom) - geometry.spacing) < 0.001,
                        "row \(row) spanning \(span) at width \(width) left \(next - bottom)"
                    )
                }
            }
        }
    }

    @Test("The horizontal gap is the same whatever a tile's width")
    func horizontalGapIsConstant() {
        for width in widths {
            let geometry = DashboardGeometry(availableWidth: width)
            let right = geometry.origin(row: 0, column: 0).x + geometry.size(rows: 2, columns: 1).width
            let next = geometry.origin(row: 0, column: 1).x
            #expect(abs((next - right) - geometry.spacing) < 0.001)
        }
    }

    /// A full-width tile has to measure exactly as wide as the two tiles
    /// above it, gutter included — the property `extent`'s spacing
    /// absorption exists for.
    @Test("A tile spanning both columns is as wide as two tiles and their gap")
    func spanningTileAbsorbsTheGutter() {
        for width in widths {
            let geometry = DashboardGeometry(availableWidth: width)
            let two = geometry.size(rows: 2, columns: 1).width * 2 + geometry.spacing
            #expect(abs(geometry.size(rows: 2, columns: 2).width - two) < 0.001)
        }
    }

    /// The half-row grid still has to make a widget-height tile square, since
    /// that is the shape every collapsed tile rests at.
    @Test("A tile one widget tall is square")
    func widgetHeightIsSquare() {
        for width in widths {
            let geometry = DashboardGeometry(availableWidth: width)
            let size = geometry.size(rows: DashboardLayout.rowsPerWidget, columns: 1)
            #expect(abs(size.height - size.width) < 0.001, "at width \(width): \(size)")
        }
    }
}
