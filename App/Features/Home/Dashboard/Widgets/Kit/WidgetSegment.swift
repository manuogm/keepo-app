import SwiftUI

/// One choice in a widget's inline picker — the W/M/Y segments in an expanded
/// header, and Cashflow's In/Out toggle.
///
/// Shared because the two are the same control doing the same job in the same
/// card, and the fastest way to make six widgets look like six designs is to
/// let each of them decide its own selected-state treatment. Everything that
/// makes a segment read as selected — the weight change, the capsule, the
/// insets — is decided here.
///
/// `tint` exists for the one case where a segment's label already carries a
/// meaning colour: Cashflow's In and Out are blue and coral everywhere else on
/// the dashboard, and a toggle that greyed them would be the only place those
/// two words aren't those two colours.
struct WidgetSegment<Label: View>: View {
    let isSelected: Bool
    var tint: Color?
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(foreground)
                .frame(minWidth: 24)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(background, in: Capsule())
                // The capsule stays the size the design wants; the *touch*
                // area is grown to Apple's 44pt minimum around it. Drawing
                // the segment itself at 44pt would put a control taller than
                // the widget's own title in every expanded header.
                .frame(minHeight: WidgetStyle.minimumTarget)
                .contentShape(Rectangle())
        }
        // `.plain`, not `.pressableRow`: this sits inside a card that has its
        // own tap gesture, and a button style that redraws on press competes
        // with the card's collapse animation.
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        guard let tint else { return isSelected ? Color.primary : Color.secondary }
        return isSelected ? tint : Color.secondary
    }

    private var background: Color {
        guard isSelected else { return .clear }
        return (tint ?? Color.secondary).opacity(0.16)
    }
}
