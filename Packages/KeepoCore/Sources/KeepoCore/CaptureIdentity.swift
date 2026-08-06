import CryptoKit
import Foundation

/// The Wallet automation payload carries no transaction id — this is the
/// hash behind `transactions`' partial unique index on
/// `(owner_id, source, external_id)` (money-safety requirement: a re-fired
/// automation must be a no-op, never a duplicate charge). Computed
/// client-side, not in SQL, so it's the single normalization/hashing path —
/// the server never re-derives it, it only enforces uniqueness on whatever
/// arrives.
public enum CaptureIdentity {
    /// - Parameter date: the automation's fire time, bucketed to the
    ///   nearest minute so a near-instant automation re-fire (the same tap,
    ///   retried by Shortcuts) still hashes identically, while two genuinely
    ///   separate purchases a minute or more apart never collide.
    public static func externalId(card: String, amount: Decimal, merchant: String, at date: Date) -> String {
        let bucket = Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
        let raw = "\(card)|\(amount)|\(merchant)|\(bucket)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
