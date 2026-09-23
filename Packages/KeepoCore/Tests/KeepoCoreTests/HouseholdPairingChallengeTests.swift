import Foundation
import Testing
@testable import KeepoCore

/// The attempt budget from security audit finding 6.
///
/// This is the half of the pairing code that is easy to get wrong and
/// impossible to notice: a code still *looks* like it works with a broken
/// budget, right up until somebody guesses it. Everything here is about
/// guesses being spent and staying spent.
@Suite("HouseholdPairingChallenge")
struct HouseholdPairingChallengeTests {
    private static let known = HouseholdPairingCode(digits: "034812")!

    @Test("the right code is accepted")
    func acceptsTheRightCode() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        #expect(challenge.judge("034812") == .accepted)
        #expect(challenge.isVerified)
    }

    @Test("a wrong code spends one try and says how many are left")
    func spendsOneTry() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        let budget = HouseholdPairingCode.maxAttempts
        #expect(challenge.judge("000000") == .rejected(remainingAttempts: budget - 1))
        #expect(challenge.remainingAttempts == budget - 1)
        #expect(!challenge.isVerified)
    }

    /// The whole point. Six digits is a million only while the budget holds.
    @Test("the budget runs out, and the last wrong guess ends it")
    func budgetRunsOut() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        for attempt in 1..<HouseholdPairingCode.maxAttempts {
            let remaining = HouseholdPairingCode.maxAttempts - attempt
            #expect(challenge.judge("000000") == .rejected(remainingAttempts: remaining))
        }
        #expect(challenge.judge("000000") == .exhausted)
        #expect(challenge.remainingAttempts == 0)
    }

    /// An exhausted challenge is over for good. If this ever returns
    /// `.accepted`, an attacker who has burned the budget simply keeps
    /// going — and the cap was decoration.
    @Test("an exhausted challenge refuses even the right code")
    func exhaustedRefusesEverything() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        for _ in 0..<HouseholdPairingCode.maxAttempts { _ = challenge.judge("000000") }

        #expect(challenge.judge("034812") == .exhausted)
        #expect(challenge.judge("034812") == .exhausted)
        #expect(!challenge.isVerified)
    }

    /// Guessing right at the end must not launder the failures before it.
    @Test("a correct guess does not refund the tries already spent")
    func correctGuessDoesNotRefundBudget() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        _ = challenge.judge("000000")
        _ = challenge.judge("111111")
        let spent = HouseholdPairingCode.maxAttempts - 2
        #expect(challenge.remainingAttempts == spent)

        #expect(challenge.judge("034812") == .accepted)
        #expect(challenge.remainingAttempts == spent, "a correct guess reset the budget")
    }

    @Test("re-answering an already-verified challenge costs nothing")
    func verifiedIsIdempotent() {
        var challenge = HouseholdPairingChallenge(code: Self.known)
        #expect(challenge.judge("034812") == .accepted)
        let remaining = challenge.remainingAttempts

        // A flapping link should not re-spend the budget, and — more to the
        // point — must not let a *wrong* code unverify a challenge that has
        // already been answered.
        #expect(challenge.judge("999999") == .accepted)
        #expect(challenge.remainingAttempts == remaining)
        #expect(challenge.isVerified)
    }

    @Test("a fresh challenge starts with the full budget and no verdict")
    func startsClean() {
        let challenge = HouseholdPairingChallenge(code: Self.known)
        #expect(challenge.remainingAttempts == HouseholdPairingCode.maxAttempts)
        #expect(!challenge.isVerified)
    }

    @Test("a challenge made without an explicit code mints a usable one")
    func mintsItsOwnCode() {
        var challenge = HouseholdPairingChallenge()
        #expect(challenge.code.digits.count == HouseholdPairingCode.digitCount)
        #expect(challenge.judge(challenge.code.digits) == .accepted)
    }
}
