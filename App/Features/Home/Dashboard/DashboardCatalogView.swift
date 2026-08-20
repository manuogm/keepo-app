import KeepoCore
import SwiftUI

/// The widget catalogue. Every entry is the **real widget view**, rendered at
/// its real proportions from `DashboardData.sample` — not a mock-up, not a
/// screenshot, not a second implementation. A preview whose only job is to
/// promise what you're about to get has to be the thing itself, or it will
/// drift from it within two changes.
///
/// Picking one dismisses the sheet and hands the kind back; the caller adds
/// it and drops straight into edit mode so it can be placed.
struct DashboardCatalogView: View {
    let onSelect: (DashboardWidgetKind) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    let geometry = DashboardGeometry(availableWidth: proxy.size.width - inset * 2)
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                            entry(kind, geometry: geometry)
                        }
                    }
                    .padding(.horizontal, inset)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Add Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var inset: CGFloat { 16 }

    private func entry(_ kind: DashboardWidgetKind, geometry: DashboardGeometry) -> some View {
        Button {
            onSelect(kind)
            dismiss()
        } label: {
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
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                preview(kind, geometry: geometry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
    }

    /// Rendered at exactly the cell size the dashboard would give it, so a
    /// 1×1 reads as half-width beside a 1×2's full width — the size badge and
    /// the picture agree, and the user learns the grid from the catalogue.
    private func preview(_ kind: DashboardWidgetKind, geometry: DashboardGeometry) -> some View {
        let size = geometry.size(rows: kind.baseSize.rows, columns: kind.baseSize.columns)
        return DashboardWidgetView(kind: kind, data: .sample)
            .frame(width: size.width, height: size.height)
            // The preview is a picture of a widget, not a widget: its own tap
            // target would compete with the row's, and its range filter would
            // invite interaction that goes nowhere.
            .allowsHitTesting(false)
    }
}
