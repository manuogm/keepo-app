import KeepoCore
import SwiftUI

/// The widget catalogue, as a panel **inside the dashboard's own view
/// hierarchy** rather than a `.sheet`.
///
/// That is not a styling choice: a `.sheet` cannot host this list's two jobs
/// at once. It has to scroll, and a widget has to come *out* of it onto the
/// dashboard underneath — which a sheet cannot show at all.
///
/// The drag out is a **system drag session** (`.onDrag`), not a SwiftUI
/// `DragGesture`, and that is the second load-bearing decision here. Every
/// gesture-based attempt failed the same way, measured in the simulator: a
/// `DragGesture` on a scrolling row — sequenced behind a long press, and
/// even attached with `.simultaneousGesture` — wins arbitration against the
/// enclosing `ScrollView` from the first touch down, and this list simply
/// refuses to move, stranding every widget below the fold. Removing that one
/// modifier restored scrolling instantly; nothing else did. A drag session
/// is what UIKit built for this shape of interaction (it is how the home
/// screen's own widget gallery works): the lift coexists with the scroll
/// pan, the preview is carried by the window rather than by this view, and
/// so the panel is free to get out of the way the moment the drag begins
/// without the widget going with it.
///
/// Every entry is the real widget view rendered against `DashboardData
/// .sample`, not a mock-up — as the tile on the dashboard, as the picture in
/// this list, and as the preview under the finger. A preview whose only job
/// is to promise what you're about to get has to be the thing itself.
struct DashboardCatalogView: View {
    let geometry: DashboardGeometry
    let maxHeight: CGFloat
    /// Tapping still adds the widget the quick way, at the first free slot.
    let onSelect: (DashboardWidgetKind) -> Void
    let onClose: () -> Void
    /// Which widget is being carried out of the list. Called as the drag
    /// session begins — and again, later, when the drop resolves the item,
    /// which is why it must stay a note of *what* rather than an action:
    /// see the comment on `onDrag` below.
    let onLift: (DashboardWidgetKind) -> Void

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
            draggableCard(kind)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(kind) }
    }

    /// The widget card, and the only part of the row a drag can start from.
    ///
    /// Attached to the whole row instead, the lift highlighted the row — the
    /// title, the size badge, the description and the card together, in one
    /// box that looked like a text selection rather than like picking up a
    /// widget. The lift shape comes from the source view, so the source view
    /// has to *be* the widget. Tapping anywhere on the row still adds it;
    /// only the grab moved.
    private func draggableCard(_ kind: DashboardWidgetKind) -> some View {
        preview(kind)
            // Clipped to the card's own corner, so the lift rounds off
            // exactly where the widget does rather than at a square edge a
            // few points outside it.
            .contentShape(
                .dragPreview,
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
            // SwiftUI calls this closure a second time when the drop
            // resolves the item — after the widget has already landed. So it
            // does one idempotent thing, note which kind is in hand, and the
            // dashboard acts on that note when the drag reaches it. Anything
            // with a consequence here (dismissing the panel, entering edit
            // mode, minting the arriving tile) would happen twice, the
            // second time stranding a widget nobody asked for.
            //
            // The payload itself cannot answer the question: a drop session
            // hands over its item data only in `performDrop`, and the grid
            // has to reflow around the widget long before then.
            .onDrag {
                onLift(kind)
                return NSItemProvider(object: kind.rawValue as NSString)
            } preview: {
                preview(kind)
            }
    }

    /// Rendered at exactly the cell size the dashboard would give it, so a
    /// 1×1 reads as half-width beside a 1×2's full width — the size badge and
    /// the picture agree, and the user learns the grid from the catalogue.
    /// Doubles as the drag preview, for the same reason.
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
