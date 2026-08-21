import KeepoCore
import SwiftUI

/// What a drag out of the catalogue is doing right now. Locations are in the
/// grid's coordinate space, so the canvas can convert them to cells with the
/// same `DashboardGeometry.cell(at:)` a tile drag uses.
enum DashboardCatalogDrag {
    case began(DashboardWidgetKind)
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

/// The widget catalogue, as a panel **inside the dashboard's own view
/// hierarchy** rather than a `.sheet`.
///
/// That is not a styling choice. A widget has to be draggable straight out
/// of here and onto the grid, and a drag cannot survive the sheet being
/// dismissed underneath it: dismissing destroys the drag's source view and
/// UIKit cancels the session, so the gesture ended with the sheet gone and
/// nothing placed. Tested twice before rewriting it this way. Living in the
/// same hierarchy means the drag is an ordinary `DragGesture` reading the
/// grid's own coordinate space — the very same mechanism that already moves
/// a tile already on the dashboard, so arriving and rearranging behave
/// identically instead of being two different systems.
///
/// Every entry is the real widget view rendered against `DashboardData
/// .sample`, not a mock-up. A preview whose only job is to promise what
/// you're about to get has to be the thing itself.
struct DashboardCatalogView: View {
    let geometry: DashboardGeometry
    let maxHeight: CGFloat
    /// Tapping still adds the widget the quick way, at the first free slot.
    let onSelect: (DashboardWidgetKind) -> Void
    let onClose: () -> Void
    let onDrag: (DashboardCatalogDrag) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                        entry(kind)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: maxHeight)
        .background(
            Color(.systemGroupedBackground),
            in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: -6)
    }

    private var inset: CGFloat { 16 }

    private var header: some View {
        HStack {
            Text("Add Widget")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, inset)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func entry(_ kind: DashboardWidgetKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kind.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(kind.sizeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer(minLength: 4)
            }
            Text(kind.summary)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            preview(kind)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(kind) }
        .gesture(dragOut(kind))
    }

    /// Long press first, for the same reason the grid's own tile drag needs
    /// one: this list scrolls, and a bare `DragGesture` would take every
    /// touch away from the scroll view.
    private func dragOut(_ kind: DashboardWidgetKind) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(DashboardGridSpace.name)))
            .onChanged { value in
                switch value {
                case .first:
                    onDrag(.began(kind))
                case .second(true, let movement?):
                    onDrag(.moved(movement.location))
                default:
                    break
                }
            }
            .onEnded { value in
                guard case .second(true, let movement?) = value else {
                    onDrag(.cancelled)
                    return
                }
                onDrag(.ended(movement.location))
            }
    }

    /// Rendered at exactly the cell size the dashboard would give it, so a
    /// 1×1 reads as half-width beside a 1×2's full width — the size badge and
    /// the picture agree, and the user learns the grid from the catalogue.
    private func preview(_ kind: DashboardWidgetKind) -> some View {
        let size = geometry.size(rows: kind.baseSize.rows, columns: kind.baseSize.columns)
        return DashboardWidgetView(kind: kind, data: .sample)
            .frame(width: size.width, height: size.height)
            // A picture of a widget, not a widget: its own tap target would
            // compete with the row's, and its controls would invite
            // interaction that goes nowhere.
            .allowsHitTesting(false)
    }
}

/// The grid's coordinate-space name, shared so the catalogue's drag and the
/// canvas's own drop maths are literally reading the same space.
enum DashboardGridSpace {
    static let name = "dashboardGrid"
}
