import KeepoCore
import SwiftUI

/// Welcome → the four features → sign in.
///
/// **It runs before sign-in**, on `SessionStore.phase == .needsSignIn`,
/// because there is no account yet to hang any of it off. That is also why
/// `hasSeenIntro` is device-local: the only thing that could remember it
/// is the device.
///
/// The flag is set when the user **reaches** sign-in, not when they finish
/// signing in — someone who read the pitch, decided to think about it, and
/// came back tomorrow has already seen it, and showing it again would be
/// marketing at somebody who is trying to log in.
struct IntroFlowView: View {
    let session: SessionStore

    private enum Phase { case welcome, features, signIn }

    @AppStorage(AppSettingsKeys.hasSeenIntro) private var hasSeenIntro = false
    @State private var phase: Phase = .welcome

    var body: some View {
        Group {
            switch phase {
            case .welcome:
                WelcomeView { advance(to: .features) }
            case .features:
                FeatureDeckView {
                    hasSeenIntro = true
                    advance(to: .signIn)
                }
            case .signIn:
                OTPSignInView(session: session)
            }
        }
        // The whole flow is one screen deep, so the phases cross-fade
        // rather than push: nothing here is a hierarchy to navigate back
        // through, and a navigation stack would offer a back button to a
        // pitch the user has already accepted.
        .transition(.opacity)
    }

    private func advance(to next: Phase) {
        withAnimation(AppTheme.Motion.standard) { phase = next }
    }
}
