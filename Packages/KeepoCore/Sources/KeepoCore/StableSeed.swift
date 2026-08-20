import Foundation

/// A hash that survives relaunches, for deriving per-item visual variation —
/// a card's shade, a currency's colour, a tile's wobble timing.
///
/// Two things it exists to prevent, both of which have bitten this codebase:
///
///  1. **Swift's own `hashValue` is seeded per process.** An item keyed on it
///     looks different on every launch, which is the opposite of the point:
///     "the green card" has to still be the green card tomorrow.
///  2. **An index is not an identity.** Deriving variation from a position in
///     a list changes it the moment a sibling is inserted ahead of it — every
///     item below the insertion re-colours itself for no reason the user can
///     see.
///
/// FNV-1a over the UTF-8 bytes: tiny, dependency-free, and stable forever.
/// Not a cryptographic hash and not trying to be — nothing here is a
/// security boundary, and the only property that matters is that the same
/// string always yields the same number.
public enum StableSeed {
    public static func hash(_ string: String) -> Int {
        var hash = 2_166_136_261
        for byte in string.utf8 {
            hash = (hash ^ Int(byte)) &* 16_777_619
        }
        return hash
    }

    /// A stable index into a collection of `upperBound` elements. Returns 0
    /// for an empty collection rather than trapping on a modulo by zero —
    /// callers are picking a decoration, and there is no sensible failure
    /// mode to propagate for that.
    public static func index(_ string: String, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(hash(string).magnitude % UInt(upperBound))
    }
}
