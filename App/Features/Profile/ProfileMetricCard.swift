import KeepoCore
import SwiftUI

/// A small titled card holding one fact about you.
///
/// Two of them sit side by side under the name on My Profile — when you
/// joined, and what currency you see your money in. Both were previously a
/// line of grey caption text and a `Picker` row buried in a settings list,
/// which is the wrong weight for either: the join date is a small piece of
/// pride and the base currency is the single setting that changes the meaning
/// of every number in the app.
///
/// The content is a slot rather than a string because the two are genuinely
/// different shapes — one is a date, the other a flag and a code — and
/// forcing them through one signature would mean an enum with two cases and
/// a `switch` in the middle of a card that is nine lines long.
struct ProfileMetricCard<Content: View>: View {
    let title: String
    /// Non-nil makes the whole card a button. The currency card is tappable
    /// and the membership card is not, and the difference has to be visible:
    /// a chevron appears only when there is somewhere to go.
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(.pressableCard)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if action != nil {
                    Spacer(minLength: 0)
                    // `textTertiary`, not `textSecondary`: this card sits on
                    // My Profile directly above the row tiles below it (My
                    // Household, My Automations), whose chevron is `List`'s
                    // own system-drawn disclosure indicator — a lighter grey
                    // than every other manual chevron in the app uses.
                    Image(systemName: "chevron.right")
                        .font(AppTheme.Typography.nanoEmphasis)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }

            // Centred in whatever height is left under the title, not
            // pinned to the top of it. The two cards are the same height and
            // their titles are the same height, so the leftover rectangle is
            // identical in both — which makes "centred in it" the one rule
            // that puts a one-line currency badge and a two-line date on the
            // same axis, without either card knowing what the other holds.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        // Both axes, so a pair of these side by side is one pair of
        // identical rectangles whatever they contain: the width was always
        // shared, and the height now is too — the card takes all it is
        // offered and its caller decides how much that is.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppTheme.Spacing.m)
        .background(
            AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
        )
    }
}
