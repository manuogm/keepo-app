import KeepoCore
import SwiftUI

/// The first thing anyone sees.
///
/// **Welcome and the problem statement are one screen, not two** (§3.1).
/// Apart, the first says nothing — "Welcome to Keepo" is a headline, and a
/// headline with its own screen is a screen with no content. Together they
/// are a title, a promise, and the reason to keep reading, which is the
/// whole job of a first screen.
///
/// The mark is `Typography.Number.hero`, the 48pt size whose own doc
/// comment calls it "the sign-in screen's mark" — a size the app defined
/// and then never used anywhere. It is used here and on sign-in now.
struct WelcomeView: View {
    let onContinue: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: AppTheme.Spacing.l) {
                    Text("Keepo")
                        .font(AppTheme.Typography.Number.display(
                            AppTheme.Typography.Number.hero, weight: .bold, scale: typeScale
                        ))
                        .foregroundStyle(AppTheme.Palette.textPrimary)

                    Text("Where all your money is kept under control.")
                        .font(AppTheme.Typography.sectionTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .multilineTextAlignment(.center)

                    // The problem, in the user's own words rather than a
                    // pitch. It is a subhead to the promise above, which is
                    // why it is quieter than it is — it earns the next
                    // four screens rather than competing with them.
                    Text("Tired of trying app after app, and none of them working the way you do?")
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppTheme.Size.proseWidth)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                OnboardingPrimaryButton(title: "Let's go", action: onContinue)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
        }
    }
}

#Preview {
    WelcomeView {}
}
