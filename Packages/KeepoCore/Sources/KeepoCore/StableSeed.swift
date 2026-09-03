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

    /// A UUID derived from a string, the same one every time.
    ///
    /// For a row whose identity is a **composite key** rather than a `uuid`
    /// column, where something downstream still wants one id — the outbox
    /// keys each queued item by UUID, and `transaction_tags` is keyed by
    /// (transaction_id, tag_id). Deriving the key means toggling one tag on
    /// one transaction repeatedly collapses to a single queued item holding
    /// the latest intent, instead of a pile of them that replay in order to
    /// the same end state.
    ///
    /// Two FNV-1a passes over different prefixes of the same input, giving
    /// 128 bits. **Not** a UUIDv5 — no namespace, no SHA-1, and no claim of
    /// cryptographic distribution; this is an internal dedup key, and the
    /// only property it needs is that the same string always yields the same
    /// UUID.
    public static func uuid(from string: String) -> UUID {
        let high = UInt64(bitPattern: Int64(hash("hi:" + string)))
        let low = UInt64(bitPattern: Int64(hash("lo:" + string)))
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((high >> UInt64(shift)) & 0xFF)) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((low >> UInt64(shift)) & 0xFF)) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
