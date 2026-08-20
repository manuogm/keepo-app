import KeepoCore
import SwiftUI

/// Edit mode's visual language: the jiggle, and the minus badge that removes
/// a widget. Both live here rather than inline in the canvas so the canvas
/// file stays about *arranging*, not about how arranging looks.

/// The iOS home-screen wobble. Two things make it read as the real thing
/// rather than as a synchronised metronome:
///
///  1. Each tile's period is slightly different, so the grid never lands on
///     a single beat — a whole screen rocking in unison looks like the page
///     is moving, not like the icons are loose.
///  2. That variation is derived from a **stable hash of the tile's id**,
///     never its index. An index-keyed value changes the moment a sibling is
///     inserted ahead of it, so a tile would visibly re-time itself whenever
///     something else on the dashboard moved.
struct JiggleModifier: ViewModifier {
    let isActive: Bool
    /// The tile's own identity — hashed below, never used directly.
    let seed: UUID

    @State private var isRocking = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isActive && isRocking ? amplitude : -amplitude))
            .animation(
                isActive
                    ? .easeInOut(duration: period).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.12),
                value: isRocking
            )
            .onChange(of: isActive) { _, active in isRocking = active }
            .onAppear { isRocking = isActive }
    }

    private var amplitude: Double { isActive ? 0.55 : 0 }

    /// 0.13–0.17s. Narrow on purpose: wide enough that no two tiles stay in
    /// phase, tight enough that they all still read as the same gesture.
    /// Keyed on the tile's own id via `StableSeed`, never on its index — see
    /// that type's header for why both alternatives are wrong.
    private var period: Double {
        0.13 + Double(StableSeed.index(seed.uuidString, upperBound: 40)) / 1_000
    }
}

extension View {
    func jiggling(_ isActive: Bool, seed: UUID) -> some View {
        modifier(JiggleModifier(isActive: isActive, seed: seed))
    }
}

/// The remove affordance — top-right, per the design. Sized and padded to be
/// comfortably tappable at 1×1: the badge itself is small, but its hit area
/// is not, because a tile that is actively wobbling is a hard target.
struct WidgetRemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                // The badge straddles the tile's corner, so the tap target
                // has to extend past the card's own bounds to feel right.
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove widget")
    }
}

/// The tile being dragged, and where the finger currently is. `location` is
/// in the grid's own coordinate space, so it converts straight to a cell via
/// `DashboardGeometry.cell(at:)` with no offset arithmetic in between.
struct DashboardDragState: Equatable {
    let id: UUID
    var translation: CGSize
    var location: CGPoint
}
