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
            ProgressDots(step: step)

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

/// Where you are, as dots — the current one a pill, per the brief.
///
/// The pill is the *same* view as the dots with a different width, animated
/// with `Motion.quick`, so the shape travels along the row instead of one
/// dot vanishing and another appearing somewhere else. `matchedGeometryEffect`
/// would do the same thing with more machinery; a width change on a capsule
/// is the whole effect.
private struct ProgressDots: View {
    let step: SetupStep

    private static let pillWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(SetupStep.progressSteps, id: \.self) { dot in
                Capsule()
                    .fill(fill(for: dot))
                    .frame(width: dot == step ? Self.pillWidth : AppTheme.Size.dot, height: AppTheme.Size.dot)
            }
        }
        .animation(AppTheme.Motion.quick, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Steps already behind you keep the accent at reduced strength: the
    /// row reads as progress rather than as one lit dot among seven dead
    /// ones, which is the difference between "four to go" and "you are on
    /// number four".
    private func fill(for dot: SetupStep) -> Color {
        if dot == step { return AppTheme.Palette.brandPrimary }
        return dot < step ? AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.dim) : AppTheme.Palette.fillStrong
    }

    private var label: String {
        guard let index = SetupStep.progressSteps.firstIndex(of: step) else { return "Setting up" }
        return "Step \(index + 1) of \(SetupStep.progressSteps.count)"
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
