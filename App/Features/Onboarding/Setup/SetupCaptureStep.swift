import KeepoCore
import SwiftUI

/// Step 4 — the one that makes Keepo Keepo, and the only step that sends
/// the user out of the app.
///
/// Three sub-steps, persisted in `draft.walkthroughStep`, because the
/// middle one hands the user to Shortcuts for minutes at a time and iOS is
/// free to terminate Keepo while they are gone. Coming back to sub-step 1
/// of 3 is the flow working; coming back to the first screen of setup is
/// the flow having lost three minutes of their work.
///
/// Why the order is this order: the notification ask comes **first** and
/// behind an explicit button, because a capture's entire review surface is
/// a notification — a permission granted before the walkthrough is a
/// permission the test at the end can actually demonstrate. Priming before
/// asking is HIG guidance and measurably better for grant rate; a system
/// sheet that appears because a timer expired is an ambush.
struct SetupCaptureStep: View {
    let session: SessionStore
    let store: OnboardingDraftStore

    /// `draft.walkthroughStep` holds the raw value, so these are stable.
    enum SubStep: Int {
        case notifications = 0
        case walkthrough = 1
        case verify = 2
    }

    private var subStep: SubStep {
        SubStep(rawValue: store.draft.walkthroughStep) ?? .notifications
    }

    var body: some View {
        switch subStep {
        case .notifications:
            SetupNotificationsSubStep(store: store, onNext: { go(.walkthrough) }, onBack: store.goBack)
        case .walkthrough:
            SetupWalkthroughSubStep(
                store: store, onNext: { go(.verify) },
                onBack: { go(.notifications) }, onSkipStep: { finish() }
            )
        case .verify:
            SetupCaptureTestSubStep(
                session: session, store: store,
                onNext: { finish() }, onBack: { go(.walkthrough) }
            )
        }
    }

    private func go(_ next: SubStep) {
        store.update { $0.walkthroughStep = next.rawValue }
    }

    /// Leaving step 4 resets the sub-step, so a user who comes *back* to it
    /// with the chrome's Back button lands on its first screen rather than
    /// on the test they already ran.
    private func finish() {
        store.update { $0.walkthroughStep = 0 }
        store.advance()
    }
}
