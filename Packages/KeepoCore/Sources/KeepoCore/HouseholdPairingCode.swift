import Foundation

/// The six digits one phone shows and the other must be told.
///
/// ## What this is for
///
/// Household pairing happens over `MCSession`, which encrypts the link but
/// does not authenticate the peer — `securityIdentity` is nil, because there
/// is no certificate authority between two phones on a kitchen table. Before
/// this existed, that left the discovery flow open in a way the security
/// audit of 2026-09-21 (finding 6) demonstrated: the owner's phone accepted
/// every invitation that arrived, without asking, and both phones sent their
/// name and face the instant the link opened. Anything within Bluetooth
/// range could harvest that with no interaction on the victim's phone at all.
///
/// A code fixes it by moving one secret onto a channel the radio cannot
/// reach: the owner's screen, and the owner's voice in the room. A device
/// that cannot see or hear that cannot produce the digits, and therefore
/// never gets far enough to be told who anybody is.
///
/// ## What it deliberately does not fix
///
/// **An active relay.** An attacker who advertises as an owner at the right
/// moment can have the real guest type the real code into *their* app, then
/// replay it to the real owner — passing the check on both legs. Binding the
/// proof to per-session nonces does not help, because an attacker who
/// controls both legs can choose its nonce on one to match the other.
/// Closing it properly needs a PAKE (SPAKE2 or similar), where the code
/// seeds a key exchange and the proof is bound to channel keys that cannot be
/// reproduced on two legs at once. That is a large amount of machinery for a
/// two-phone flow, and the attack it buys off needs a co-located attacker,
/// advertising at the right second, winning the discovery race, while both
/// people are actively pairing.
///
/// This was weighed and accepted deliberately, not overlooked. The same
/// ceiling already applies to `MCSession`'s own encryption, so no amount of
/// layering on top of it removes the assumption.
public struct HouseholdPairingCode: Hashable, Sendable {
    /// Six digits: 1,000,000 codes. Only meaningful alongside
    /// `maxAttempts` — see its doc comment.
    public static let digitCount = 6

    /// Wrong guesses allowed before the pairing session is abandoned and the
    /// code burned.
    ///
    /// **This is what makes six digits enough**, and it is the number to
    /// think hardest about if any of this is ever revisited. A million
    /// combinations is only a million if guessing is expensive: uncapped, a
    /// peer that can reconnect and retry walks the whole space in minutes. At
    /// five, the chance of hitting it is 5 in 1,000,000.
    ///
    /// The cap therefore has to be counted by the side holding the secret,
    /// against the *code*, and it has to survive the other phone
    /// disconnecting — a counter that resets with the connection is one the
    /// attacker resets for free. See `HouseholdPairingSession`.
    public static let maxAttempts = 5

    /// Exactly `digitCount` characters, zero-padded, `0`–`9` only.
    public let digits: String

    private init(unchecked digits: String) {
        self.digits = digits
    }

    /// A fresh code, uniform over every value from `000000` to `999999`.
    ///
    /// `SystemRandomNumberGenerator` is Apple's CSPRNG, and it is named here
    /// rather than left implicit so that nobody later swaps in something
    /// seeded and reproducible without noticing what it was for.
    ///
    /// The range starts at zero, which matters more than it looks: the
    /// obvious `100_000...999_999` avoids having to think about padding and
    /// silently throws away a tenth of the keyspace, while telling anybody
    /// guessing that no code begins with a zero.
    public static func generate() -> HouseholdPairingCode {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        return HouseholdPairingCode(unchecked: String(format: "%0\(digitCount)d", value))
    }

    /// Rebuilds a code from digits already generated. Returns nil for
    /// anything that is not exactly `digitCount` digits, so a malformed value
    /// can never become a code that compares equal to something.
    public init?(digits: String) {
        let normalized = Self.normalize(digits)
        guard normalized.count == Self.digitCount else { return nil }
        self.digits = normalized
    }

    /// Everything that is not a digit, removed — so a code read aloud and
    /// typed back as "034 812" or "034-812" is the code, and a stray space
    /// is never a failed attempt the user cannot see.
    public static func normalize(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    /// Whether `entered` is this code, in time that does not depend on how
    /// many leading digits are right.
    ///
    /// The same reasoning as `_shared/secret.ts` in the edge functions, and
    /// more warranted here than there: the attacker is on the local radio
    /// rather than the far side of the internet, so timing is measurable
    /// enough to be worth not leaking. A `==` on `String` returns at the
    /// first differing character, which over enough attempts is a
    /// digit-at-a-time oracle rather than a 1-in-a-million guess.
    public func matches(_ entered: String) -> Bool {
        let expected = Array(digits.utf8)
        let provided = Array(Self.normalize(entered).utf8)
        guard provided.count == expected.count else { return false }

        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ provided[index] }
        return difference == 0
    }

    /// Grouped for reading aloud — `034 812`. Two groups of three is what
    /// people can hold in their head for the length of a sentence.
    public var formatted: String {
        let middle = digits.index(digits.startIndex, offsetBy: Self.digitCount / 2)
        return "\(digits[..<middle]) \(digits[middle...])"
    }
}
