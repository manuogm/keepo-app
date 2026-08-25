import KeepoCore
import SwiftUI

/// Keeping an expanded widget on screen.
///
/// A widget expands **in place** — it grows where it sits and the grid
/// reflows around it; nothing is lifted out into an overlay. The cost of
/// that (and the reason this file exists) is that a tile near the bottom of
/// a tall dashboard can grow straight past the fold, leaving the user to
/// scroll down and find the half they asked to see. So the canvas scrolls
/// to it instead, by the smallest amount that fits the whole tile with one
/// grid row of breathing room underneath.
///
/// "The smallest amount" is the rule worth stating: this is not
/// scroll-to-top and not scroll-to-centre. A tile already fully visible does
/// not move at all, which matters because expanding the top widget on a
/// short dashboard should look like it grew, not like the page jumped.
extension DashboardCanvasView {
    /// Scrolls so the tile at `row`, grown to `size`, is fully visible.
    ///
    /// Called from the expansion animation's completion, once the content has
    /// actually reached its new height — see `setExpansion`. The grid's own
    /// top doesn't move when a tile expands (only the content below it does),
    /// so the tile's position is the same either way; what changes is whether
    /// the scroll view will *let* us scroll that far.
    func scrollToFit(row: Int, size: DashboardWidgetSize, geometry: DashboardGeometry) {
        guard scrollGeometry.viewportHeight > 0, gridFrame != .zero else { return }

        // The grid's top in *content* space. `gridFrame` is measured in the
        // canvas (viewport) space, so undoing the current scroll offset is
        // what turns it into a position that doesn't move as we scroll.
        let gridTop = gridFrame.minY + scrollGeometry.offsetY
        let tileTop = gridTop + geometry.origin(row: row, column: 0).y
        let tileHeight = geometry.size(rows: size.rows, columns: size.columns).height
        let tileBottom = tileTop + tileHeight
        // Two grid rows of clearance below, per the design — one row left the
        // expanded tile sitting low enough on the screen that it read as
        // wedged against the bottom edge rather than presented on it.
        let margin = geometry.height(rows: 2) + geometry.spacing

        // Already fully on screen with its clearance: don't move at all.
        // Expanding the top widget of a short dashboard should look like it
        // grew, not like the page jumped.
        let viewportBottom = scrollGeometry.offsetY + scrollGeometry.viewportHeight
        guard tileTop < scrollGeometry.offsetY || tileBottom + margin > viewportBottom else { return }

        // Centred in the viewport, then pulled down far enough to guarantee
        // the bottom clearance, then capped so the tile's own top never goes
        // off screen — a tile taller than the viewport resolves to its top,
        // which is where the headline and the filter live.
        let centred = tileTop - (scrollGeometry.viewportHeight - tileHeight) / 2
        let clearingBottom = tileBottom + margin - scrollGeometry.viewportHeight
        let target = min(max(centred, clearingBottom), tileTop)

        // Clamped to the page's real bounds. This runs after the expansion
        // has been laid out, so `contentHeight` already includes the taller
        // tile and the scroll view will honour the whole range.
        let clamped = min(max(target, 0), scrollGeometry.maximumOffsetY)
        guard abs(clamped - scrollGeometry.offsetY) > 1 else { return }
        scrollPosition.scrollTo(y: clamped)
    }
}
