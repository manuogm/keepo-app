import KeepoCore
import SwiftUI
import UIKit

/// The one point in setup that writes anything.
///
/// Six screens collect a draft and none of them touch the server. The flow
/// this replaces wrote the account and completed onboarding from inside its
/// fourth step, so abandoning afterwards left an orphan account behind and
/// Back was only correct by accident. Everything happens here instead,
/// which buys three things at once: Back is trivially correct on every
/// step, an abandoned flow leaves nothing at all, and failure is handled in
/// one place rather than four.
///
/// **Nothing here refreshes the profile.** That is what flips
/// `SessionStore.phase` to `.ready`, and the instant it does, `RootView`
/// swaps `MainTabView` in and tears this view down — cancelling the very
/// task that is running the commit, mid-write. It is also why this calls
/// `ProfileRepository.completeOnboarding` directly rather than
/// `SessionStore`'s wrapper, which refreshed immediately by design: the
/// wrapper existed for the old flow and was removed with it. The refresh
/// is the last act of `SetupAllSetView`, on a tap.
struct SetupCommitView: View {
    let session: SessionStore
    let store: OnboardingDraftStore

    /// Its own instance rather than the one `MainTabView` owns, which does
    /// not exist yet at this point in the flow. Nothing is lost by that:
    /// the upload writes through to the profile and to the on-disk cache,
    /// so the store the signed-in app builds a moment later finds the
    /// picture already there.
    @State private var avatars = AvatarStore()
    @State private var errorMessage: String?
    /// Worked out once and kept, so **Try Again is the same writes**.
    /// `SetupCommitPlan` mints a fresh id per category, so rebuilding it on
    /// a retry would write a second full set of them — the account is safe
    /// either way (its id comes from the draft) but the categories are not.
    @State private var plan: SetupCommitPlan?
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            // The same curtain `MappedCardSheet` uses — translucent
            // material over a black at `Opacity.fill`, never a flat scrim.
            // It reads as something laid over the flow rather than as a
            // ninth screen, which is what this is: the six answers are
            // still behind it, and if the commit fails the user goes back
            // to them rather than starting again.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(AppTheme.Opacity.fill))
                .ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xl) {
                if let errorMessage {
                    failure(errorMessage)
                } else {
                    working
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .frame(maxWidth: AppTheme.Size.proseWidth)
        }
        // Keyed on nothing, so a retry has to go through `run()` explicitly
        // rather than through a state change that happens to re-fire this.
        .task {
            // Recorded before the writes start, not after: if iOS kills the
            // app mid-commit, the next launch resumes here and runs it
            // again — which is safe precisely because every id in the plan
            // comes from the draft.
            store.update { $0.step = .committing }
            await run()
        }
    }

    private var working: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            ProgressView()
                .controlSize(.large)
            Text("Setting up your Keepo")
                .font(AppTheme.Typography.Number.display(
                    AppTheme.Typography.Number.metricCompact, weight: .bold, scale: typeScale
                ))
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text("Saving your profile, your first account and your categories.")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The draft is untouched on failure, so Try Again is a real second
    /// attempt and not a restart — the user does not retype six screens
    /// because a network dropped.
    private func failure(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppTheme.Typography.screenTitle.weight(.regular))
                .foregroundStyle(AppTheme.Palette.statusNegative)
            Text("That didn't save")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text(message)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Text("Nothing you entered has been lost.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)

            PrimaryActionButton(title: "Try Again", fillsWidth: true) {
                Task { await run() }
            }
            SecondaryActionButton(title: "Back") {
                errorMessage = nil
                store.update { $0.step = .account }
            }
        }
    }

    // MARK: - The commit

    private func run() async {
        errorMessage = nil
        guard let userId = session.profile?.id else {
            errorMessage = "You are not signed in."
            return
        }
        guard let plan = plan ?? SetupCommitPlan.make(draft: store.draft, userId: userId) else {
            // Unreachable from the UI — the currency step cannot be left
            // without a currency, and Skip there accepts the wheel's value.
            // Kept because the alternative is a patch the database rejects
            // with a CHECK violation the user cannot act on.
            errorMessage = "Keepo still needs a base currency."
            store.update { $0.step = .currency }
            return
        }
        self.plan = plan

        await uploadAvatar(plan)

        // The only hard stop. Everything below it is either local-first or
        // device-local and cannot meaningfully fail; this is the write that
        // makes the user onboarded at all.
        do {
            try await ProfileRepository.completeOnboarding(
                client: session.client, userId: userId,
                baseCurrency: plan.baseCurrency, displayName: plan.displayName
            )
        } catch {
            errorMessage = UserFacingError.describe(error)
            return
        }

        await writeLocalFirst(plan)

        // **The profile is deliberately NOT refreshed here.** That is what
        // flips `phase` to `.ready`, and doing it now would drop the user
        // straight into the app — skipping the one screen that tells them
        // the setup they just spent two minutes on actually worked.
        // `SetupAllSetView` does it, on a tap, as the last act of the flow,
        // with nothing left after it to interrupt. The draft stays for the
        // same reason: that screen greets them by the name in it, and the
        // server copy has not been re-read yet.
        store.update { $0.step = .allSet }
    }

    /// Failure here is swallowed on purpose. A photo that did not upload is
    /// worth one line in Profile, not a wall between the user and the app
    /// they just spent two minutes setting up — and the avatar picker on
    /// that screen is the same control, so the retry already exists.
    ///
    /// It runs **before** the profile patch, which is what keeps the
    /// internal `refreshProfile()` inside `AvatarStore.replace` harmless:
    /// `onboarded_at` is still null at this point, so that refresh cannot
    /// flip the phase and pull this screen out from under the commit.
    private func uploadAvatar(_ plan: SetupCommitPlan) async {
        guard let data = plan.avatarJPEG, let image = UIImage(data: data) else { return }
        _ = await avatars.replace(with: image, session: session)
    }

    /// Account, then categories, then the dashboard. The first two go
    /// through the outbox, so they are durable on this device the moment
    /// they are submitted and drain to the server on their own; the third
    /// is `UserDefaults`. None of them has a failure worth surfacing.
    private func writeLocalFirst(_ plan: SetupCommitPlan) async {
        if let account = plan.account {
            await session.outbox.submitCreateAccount(account)
        }
        for category in plan.categories {
            await session.outbox.submitCreateCategory(category)
        }
        DashboardStore().replace(kinds: plan.widgets)
    }
}
