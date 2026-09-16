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
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxl) {
                Spacer(minLength: 0)

                VStack(spacing: AppTheme.Spacing.l) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTheme.Typography.Number.display(
                            AppTheme.Typography.Number.metric, weight: .regular, scale: typeScale
                        ))
                        .foregroundStyle(AppTheme.Palette.statusPositive)

                    Text(greeting)
                        .font(AppTheme.Typography.Number.display(
                            AppTheme.Typography.Number.metricCompact, weight: .bold, scale: typeScale
                        ))
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(summary)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppTheme.Size.proseWidth)
                }

                Spacer(minLength: 0)

                OnboardingPrimaryButton(title: "Go to my Keepo", isLoading: isFinishing, fillsWidth: true) {
                    Task { await finish() }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
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

    /// Says what was actually built, from the draft — so it cannot promise
    /// an account or categories a skipped step never created.
    private var summary: String {
        var built: [String] = []
        if let account = store.draft.account, !account.name.trimmingCharacters(in: .whitespaces).isEmpty {
            built.append(account.name)
        }
        let categories = store.draft.selectedCategories.count
        if categories > 0 {
            built.append("\(categories) categories")
        }
        let widgets = store.draft.selectedMetrics.count
        if widgets > 0 {
            built.append(widgets == 1 ? "1 widget" : "\(widgets) widgets")
        }
        guard !built.isEmpty else { return "Keepo is ready." }
        return "\(ListFormatter.localizedString(byJoining: built)) — ready and waiting."
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
