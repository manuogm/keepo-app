import KeepoCore
import SwiftUI

// How a ceremony ends when it does not end well — the user backing out, or a
// step failing. Split out of `HouseholdSetupCoordinator.swift` for the
// project's file-length lint, and a fair seam on its own: everything in that
// file is about getting a household built, and everything here is about
// undoing one that will not be.

@MainActor
extension HouseholdSetupCoordinator {
    /// The run ended badly. Says so on this screen and tells the other
    /// phone — unless this side is the one that stopped it, in which case
    /// both have already been done and the person reading does not need to be
    /// told what they just chose.
    func report(_ message: String) async {
        // Not over a household that was actually built: the owner's inbox
        // stays open through the report, and a link torn down after Finish
        // must not repaint a finished ceremony as a failed one.
        guard !didAbort, outcome != .finished else { return }
        conclude(message)
        pairing.send(.cancelled(reason: message))

        // A household nobody ever joined, under a screen that has just said
        // it was not built, is a single-member household the user never asked
        // for — `HouseholdQRView.discardIfUnused`'s rule, for the same reason.
        //
        // Once the guest **has** joined it is left alone. A transient failure
        // in the last step of the ceremony is not grounds for dissolving a
        // household that genuinely exists; the Household screen will show it,
        // and leaving is a decision for the person, not for an error handler.
        if didCreateHousehold && !hasJoined {
            try? await HouseholdRepository.leave(client: session.client)
            await session.syncNow()
            session.refresh.bump()
        }
    }

    /// The user backed out, from either phone and at any point.
    ///
    /// Until this existed the ceremony was a one-way door: both screens are
    /// full-screen covers with no chrome, and the only way out was to finish
    /// or to have the link drop.
    ///
    /// The undo is the same wherever it is called from — **if this device is
    /// in a household this run put it in, leave it**. On a household nobody
    /// joined that retires the membership and nothing else; on one the guest
    /// has already joined, `leave_household` ends it for both, which is what
    /// an abort after the join has to mean. A household the user already had
    /// and nobody joined is left alone: it was never this screen's.
    ///
    /// Swallowed, because the other phone may have got there first and
    /// dissolved it already — and "you are not a member" is the outcome being
    /// asked for, not a failure to report.
    func abort() async {
        guard !didAbort else { return }
        didAbort = true
        pairing.send(.cancelled(reason: nil))
        if didCreateHousehold || hasJoined {
            try? await HouseholdRepository.leave(client: session.client)
            await session.syncNow()
            session.refresh.bump()
        }
        pairing.stop()
        conclude("You stopped building the household.")
    }
}
