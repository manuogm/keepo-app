import SwiftUI

/// What automatic capture is — a heading, a line and a picture — and the
/// words on the button that starts it.
///
/// **One copy, two screens.** Onboarding's capture intro and Profile → My
/// Automations' blank state are the same pitch for the same feature, made
/// to a user at a different moment. They used to be two pitches — Profile
/// kept a diagram-and-bullets version after onboarding moved to the
/// illustration — and a user who skipped setup in onboarding then met a
/// different-looking sales page for the same thing in Profile.
enum CapturePitch {
    static let title = "Automatic payment detection"
    static let subtitle = "Most of your day-to-day spending, registered automatically"
    static let setUpTitle = "Set up now (2 min)"

    /// Centred across the width; each host decides where it floats.
    static var illustration: some View {
        KeepoIllustration(name: "illustration-auto-payment", size: AppTheme.Size.illustrationFeature)
            .frame(maxWidth: .infinity)
    }
}

/// The pitch as a whole screen outside onboarding — heading at the top, the
/// illustration floating in what is left, the button concentric with the
/// screen's bottom corners — laid out the way `OnboardingScaffold` lays out
/// the capture intro, minus onboarding's progress chrome.
///
/// Profile → My Automations shows it when capture is not set up, and the
/// account form's "add a card" opens on it: both are a user who has not set
/// capture up meeting the feature, and they should meet the same screen.
///
/// One button, with no "later" beside it: the way out is the host's own
/// Back or close, which is where a user already looks for it.
struct CapturePitchScreen: View {
    /// A line over the button saying why the user is looking at this rather
    /// than at what they tapped — `nil` when they came here on purpose.
    var note: String?
    let onSetUp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ScreenHeading(title: CapturePitch.title, subtitle: CapturePitch.subtitle)
                        Spacer(minLength: AppTheme.Spacing.xxl)
                        CapturePitch.illustration
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.top, AppTheme.Spacing.xl)
                    .padding(.bottom, AppTheme.Spacing.xxl)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            VStack(spacing: AppTheme.Spacing.s) {
                if let note {
                    Text(note)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                PrimaryActionButton(title: CapturePitch.setUpTitle, fillsWidth: true, action: onSetUp)
            }
            .padding(.horizontal, KeepoTabBarMetrics.margin)
            .padding(.top, AppTheme.Spacing.m)
            .padding(.bottom, KeepoTabBarMetrics.margin)
        }
        // Measured from the screen's true bottom edge, as `ExportView`'s bar
        // is and for its reason: ignoring the inset rather than reading it,
        // which once looped layout at 100% CPU.
        .ignoresSafeArea(.container, edges: .bottom)
    }
}
