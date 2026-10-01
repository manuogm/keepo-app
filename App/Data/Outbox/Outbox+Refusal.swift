import Foundation
import KeepoCore

// What happens when the server refuses a write outright — split out of
// Outbox.swift for its file-length lint, same precedent as Outbox+Retry.swift.
extension Outbox {
    /// A refused write is final: it is not queued (or is dropped from the
    /// queue), the user is told, and the mirror is marked for a full
    /// re-sync, because the optimistic copy the write left there describes
    /// something the server never accepted.
    ///
    /// Before this, every failure was retried forever. A refusal therefore
    /// never landed, never cleared, and left its optimistic copy on screen
    /// indefinitely — a transfer edit addressed by the wrong group id, a
    /// delete sent to the wrong RPC, a transfer between accounts the
    /// integrity trigger would never accept — each "saved" on the phone and
    /// silently absent on the server, with a pending-sync banner as the only
    /// clue.
    func recordRefusal(_ error: Error) {
        refusal = OutboxRefusal(message: UserFacingError.describe(error))
        needsFullResync = true
        onRefusal?()
    }

    /// The alert has been seen.
    public func dismissRefusal() {
        refusal = nil
    }

    /// The full re-sync `needsFullResync` asked for has happened.
    func markResynced() {
        needsFullResync = false
    }
}
