import Foundation

/// A pairing code and the budget of wrong guesses that goes with it.
///
/// The two belong in one type because neither is safe without the other:
/// `HouseholdPairingCode.maxAttempts` explains why six digits is a
/// meaningful secret only while guessing is capped, and a cap kept somewhere
/// else is a cap somebody eventually forgets to apply. Holding them together
/// also means the rule can be tested here, at a desk, rather than only by
/// putting two phones on a table.
///
/// **Lifetime is the security property.** One challenge belongs to one
/// pairing session, and it must outlive the peer disconnecting — see
/// `HouseholdPairingSession`, which holds it for as long as the discovery
/// screen is up. A challenge created per connection is a budget the other
/// phone refills by hanging up, which is the same as having no budget.
public struct HouseholdPairingChallenge: Sendable {
    public let code: HouseholdPairingCode
    public private(set) var remainingAttempts: Int
    /// Sticky once true: the digits were right, and the peer does not have
    /// to prove it again if the link flaps.
    public private(set) var isVerified = false

    public enum Verdict: Equatable, Sendable {
        /// Right. Identities may now cross.
        case accepted
        /// Wrong, with tries left.
        case rejected(remainingAttempts: Int)
        /// Wrong, and out of tries. The session is over and the code is
        /// spent — the caller starts a new one rather than retrying.
        case exhausted
    }

    public init(code: HouseholdPairingCode = .generate()) {
        self.code = code
        self.remainingAttempts = HouseholdPairingCode.maxAttempts
    }

    /// Judges one guess, spending a try unless the answer is already known.
    ///
    /// Note what does **not** happen on a correct guess: the budget is not
    /// refunded and not reset. There is nothing to reset it for — the
    /// challenge is answered — and a reset here would be a way to launder
    /// spent attempts by guessing right once at the end.
    public mutating func judge(_ entered: String) -> Verdict {
        if isVerified { return .accepted }
        guard remainingAttempts > 0 else { return .exhausted }

        if code.matches(entered) {
            isVerified = true
            return .accepted
        }

        remainingAttempts -= 1
        return remainingAttempts > 0 ? .rejected(remainingAttempts: remainingAttempts) : .exhausted
    }
}
