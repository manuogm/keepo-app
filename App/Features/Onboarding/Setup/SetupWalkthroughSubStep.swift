import KeepoCore
import SwiftUI

/// Step 4b — get the shortcut, then point a Wallet automation at it, as a
/// list of things to do rather than a page to read.
///
/// **This used to be the part where setup went wrong.** The old procedure
/// had the user build the action themselves and drag `Merchant`, `Amount`
/// and `Card or Pass` into it by hand — six steps, three of them
/// mistypeable, and a mis-wired field produces no error at all: purchases
/// simply never arrive. Publishing the shortcut prebuilt deleted that
/// entire half. What is left is four steps with nothing to map.
///
/// The four are `CaptureSetupChecklist`, reading `ShortcutsWalkthrough` —
/// still the only copy of these instructions in the app, and still what
/// Profile → My Automations renders, there as reference rather than as
/// tasks.
///
/// **Next is gated on the list being finished**, which is the one place in
/// onboarding where that is the right call. Every step happens in another
/// app, so Keepo cannot tell whether any of it was done; the ticks are the
/// user telling it. A forward button that worked regardless would send
/// people to a connection test that was never going to pass, and the whole
/// reason this step has no Skip is that the way out is one screen back, at
/// "Set up later".
struct SetupWalkthroughSubStep: View {
    let onNext: () -> Void
    let onBack: () -> Void

    /// Persisted rather than `@State`: the user leaves for the Shortcuts
    /// app on every one of these steps, and iOS is free to terminate Keepo
    /// while they are gone. Coming back to a list that forgot two ticks is
    /// the same class of loss the draft itself exists to prevent.
    @AppStorage(AppSettingsKeys.walkthroughCompleted) private var completedRaw = ""

    var body: some View {
        OnboardingScaffold(
            title: "Set up automatic capture",
            step: .capture,
            onBack: onBack,
            primaryTitle: "I've done that",
            isPrimaryEnabled: isFinished,
            onPrimary: onNext
        ) {
            CaptureSetupChecklist(completed: completedBinding)
        }
    }

    private var completed: Set<Int> {
        Set(completedRaw.split(separator: ",").compactMap { Int($0) })
    }

    private var isFinished: Bool {
        ShortcutsWalkthrough.steps.allSatisfy { completed.contains($0.id) }
    }

    /// Sorted and comma-joined, so the stored form is stable and a diff of
    /// `UserDefaults` says something a human can read.
    private var completedBinding: Binding<Set<Int>> {
        Binding(
            get: { completed },
            set: { completedRaw = $0.sorted().map(String.init).joined(separator: ",") }
        )
    }
}
