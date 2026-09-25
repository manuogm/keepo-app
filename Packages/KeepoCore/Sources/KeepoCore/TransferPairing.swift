import Foundation

/// Which two accounts a transfer may join.
///
/// `check_transfer_integrity` enforces this at commit, and until this type
/// existed that was the only place it lived: the transaction form offered
/// every account the user could see on both ends, including a private one
/// paired with the partner's shared account, which the trigger rejects every
/// time. The save "worked" on screen — the outbox's write-through had already
/// put both legs in the local mirror — and the create then retried against
/// the server forever. Stating the rule here lets a picker ask it first; the
/// trigger stays the authority.
///
/// The rule is the trigger's, word for word: **one owner, or both accounts
/// shared into the same household.** "The same household" needs no field of
/// its own on the client, because a user belongs to one household at most
/// and an account the viewer can see that is not theirs is, by construction,
/// shared into that one.
public enum TransferPairing {
    /// The rule reads an account's owner and whether it is shared.
    public typealias Side = AccountSharing

    public static func allows(_ source: Side, _ destination: Side) -> Bool {
        source.ownerId == destination.ownerId || (source.isShared && destination.isShared)
    }
}
