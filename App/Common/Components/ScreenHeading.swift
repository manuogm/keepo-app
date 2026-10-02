import SwiftUI

/// A screen's title and the line or two under it, drawn in the content
/// rather than in the navigation bar — onboarding's heading.
///
/// Lifted out of `OnboardingScaffold` so the capture setup reached from
/// Profile can wear the same heading as the onboarding screens it repeats;
/// two copies of it would drift on spacing within a week.
struct ScreenHeading: View {
    let title: String?
    var subtitle: String?
    /// Holds the subtitle to a single line: lifts the prose measure (a line
    /// that must not wrap cannot also be capped narrower than itself) and
    /// lets the text shrink a little on a narrow phone rather than wrap or
    /// truncate. For a subtitle that is one short sentence, not for prose.
    var subtitleOnOneLine = false

    /// **Both lines are `fixedSize` vertically, and that is load-bearing.**
    /// Content around a heading often sits between flexible spacers, so
    /// SwiftUI is free to negotiate this block's height — and given the
    /// chance it compresses the title to a single line and truncates it with
    /// an ellipsis rather than wrapping. It showed up as "Purchases, without
    /// o…" on the capture step the moment that step's subtitle got shorter,
    /// which is the worst shape of layout bug: invisible in code, and
    /// triggered by editing a different string.
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            if let title {
                Text(title)
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle {
                Text(subtitle)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(subtitleOnOneLine ? 1 : nil)
                    .minimumScaleFactor(subtitleOnOneLine ? 0.8 : 1)
                    // The token exists for exactly this: prose stops being
                    // readable past roughly this measure.
                    .frame(
                        maxWidth: subtitleOnOneLine ? .infinity : AppTheme.Size.proseWidth,
                        alignment: .leading
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
