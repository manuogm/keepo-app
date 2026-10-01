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
    /// `nil` on the currency step, where Skip would only repeat Next (see
    /// `SetupStep.isSkippable`).
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
                // There the moment the screen appears. It used to fade in
                // after 2.75 seconds, to make skipping a decision rather
                // than a reflex; in practice that read as the app holding
                // back a control the user had already decided to use.
                if let onSkip {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(AppTheme.Typography.label)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .frame(height: AppTheme.Size.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .frame(height: AppTheme.Size.touchTarget)
    }
}
