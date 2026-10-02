import KeepoCore
import SwiftUI

/// Step 3a — the pitch, and the fork.
///
/// **The step used to open with work.** The first thing it did was hand the
/// user a permission prompt and then send them to Shortcuts, before
/// anything had explained why either was worth doing. Setting up a Wallet
/// automation is the most effortful minute in the whole of onboarding, and
/// it was the one minute asked for with the least context.
///
/// So this screen sells it and then asks. Two answers, both real: **Set up
/// now** runs the walkthrough and the test; **Skip** goes straight past
/// both, and is not a lesser answer — capture lives in Profile → My
/// Automations unchanged, and everything else in Keepo works without it.
/// Offering a genuine way out here is also what lets the two screens behind
/// it drop their Skip entirely: a user who starts the setup has already
/// been given the way out, and one more escape hatch halfway through an
/// installation is how people end up with a half-built automation.
///
/// The answer to "later" is the chrome's Skip, the same control every other
/// optional step uses, rather than a second button stacked under the
/// first: one primary action in the scaffold's bottom bar — the same place
/// every other step's forward button sits — and the escape where the user
/// already looks for it.
struct SetupCaptureIntroSubStep: View {
    let onSetUpNow: () -> Void
    let onSetUpLater: () -> Void
    let onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: CapturePitch.title,
            subtitle: CapturePitch.subtitle,
            step: .capture,
            onBack: onBack,
            onSkip: onSetUpLater,
            primaryTitle: CapturePitch.setUpTitle,
            primaryFillsWidth: true,
            onPrimary: onSetUpNow
        ) {
            // Floats in the space between the heading and the bar — the
            // scaffold's default — so the drawing is centred in what is
            // left rather than pinned under the subtitle.
            CapturePitch.illustration
        }
    }
}
