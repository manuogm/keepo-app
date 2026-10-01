import KeepoCore
import SwiftUI

/// The drawer's own chrome — its surface, its header row and the state it
/// ends on — split out of `NeedsReviewPanel.swift` purely to keep that file
/// under the project's file-length lint, same precedent as
/// `NeedsReviewPanel+Actions.swift` and `TransactionsListView+Loading.swift`.
extension NeedsReviewPanel {
    /// **A card until it is the screen, and the screen after that.**
    ///
    /// Collapsed, the drawer is one row on the Transactions canvas and has
    /// to be seen: `bgSurface` white, with its shadow and its two rounded
    /// corners, the same as any other card in the app.
    ///
    /// Expanded, it *is* that screen — so it takes the screen's own
    /// `bgCanvas` grey and stops being a surface at all. That is what lets
    /// the item tiles be `bgSurface` white like the ledger's: white on grey
    /// is how a tile reads as a tile everywhere else here, and the drawer
    /// used to have that relationship upside down, with grey tiles on a
    /// white sheet.
    ///
    /// **`colorSafe`, not `standard`.** This is an interpolated colour and
    /// nothing else, which is exactly the case `AppTheme.Motion`'s fourth
    /// token exists for: a spring overshooting a colour ramp has nowhere to
    /// go, clamps, and comes back as a flash.
    var surface: some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: Metrics.radius, bottomTrailingRadius: Metrics.radius, style: .continuous
        )
        .fill(isExpanded ? AppTheme.Palette.bgCanvas : AppTheme.Palette.bgSurface)
        .animation(AppTheme.Motion.colorSafe, value: isExpanded)
    }

    /// **Green, not mango.** Everywhere else in this panel the accent means
    /// "your attention is wanted"; this is the one moment it is not wanted
    /// any more, and `statusPositive` is the colour the rest of the app
    /// already uses to say money arrived and a thing went right.
    var successState: some View {
        ZStack {
            // Behind the mark and unclipped, so the pieces read as coming
            // *from* the tick rather than flying past it — the same
            // arrangement onboarding's All Set screen uses. Silent under
            // Reduce Motion; the haptic on `showSuccess` still fires.
            ConfettiBurst(isActive: showSuccess)

            VStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: "checkmark")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                    .background(AppTheme.Palette.statusPositive, in: Circle())
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text("Your inbox is now clear!")
                        .font(AppTheme.Typography.rowTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    Text("Nothing else needs your review.")
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, AppTheme.Spacing.xxl)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    /// The glyph is `textPrimary` and sits in no well of its own: the count
    /// beside it is what should catch the eye, and an icon in a tinted
    /// circle was competing with the words for it. It still occupies a full
    /// `icon`-wide column so the header's text starts exactly where every
    /// row's below it does.
    var header: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) { isExpanded.toggle() }
        } label: {
            HStack(spacing: AppTheme.Spacing.m) {
                KeepoIcon(name: "icon-inbox", size: AppTheme.Size.glyph)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .frame(width: AppTheme.Size.icon)

                Text(headline)
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.m)
        }
        .buttonStyle(.pressableRow)
        .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")
    }

    var headline: String {
        items.count == 1 ? "1 item needs review" : "\(items.count) items need review"
    }
}
