import KeepoCore
import SwiftUI

/// The widget catalogue's presentation, and everything that happens to a
/// widget dragged out of it. Split from `DashboardCanvasView` to keep that
/// file under the project's length lint — the canvas owns the grid and the
/// tiles already on it; this owns arrival.
extension DashboardCanvasView {

    /// A widget on its way in from the catalogue. Its id is minted once, at
    /// lift-off, so the tile previewed under the finger and the tile finally
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
                onSelect: { kind in
                    isPickingWidget = false
                    add(kind)
                },
                onClose: { isPickingWidget = false },
                onDrag: { phase in handleCatalogDrag(phase, geometry: geometry) }
            )
            .ignoresSafeArea(edges: .bottom)
            .transition(.move(edge: .bottom))
        }
    }

    /// A widget dragged out of the catalogue is the same gesture as a tile
    /// being moved — it just starts life off-grid. The panel gets out of the
    /// way the moment the drag begins, so the widget is in hand over the
    /// dashboard rather than landing somewhere and needing to be found.
    private func handleCatalogDrag(_ phase: DashboardCatalogDrag, geometry: DashboardGeometry) {
        switch phase {
        case .began(let kind):
            guard incoming == nil else { return }
            incoming = DashboardIncomingWidget(kind: kind)
            withAnimation(.snappy(duration: 0.25)) { isPickingWidget = false }
            beginEditing()
        case .moved(let location):
            previewIncoming(at: geometry.cell(at: location))
            updateAutoScroll(gridY: location.y, geometry: geometry)
        case .ended(let location):
            stopAutoScroll()
            dropIncoming(at: geometry.cell(at: location))
        case .cancelled:
            stopAutoScroll()
            clearIncoming()
        }
    }

    // MARK: - Dropping in from the catalogue

    /// Reflows the grid around the widget on its way in, using the same
    /// preview arrangement a tile already on the dashboard uses while being
    /// dragged — so arriving and rearranging look like one mechanism.
    private func previewIncoming(at cell: DashboardGridCell) {
        guard let incoming, cell != previewCell else { return }
        previewCell = cell
        var preview = store.arrangement
        preview.insert(kind: incoming.kind, id: incoming.id, atRow: cell.row, column: cell.column)
        withAnimation(.snappy(duration: 0.25)) { dragPreview = preview }
    }

    private func dropIncoming(at cell: DashboardGridCell) {
        guard let incoming else { return }
        withAnimation(.snappy(duration: 0.3)) {
            store.insert(kind: incoming.kind, id: incoming.id, atRow: cell.row, column: cell.column)
            clearIncoming()
        }
        bumpEditModeTimeout()
    }

    private func clearIncoming() {
        incoming = nil
        dragPreview = nil
        previewCell = nil
    }

}
