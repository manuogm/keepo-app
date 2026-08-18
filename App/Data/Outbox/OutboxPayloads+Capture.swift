import Foundation

// ReviewCaptureTransactionPayload, split out of OutboxPayloads.swift purely
// to keep that file under the project's file-length lint threshold — same
// precedent as Outbox+Capture.swift.

/// The Needs Review "review, then confirm" write — an edit and a status
/// flip in a single payload/RPC/outbox item (migration 20260825100000),
/// replacing what used to be an `UpdateTransactionPayload` and a
/// `ConfirmCaptureTransactionPayload` sent as two independently-queued
/// writes sharing one row and one version counter. That split let the two
/// race (whichever arrived second sent a now-stale `expectedVersion`) and,
/// offline, let the outbox's own collapse-by-row-id rule silently discard
/// the edit when the confirm queued under the same id. Shaped exactly like
/// `UpdateTransactionPayload` — same fields, same semantics — because it
/// replaces exactly that write for this one case.
public struct ReviewCaptureTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let accountId: UUID
    public let categoryId: UUID
    public let amountE4: Int64
    public let currency: String
    public let occurredAt: Date
    public let merchantRaw: String?
    public let notes: String?

    public init(
        id: UUID, expectedVersion: Int, accountId: UUID, categoryId: UUID,
        amountE4: Int64, currency: String, occurredAt: Date, merchantRaw: String?, notes: String? = nil
    ) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.accountId = accountId
        self.categoryId = categoryId
        self.amountE4 = amountE4
        self.currency = currency
        self.occurredAt = occurredAt
        self.merchantRaw = merchantRaw
        self.notes = notes
    }
}
