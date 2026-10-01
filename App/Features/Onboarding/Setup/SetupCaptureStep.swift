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
/// **Why the notification ask now comes last.** It used to be first, on the
/// argument that a capture's whole review surface is a notification, so a
/// permission granted before the walkthrough is one the test at the end can
/// demonstrate. True, and beside the point: the very first thing the step
/// did was ask for a system permission to support a feature the user had
/// not yet been told about, let alone agreed to set up. Priming before
/// asking is the HIG rule, and the strongest possible priming for "let
/// Keepo notify you about captured purchases" is having just watched a
/// captured purchase arrive. Now the ask lands on someone who either ran
/// the test or explicitly deferred the feature — in both cases, someone who
/// knows what the notification is for.
struct SetupCaptureStep: View {
    let session: SessionStore
    let store: OnboardingDraftStore

    /// `draft.walkthroughStep` holds the raw value, so these are stable.
    enum SubStep: Int {
        case intro = 0
        case walkthrough = 1
        case verify = 2
        case notifications = 3
    }

    private var subStep: SubStep {
        SubStep(rawValue: store.draft.walkthroughStep) ?? .intro
    }

    var body: some View {
        switch subStep {
        case .intro:
            SetupCaptureIntroSubStep(
                onSetUpNow: { go(.walkthrough) },
                // Straight past both the walkthrough and the test, to the
                // one part of this step that stands on its own.
                onSetUpLater: { go(.notifications) },
                onBack: store.goBack
            )
        case .walkthrough:
            SetupWalkthroughSubStep(onNext: { go(.verify) }, onBack: { go(.intro) })
        case .verify:
            SetupCaptureTestSubStep(
                session: session, store: store,
                onNext: { go(.notifications) }, onBack: { go(.walkthrough) }
            )
        case .notifications:
            // Back goes to the **intro**, not to whichever screen happened
            // to precede this one. The intro is this step's hub — it is
            // where both paths start and the only place the choice can be
            // changed — and sending someone back into a walkthrough they
            // already completed would be answering "I want to reconsider"
            // with "do it again".
            SetupNotificationsSubStep(store: store, onNext: finish, onBack: { go(.intro) })
        }
    }

    private func go(_ next: SubStep) {
        store.update { $0.walkthroughStep = next.rawValue }
    }

    /// Leaving step 4 resets the sub-step, so a user who comes *back* to it
    /// with the chrome's Back button lands on its first screen rather than
    /// on the notification ask they already answered.
    private func finish() {
        store.update { $0.walkthroughStep = 0 }
        store.advance()
    }
}
