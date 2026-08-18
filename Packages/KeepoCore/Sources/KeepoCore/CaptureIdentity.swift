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
    public static func externalId(card: String, amount: Int64, merchant: String, at date: Date) -> String {
        let bucket = Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
        let raw = "\(card)|\(amount)|\(merchant)|\(bucket)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// UUIDv5 (RFC 4122 §4.3) over `externalId`, namespaced to Keepo
    /// captures specifically. A re-fired automation now mints the exact
    /// same row id both times, not just the same `externalId` — closing a
    /// gap `externalId`'s own uniqueness index couldn't (C-07): before
    /// this, two fires within the same one-minute bucket wrote two local
    /// rows under two random ids, the second server insert correctly
    /// 23505'd on `externalId`, and `LiveOutboxSender` swallowed that as
    /// "already applied" — leaving the second local row orphaned forever,
    /// with no server counterpart to ever reconcile it against. Deriving
    /// the id from the same input the uniqueness constraint already keys
    /// on means the second local write lands on the SAME row instead.
    public static func transactionId(forExternalId externalId: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: captureNamespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(externalId.utf8))
        var digest = Array(hasher.finalize().prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// A fixed, arbitrary namespace UUID scoped to this one use — RFC 4122
    /// only requires it be stable and specific to the naming context, not
    /// registered anywhere. Built from a byte-tuple literal (never
    /// `UUID(uuidString:)!`) so there's nothing here that can fail at runtime.
    private static let captureNamespace = UUID(uuid: (
        0x6E, 0x7A, 0x9C, 0x9E, 0x6B, 0x1E, 0x4E, 0x9B, 0x9C, 0x7E, 0x5B, 0x7F, 0x0D, 0x2C, 0x9A, 0x41
    ))
}
