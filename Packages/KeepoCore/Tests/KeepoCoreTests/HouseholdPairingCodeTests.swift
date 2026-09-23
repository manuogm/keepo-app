import Foundation
import Testing
@testable import KeepoCore

/// The pairing code from security audit finding 6. These assertions are the
/// properties the code's security rests on, not its formatting — a code that
/// is short, predictable or leaky through a comparison is a code that buys
/// nothing.
@Suite("HouseholdPairingCode")
struct HouseholdPairingCodeTests {
    // MARK: - Generation

    @Test("a generated code is always exactly six digits")
    func generatedCodeIsSixDigits() {
        for _ in 0..<1_000 {
            let code = HouseholdPairingCode.generate()
            // Computed outside the macro: `allSatisfy` is `rethrows`, and
            // #expect's call decomposition refuses to expand one.
            let isAllDigits = code.digits.allSatisfy(\.isNumber)
            #expect(code.digits.count == HouseholdPairingCode.digitCount)
            #expect(isAllDigits)
        }
    }

    /// The bug this exists to prevent is `Int.random(in: 100_000...999_999)`,
    /// which looks right, avoids having to think about padding, and quietly
    /// throws away a tenth of the keyspace. Over 4,000 draws a missing
    /// leading zero is not a coin flip — it is a certainty.
    @Test("codes use the full range, leading zeros included")
    func generatedCodesIncludeLeadingZeros() {
        var sawLeadingZero = false
        for _ in 0..<4_000 where HouseholdPairingCode.generate().digits.hasPrefix("0") {
            sawLeadingZero = true
            break
        }
        #expect(sawLeadingZero, "no code in 4,000 started with 0 — the keyspace is probably 100000...999999")
    }

    /// Not a serious randomness test — `SystemRandomNumberGenerator` is the
    /// platform CSPRNG and is not what would break. This catches the thing
    /// that actually would: a constant, a counter, or a value seeded once.
    @Test("generation does not return the same code every time")
    func generatedCodesVary() {
        let codes = Set((0..<500).map { _ in HouseholdPairingCode.generate().digits })
        #expect(codes.count > 400, "500 draws produced only \(codes.count) distinct codes")
    }

    // MARK: - Matching

    @Test("a code matches its own digits")
    func matchesItself() {
        let code = HouseholdPairingCode.generate()
        #expect(code.matches(code.digits))
    }

    @Test("a code read aloud and typed back with spacing still matches", arguments: [
        "034812", "034 812", "034-812", " 034812 ", "034  812"
    ])
    func matchesDespiteSpacing(entered: String) {
        let code = HouseholdPairingCode(digits: "034812")
        #expect(code?.matches(entered) == true)
    }

    @Test("a wrong code does not match", arguments: [
        "034813", "134812", "000000", "", "03481", "0348120", "abcdef"
    ])
    func rejectsWrongCode(entered: String) {
        let code = HouseholdPairingCode(digits: "034812")
        #expect(code?.matches(entered) == false)
    }

    /// The property behind the constant-time comparison: a guess that is
    /// wrong only in its last digit is exactly as wrong as one that shares
    /// nothing. This cannot assert on timing without being flaky, so it
    /// asserts the behaviour the timing protects — that neither is ever
    /// treated as closer than the other.
    @Test("a near-miss is refused exactly like a total miss")
    func nearMissIsStillAMiss() {
        let code = HouseholdPairingCode(digits: "034812")
        #expect(code?.matches("034811") == false)
        #expect(code?.matches("999999") == false)
    }

    // MARK: - Parsing

    @Test("only exactly six digits parse into a code", arguments: [
        "12345", "1234567", "", "12a456", "abcdef"
    ])
    func rejectsMalformedDigits(raw: String) {
        #expect(HouseholdPairingCode(digits: raw) == nil)
    }

    @Test("a six-digit string parses, spacing and all")
    func parsesSixDigits() {
        #expect(HouseholdPairingCode(digits: "000000")?.digits == "000000")
        #expect(HouseholdPairingCode(digits: "034 812")?.digits == "034812")
    }

    // MARK: - The attempt budget

    /// Six digits is only a million if guessing is capped; uncapped, a peer
    /// that reconnects and retries walks the space in minutes. If anyone
    /// ever raises this, the keyspace has to be revisited in the same
    /// change — hence a test that makes the number deliberate.
    @Test("the attempt budget stays small enough for six digits to mean something")
    func attemptBudgetIsTight() {
        #expect(HouseholdPairingCode.maxAttempts <= 10)
        #expect(HouseholdPairingCode.maxAttempts >= 3, "too few tries to survive an honest typo")
    }

    // MARK: - Display

    @Test("the code is grouped in threes for reading aloud")
    func formatsInTwoGroups() {
        #expect(HouseholdPairingCode(digits: "034812")?.formatted == "034 812")
        #expect(HouseholdPairingCode(digits: "000000")?.formatted == "000 000")
    }
}
