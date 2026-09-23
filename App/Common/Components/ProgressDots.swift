import SwiftUI

/// Where you are in a short flow, as dots — the current one a pill, per the
/// onboarding brief.
///
/// The pill is the *same* view as the dots with a different width, animated
/// with `Motion.quick`, so the shape travels along the row instead of one
/// dot vanishing and another appearing somewhere else. `matchedGeometryEffect`
/// would do the same thing with more machinery; a width change on a capsule
/// is the whole effect.
///
/// Shared by the app's two step-by-step flows, setup and Export, so "step 2
/// of 3" looks the same wherever it is said. It lived privately in
/// `OnboardingChrome` until Export became one question per screen.
struct ProgressDots: View {
    /// Zero-based. `count` or more means every step is behind you.
    let current: Int
    let count: Int

    private static let pillWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(fill(for: dot))
                    .frame(width: dot == current ? Self.pillWidth : AppTheme.Size.dot, height: AppTheme.Size.dot)
            }
        }
        .animation(AppTheme.Motion.quick, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(current, count - 1) + 1) of \(count)")
    }

    /// Steps already behind you keep the accent at reduced strength: the
    /// row reads as progress rather than as one lit dot among dead ones,
    /// which is the difference between "four to go" and "you are on number
    /// four".
    private func fill(for dot: Int) -> Color {
        if dot == current { return AppTheme.Palette.brandPrimary }
        return dot < current ? AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.dim) : AppTheme.Palette.fillStrong
    }
}
