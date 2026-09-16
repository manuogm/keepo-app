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
                CapturePitchView()
                choices
            }
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
