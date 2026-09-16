import KeepoCore
import SwiftUI

/// What automatic capture is, in one diagram and three lines.
///
/// Shared by onboarding's capture intro and Profile → My Automations,
/// because they are the same pitch made to the same person at two different
/// moments — someone deciding whether the minute of setup is worth it. Two
/// copies of it would drift, and the one in Profile would be the one nobody
/// noticed had gone stale.
///
/// **A picture, not paragraphs.** This started as three paragraphs that
/// were accurate and were not going to be read: it is the fifth screen of a
/// setup flow, asking for the only genuinely effortful minute in it. The
/// argument is three nouns and an arrow — you tap, Keepo writes it down —
/// and a diagram makes it in the time it takes to look at the screen. The
/// lines that survive are the three facts a diagram cannot carry: what gets
/// captured, how much of your spending that is, and what it costs to set up.
struct CapturePitchView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            flow
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                point("creditcard.fill", "The merchant, the amount and the card, as the payment goes through")
                point("bolt.fill", "Most of your day-to-day spending, entered without you typing")
                point("clock.fill", "About a minute to set up, once")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tap, Keepo, logged. Three discs and two chevrons, which is the whole
    /// feature.
    private var flow: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Spacer(minLength: 0)
            disc { Image(systemName: "wave.3.right") }
            chevron
            disc(isBrand: true) { Text("K").font(AppTheme.Typography.cardTitle) }
            chevron
            disc(tint: AppTheme.Palette.statusPositive) { Image(systemName: "checkmark") }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You pay, Keepo logs it")
    }

    private func disc<Glyph: View>(
        isBrand: Bool = false, tint: Color? = nil, @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        glyph()
            .font(AppTheme.Typography.sectionTitle)
            .foregroundStyle(isBrand ? AppTheme.Palette.textOnAccent : (tint ?? AppTheme.Palette.textPrimary))
            .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
            .background(
                isBrand ? AppTheme.Palette.brandPrimary : AppTheme.Palette.bgSurface,
                in: Circle()
            )
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.Palette.textSecondary)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.m) {
            Image(systemName: symbol)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.brandPrimary)
                .frame(width: AppTheme.Size.glyphSmall)
            Text(text)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
