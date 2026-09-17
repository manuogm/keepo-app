import KeepoCore
import SwiftUI

/// Step 4c — the connection test, wearing onboarding's chrome.
///
/// The test itself is `CaptureConnectionTestView`, which carries its own
/// actions and knows nothing about where it is drawn: Profile → My
/// Automations runs the identical round trip with no scaffold around it,
/// and a version whose forward action lived in the bottom bar would have
/// had to exist twice.
///
/// **No Skip and no forward button**, which is the whole shape of this
/// screen. The way out of capture setup is two taps back, at the intro's
/// "Set up later"; an escape offered here mostly produces half-built
/// automations, and there is nothing to press while the test runs itself.
struct SetupCaptureTestSubStep: View {
    let session: SessionStore
    let store: OnboardingDraftStore
    let onNext: () -> Void
    let onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            // **No heading.** The content is the headline: it says it is
            // testing while it runs, and celebrates when it lands. A title
            // over that was a second, quieter version of the same sentence.
            title: nil,
            step: .capture,
            onBack: onBack,
            isPrimaryVisible: false,
            onPrimary: onNext,
            content: {
                CaptureConnectionTestView(session: session, onFinished: onNext)
            }
        )
    }
}
