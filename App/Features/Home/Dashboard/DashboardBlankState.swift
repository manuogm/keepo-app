import SwiftUI

/// What Home shows once every widget has been removed. Deliberately not a
/// tile: no card, no fill, nothing that looks like a widget sitting there.
/// A dashboard with nothing on it should look like an empty surface waiting
/// for something, not like a broken widget.
struct DashboardBlankState: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 96, height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                            .strokeBorder(
                                Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
            }
            .buttonStyle(.pressableCard)

            VStack(spacing: 4) {
                Text("Your dashboard is empty")
                    .font(.headline)
                Text("Add widgets to track what matters to you.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, KeepoTabBarMetrics.clearance)
        .accessibilityElement(children: .contain)
    }
}

/// The always-available "add a widget" tile, sitting one row below the grid.
/// Kept on screen even when the dashboard is full, per the design — the
/// catalogue is otherwise only reachable by first long-pressing into edit
/// mode, which is a lot of gesture to discover for the most common thing a
/// user will want to do here.
///
/// A full-width bar exactly **one row** — half a widget — tall. That shape
/// is grammar rather than decoration: the half-row grid is what makes a
/// control shorter than a widget expressible at all, and at this height the
/// bar reads as a slot in the same grid rather than as a button bolted
/// underneath it, without claiming the screen a real widget would.
struct AddWidgetTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Add a widget")
    }
}
