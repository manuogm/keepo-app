import KeepoCore
import StoreKit
import SwiftUI

/// Asks for a rating, on a clean foreground beat, if `ReviewPolicy` says
/// this is a moment to ask.
///
/// **The ask and the condition are deliberately separate events.** The
/// condition is decided at the write that resolved a capture
/// (`ReviewPrompter.recordCaptureResolved`), which happens just as often
/// with the app backgrounded — a quick action from a notification — as with
/// it open. A prompt fired there would be fired at nobody, and a rule that
/// watched the inbox count for a 1 → 0 transition would never observe that
/// clear at all. So the write arms; this asks.
///
/// **A settled beat, not merely politeness.** `requestReview` requires a
/// foreground-active scene and silently does nothing otherwise — and Apple
/// does not document whether that no-op still consumes one of the three
/// displays it allows per year, so a call made at the wrong moment is pure
/// downside. Waiting also keeps it off the back of whatever gesture the
/// user just made.
///
/// **Read nothing into what you see while testing**: the system always
/// displays this in debug builds, never in TestFlight, and only sometimes
/// in App Store builds.
private struct ReviewPromptModifier: ViewModifier {
    /// `profiles.created_at` — the fallback's clock, which already exists
    /// rather than being a local first-launch key this would have to invent.
    let signedUpAt: Date?
    /// Suppressed while the Profile sheet (or anything else) is up: a
    /// system alert over a modal is the definition of an interruption.
    let isPresentingModal: Bool

    /// Long enough that the screen has settled and short enough that the
    /// prompt still reads as part of arriving, rather than as something
    /// that ambushed a user already doing something else.
    private static let settle = Duration.seconds(2)

    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: beat) { await askIfDue() }
    }

    /// Re-fires the wait on every change that could make this the right
    /// moment — and cancels the pending one when it stops being.
    private var beat: Beat {
        Beat(isActive: scenePhase == .active, isPresentingModal: isPresentingModal)
    }

    private struct Beat: Equatable {
        let isActive: Bool
        let isPresentingModal: Bool
    }

    private func askIfDue() async {
        guard beat.isActive, !beat.isPresentingModal else { return }
        guard ReviewPrompter.isDue(signedUpAt: signedUpAt) else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }
        // Re-checked after the wait: the user may have opened the Profile
        // sheet or backgrounded the app during it, and `task(id:)` only
        // cancels — it cannot un-call something already called.
        guard beat.isActive, !beat.isPresentingModal else { return }
        requestReview()
        // Recorded whether or not anything appeared, because there is no
        // way to find out and a call that showed nothing still has to start
        // the re-ask clock. Clearing the armed flag here is what makes each
        // arming one-shot.
        ReviewPrompter.markAsked()
    }
}

extension View {
    func reviewPrompt(signedUpAt: Date?, isPresentingModal: Bool) -> some View {
        modifier(ReviewPromptModifier(signedUpAt: signedUpAt, isPresentingModal: isPresentingModal))
    }
}
