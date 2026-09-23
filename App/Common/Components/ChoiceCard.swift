import SwiftUI

/// One answer to a pick-one question, drawn as its own card: an icon, a
/// title, and a line or two of what choosing it means. The chosen card fills
/// with `textPrimary` and its ink inverts, so the answer is the one dark
/// (or, in dark mode, light) shape in the list — no radio circle needed.
///
/// Extracted from the Notifications screen's three levels when Export's
/// format step was asked to look exactly like them; one card, so the two
/// cannot drift.
struct ChoiceCard<Icon: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var icon: Icon

    @Environment(\.colorScheme) private var colorScheme

    /// The selected card's fill is `textPrimary` itself, which is adaptive
    /// — so its own text cannot reuse that token without disappearing into
    /// it. `inkOnPrimaryFill` is that pair, in one place.
    private var selectedTextColor: Color {
        AppTheme.Palette.inkOnPrimaryFill(colorScheme)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.s) {
                icon
                    .foregroundStyle(isSelected ? selectedTextColor : AppTheme.Palette.textPrimary)
                    .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                    .accessibilityHidden(true)
                // A hidden twin sized for the longest possible detail (two
                // lines) reserves one consistent height for every card. The
                // real title+detail block — one line of detail for some
                // options, two for others — centers as a whole inside that
                // reserved height, so every card gets the same top/bottom
                // margin without disturbing the title-to-detail gap that
                // separates its own two lines.
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(title)
                            .font(AppTheme.Typography.bodyEmphasis)
                            .lineLimit(1)
                        Text("Reserved\nReserved")
                            .font(AppTheme.Typography.caption)
                            .lineLimit(2)
                    }
                    .opacity(0)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(title)
                            .font(isSelected ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.body)
                            .foregroundStyle(isSelected ? selectedTextColor : AppTheme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(detail)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(
                                isSelected ? selectedTextColor.opacity(0.85) : AppTheme.Palette.textSecondary
                            )
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AppTheme.Palette.textPrimary : AppTheme.Palette.bgSurface,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
            )
        }
        .buttonStyle(.pressableRow)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
