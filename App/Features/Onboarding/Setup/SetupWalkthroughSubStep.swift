import KeepoCore
import SwiftUI

/// Step 4b — get the shortcut, then point a Wallet automation at it.
///
/// **This used to be the part where setup went wrong.** The old procedure
/// had the user build the action themselves and drag `Merchant`, `Amount`
/// and `Card or Pass` into it by hand — six steps, three of them
/// mistypeable, and a mis-wired field produces no error at all: purchases
/// simply never arrive. Publishing the shortcut prebuilt deleted that
/// entire half. What is left is four taps with nothing to map.
///
/// The screen renders `ShortcutsWalkthroughView`, which renders
/// `ShortcutsWalkthrough` — the same model Profile → My Automations
/// renders, so there is one copy of these instructions in the app and
/// re-recording the clips is the only cost when Shortcuts moves a button.
struct SetupWalkthroughSubStep: View {
    let onNext: () -> Void
    let onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Set up automatic capture",
            subtitle: "Add Keepo's shortcut, then point a Wallet automation at it. You'll leave the "
                + "app for a minute — Keepo picks up right here.",
            step: .capture,
            onBack: onBack,
            primaryTitle: "I've done that",
            onPrimary: onNext
        ) {
            ShortcutsWalkthroughView()
        }
    }
}
