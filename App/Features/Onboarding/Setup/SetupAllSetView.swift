import KeepoCore
import SwiftUI

/// Step 8 — the payoff, and the only screen in the flow with nothing to
/// answer.
///
/// **No rating prompt here**, which is the whole of decision §3.10. Apple's
/// HIG says not to ask during onboarding, a rating given before any value
/// has been delivered rates the onboarding rather than the app, and a new
/// listing's first reviews are disproportionately weighted — so harvesting
/// them here would spend the launch's most valuable asset on its least
/// informed reviewers. Worse, `requestReview` is a black box the system may
/// silently decline to display, so a screen designed around a dialog
/// appearing over it would sometimes be a title over nothing. The ask lives
/// in the signed-in app, behind `ReviewPolicy`.
///
/// **This screen owns the `refreshProfile()` that ends the flow.** Every
/// write already happened on the previous screen; this is the one tap that
/// flips `SessionStore.phase` to `.ready`, and it is last so there is
/// nothing left for the resulting teardown to interrupt.
struct SetupAllSetView: View {
    let session: SessionStore
    let store: OnboardingDraftStore

    @State private var isFinishing = false
    /// Flipped once, a beat after the screen appears, and it drives all
    /// three of the celebration: the mark's pop, the burst, and the haptic.
    /// One trigger rather than three keeps them in step — the haptic landing
    /// a frame before the confetti is the difference between a celebration
    /// and a glitch.
    @State private var hasLanded = false
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    /// A breath before it fires. The view appears while the previous screen
    /// is still animating out, and a burst that starts during that
    /// transition is a burst nobody sees the start of.
    private static let celebrationDelay = Duration.milliseconds(250)

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            // Full-bleed and behind everything: the pieces start at the
            // centre — where the mark is — and have to be free to travel
            // past the safe area, or the burst stops in a rectangle that
            // is visibly not the screen.
            ConfettiBurst(isActive: hasLanded)
                .ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxl) {
                Spacer(minLength: 0)

                VStack(spacing: AppTheme.Spacing.l) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTheme.Typography.Number.display(
                            AppTheme.Typography.Number.metric, weight: .regular, scale: typeScale
                        ))
                        .foregroundStyle(AppTheme.Palette.statusPositive)
                        // Lands rather than appears. The spring overshoots
                        // slightly, which is what makes it read as a stamp
                        // coming down instead of an image fading in.
                        .scaleEffect(hasLanded ? 1 : 0.5)
                        .opacity(hasLanded ? 1 : 0)
                        .animation(AppTheme.Motion.standard, value: hasLanded)

                    Text(greeting)
                        .font(AppTheme.Typography.Number.display(
                            AppTheme.Typography.Number.metricCompact, weight: .bold, scale: typeScale
                        ))
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                }

                // Centred with the mark rather than pinned to the bottom
                // edge. There is nothing else on this screen and nothing
                // left to answer, so a button held at arm's length from the
                // only other thing present just looked stranded.
                OnboardingPrimaryButton(title: "Go to my Keepo", isLoading: isFinishing, fillsWidth: true) {
                    Task { await finish() }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
        }
        // Fires whether or not the confetti does: Reduce Motion suppresses
        // the pieces, and a success the user cannot see is exactly when the
        // one they can feel matters most.
        .sensoryFeedback(AppTheme.Feedback.success, trigger: hasLanded)
        .task {
            try? await Task.sleep(for: Self.celebrationDelay)
            hasLanded = true
        }
    }

    /// The name is read from the **draft**, not the profile: the profile on
    /// this device is still the one fetched before setup ran, and the whole
    /// point of the greeting is that Keepo now knows who they are. A user
    /// who skipped step 1 gets the unnamed version rather than a blank.
    private var greeting: String {
        guard let name = store.draft.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "You're all set"
        }
        return "You're all set, \(name)"
    }

    /// Clears the draft **before** the refresh, not after: the refresh is
    /// what tears this view down, so anything sequenced behind it is racing
    /// its own teardown. Everything in the draft is already committed by
    /// the time this screen exists, so there is nothing left to lose.
    private func finish() async {
        isFinishing = true
        store.clear()
        try? await session.refreshProfile()
    }
}
