import KeepoCore
import SwiftUI

/// The setup half of onboarding: the screens that run after sign-in and
/// before the app, and the draft they all write into.
///
/// It owns three things and delegates the rest. The **draft store**, which
/// is what makes Back correct and termination survivable. The **currency
/// list**, loaded once here rather than twice — steps 2 and 3 both need it,
/// and two copies of the same query against the same mirror is the kind of
/// duplication that goes wrong when only one of them is fixed. And the
/// **routing**, which is a switch on the draft's own step, so "where am I"
/// has exactly one answer and it is the one that was persisted.
struct SetupFlowView: View {
    let session: SessionStore

    @State private var store = OnboardingDraftStore()
    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var isShowingResumeNote = false

    var body: some View {
        ZStack {
            switch store.draft.step {
            case .profile:
                SetupProfileStep(session: session, store: store)
            case .currency:
                SetupCurrencyStep(store: store, currencies: currencies)
            case .account:
                SetupAccountStep(store: store, currencies: currencies)
            case .capture:
                SetupCaptureStep(session: session, store: store)
            case .categories:
                SetupCategoriesStep(store: store)
            case .dashboard:
                SetupDashboardStep(store: store)
            case .committing:
                SetupCommitView(session: session, store: store)
            case .allSet:
                SetupAllSetView(session: session, store: store)
            }
        }
        .animation(AppTheme.Motion.standard, value: store.draft.step)
        // Keyed on the refresh token for a reason the old flow discovered
        // the hard way: on a **fresh install** the first sync pull has not
        // landed when this appears, so a one-shot read finds no currencies
        // and step 2 dead-ends on an empty wheel with a dead Next button,
        // recoverable only by relaunching. `syncNow` bumps the token when
        // the pull completes, which re-fires this.
        .task(id: session.refresh.token) {
            currencies = (try? await session.dbQueue.read { database in
                try LocalTableQueries.currencies(database)
            }) ?? []
        }
        .overlay(alignment: .bottom) {
            if isShowingResumeNote {
                resumeNote
            }
        }
        .task {
            guard store.didResume else { return }
            isShowingResumeNote = true
            try? await Task.sleep(for: .seconds(3))
            isShowingResumeNote = false
        }
    }

    /// Shown once, and only to someone who actually left mid-flow. Without
    /// it, being dropped onto step 4 of 6 with no explanation reads as the
    /// app having lost the first three.
    private var resumeNote: some View {
        Text("Picking up where you left off")
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Palette.bgSurfaceRaised, in: Capsule())
            .elevation(.floating)
            // A toast, above the bottom bar — the one strip of these
            // screens with nothing in it. It sat at the top first, where it
            // covered the progress dots; nudged down from there it landed
            // on the title instead, because a two-line title starts exactly
            // there. Every position at the top of a setup step is occupied
            // by something the user needs at that moment.
            .padding(.bottom, AppTheme.Size.touchTarget + AppTheme.Spacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(AppTheme.Motion.standard, value: isShowingResumeNote)
    }
}
