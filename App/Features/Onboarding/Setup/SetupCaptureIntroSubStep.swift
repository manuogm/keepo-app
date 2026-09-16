import KeepoCore
import SwiftUI

/// Step 4a — the pitch, and the fork.
///
/// **The step used to open with work.** The first thing it did was hand the
/// user a permission prompt and then send them to Shortcuts, before
/// anything had explained why either was worth doing. Setting up a Wallet
/// automation is the most effortful minute in the whole of onboarding, and
/// it was the one minute asked for with the least context.
///
/// So this screen sells it and then asks. Two answers, both real: **Set up
/// now** runs the walkthrough and the test; **Set up later** skips straight
/// past both, and is not a lesser answer — capture lives in Profile → My
/// Automations unchanged, and everything else in Keepo works without it.
/// Offering a genuine "later" here is also what lets the two screens behind
/// it drop their Skip entirely: a user who starts the setup has already
/// been given the way out, and one more escape hatch halfway through an
/// installation is how people end up with a half-built automation.
struct SetupCaptureIntroSubStep: View {
    let onSetUpNow: () -> Void
    let onSetUpLater: () -> Void
    let onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Automatic payment detection",
            step: .capture,
            onBack: onBack,
            isPrimaryVisible: false,
            onPrimary: onSetUpNow
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                pitch
                choices
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **A picture of the mechanism, then three lines under it.**
    ///
    /// This screen opened with three paragraphs. They were accurate and
    /// nobody was going to read them: it is the fifth screen of a setup
    /// flow, and it is asking for the only genuinely effortful minute in
    /// it. The argument — you tap your phone, Keepo writes it down — is
    /// three nouns and an arrow, and a diagram makes it in the time it
    /// takes to look at the screen.
    ///
    /// The lines that survive are the three facts the diagram cannot
    /// carry: what exactly gets captured, how much of your spending that
    /// turns out to be, and what it costs you to set up.
    private var pitch: some View {
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

    /// Both full width and stacked, rather than a pair in a bottom bar. They
    /// are two answers to the question the screen just asked, not an action
    /// and an escape — and a "later" tucked into a corner reads as the
    /// wrong answer, which would make the minute feel compulsory when it is
    /// genuinely not.
    private var choices: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            OnboardingPrimaryButton(title: "Set up now", fillsWidth: true, action: onSetUpNow)
            Button(action: onSetUpLater) {
                Text("Set up later")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: AppTheme.Size.touchTarget)
                    .overlay(Capsule().stroke(AppTheme.Palette.textSecondary, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
