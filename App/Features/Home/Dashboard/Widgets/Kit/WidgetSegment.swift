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
                .padding(.horizontal, 8)
                // Tight, like the tab bar this is meant to read as. It used
                // to be 6pt of padding inside a 44pt frame, and the frame —
                // not the padding — is what made every expanded widget's
                // header 44pt tall and pushed its title and headline down.
                .padding(.vertical, 4)
                .background(background, in: Capsule())
                // The 44pt target comes back as an *overlay*, so the finger
                // gets HIG's area without the layout getting its height.
                .hitTarget()
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

    /// The selected segment's capsule.
    ///
    /// Untinted, it is the **card's own colour** rather than a darker grey —
    /// the same trick `UISegmentedControl` uses. The segment sits on a faint
    /// track, so punching back to the surface behind it reads as raised, and
    /// the selected label gets the card's full contrast instead of dark grey
    /// text on mid grey. A darker selected capsule did the opposite: it was
    /// nearly the track's own tone, so the selection was hard to find and
    /// the letter on it was hard to read.
    ///
    /// Tinted, it stays a wash of the tint — Cashflow's In/Out toggle has no
    /// track behind it, so a card-coloured capsule there would be invisible.
    private var background: Color {
        guard isSelected else { return .clear }
        guard let tint else { return Color(.secondarySystemGroupedBackground) }
        return tint.opacity(0.16)
    }
}
