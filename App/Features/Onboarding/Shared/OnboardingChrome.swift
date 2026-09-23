import KeepoCore
import SwiftUI

/// The bar across the top of every setup step: where you are, the way back,
/// and the way past.
///
/// One component rather than eight copies, for the reason the brief gives
/// and the reason the lint threshold gives: eight screens that each drew
/// their own dots would drift on spacing within a week, and the drift would
/// be visible precisely because the user sees this bar eight times in
/// ninety seconds.
struct OnboardingChrome: View {
    let step: SetupStep
    /// `nil` on the first step — there is nowhere to go back to, and a
    /// disabled button that never enables is worse than no button.
    var onBack: (() -> Void)?
    /// `nil` on the account step, which is the one thing Keepo cannot do
    /// without (see `SetupStep.isSkippable`).
    var onSkip: (() -> Void)?

    var body: some View {
        ZStack {
            ProgressDots(
                current: SetupStep.progressSteps.firstIndex(of: step) ?? SetupStep.progressSteps.count,
                count: SetupStep.progressSteps.count
            )

            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(AppTheme.Typography.bodyEmphasis)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Spacer(minLength: 0)
                if let onSkip {
                    DelayedSkipButton(step: step, action: onSkip)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .frame(height: AppTheme.Size.touchTarget)
    }
}

/// A `Skip` that is not there the instant the screen appears.
///
/// **2.75 seconds**, which is long enough that skipping is a decision
/// rather than a reflex and short enough that it never reads as a hostage
/// situation. It resets per step — `task(id:)` keyed on the step — because
/// a Skip inherited from the previous screen would be visible before this
/// screen had been read at all.
///
/// The fade uses `Motion.colorSafe` deliberately. It is an opacity change,
/// and that token's own doc comment explains why a spring on one is a
/// rendering bug rather than a matter of taste.
struct DelayedSkipButton: View {
    let step: SetupStep
    let action: () -> Void

    private static let delay = Duration.milliseconds(2750)

    @State private var isVisible = false

    var body: some View {
        Button(action: action) {
            Text("Skip")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(height: AppTheme.Size.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        // Not merely invisible: a zero-opacity button is untappable in
        // UIKit anyway (`hitTest` skips alpha ≤ 0.01 — see `AmountField`'s
        // own header, where relying on the opposite was a real bug), and
        // leaving it in the accessibility tree would offer VoiceOver a
        // control sighted users cannot see yet.
        .disabled(!isVisible)
        .accessibilityHidden(!isVisible)
        .animation(AppTheme.Motion.colorSafe, value: isVisible)
        .task(id: step) {
            isVisible = false
            try? await Task.sleep(for: Self.delay)
            isVisible = true
        }
    }
}
