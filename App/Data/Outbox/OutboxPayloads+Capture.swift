import Foundation
import KeepoCore

// CaptureTransactionPayload and ReviewCaptureTransactionPayload, split out of
// OutboxPayloads.swift purely to keep that file under the project's
// file-length lint threshold — same precedent as Outbox+Capture.swift.

/// The App Intent's write, generalized into the outbox as its 7th
/// operation (anticipated in Phase 11's log). No `expectedVersion` — a
/// capture has nothing to conflict against, it's an insert-or-noop keyed by
/// `externalId`, not an edit of an existing row.
public struct CaptureTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let cardIdentifier: String
    public let merchantRaw: String
    public let merchantNormalized: String
    public let amountE4: Int64
    public let occurredAt: Date
    public let externalId: String
    public let notes: String?
    /// What `CurrencyDetector` read out of Wallet's formatted amount, or
    /// `nil` when it could not be certain. **Not a decision** — the server
    /// and `CaptureLocalWrite` both compare it against the mapped account's
    /// currency and both re-check it against the supported set, because
    /// only they know the account.
    public let detectedCurrency: String?
    /// The category this device resolved from one of the user's titles,
    /// when the merchant taught Keepo nothing — **never set by whoever
    /// builds the payload**, only by `Outbox.submitCaptureTransaction` once
    /// the local resolution has run (`hinting(_:)`). The server uses it only
    /// where its own merchant map has no answer. There is deliberately no
    /// title here: a capture never gets one.
    public let categoryHint: UUID?

    public init(
        id: UUID, cardIdentifier: String, merchantRaw: String, merchantNormalized: String,
        amountE4: Int64, occurredAt: Date, externalId: String, notes: String? = nil,
        detectedCurrency: String? = nil, categoryHint: UUID? = nil
    ) {
        self.id = id
        self.cardIdentifier = cardIdentifier
        self.merchantRaw = merchantRaw
        self.merchantNormalized = merchantNormalized
        self.amountE4 = amountE4
        self.occurredAt = occurredAt
        self.externalId = externalId
        self.notes = notes
        self.detectedCurrency = detectedCurrency
        self.categoryHint = categoryHint
    }

    /// The same capture, carrying the local resolution's category as advice
    /// for the server.
    public func hinting(_ categoryId: UUID?) -> CaptureTransactionPayload {
        CaptureTransactionPayload(
            id: id, cardIdentifier: cardIdentifier, merchantRaw: merchantRaw, merchantNormalized: merchantNormalized,
            amountE4: amountE4, occurredAt: occurredAt, externalId: externalId, notes: notes,
            detectedCurrency: detectedCurrency, categoryHint: categoryId
        )
    }
}

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
    /// See `CreateTransactionPayload.original`. On a capture this is what
    /// Wallet reported and the user could not edit; `amountE4` beside it is
    /// what the user *could*, and usually should — a bank's spread is not
    /// the ECB's rate.
    public let original: ForeignOriginal?
    /// What the user typed while reviewing — a capture never arrives with
    /// one of its own.
    public let title: String?

    public init(
        id: UUID, expectedVersion: Int, accountId: UUID, categoryId: UUID,
        amountE4: Int64, currency: String, occurredAt: Date, merchantRaw: String?, notes: String? = nil,
        original: ForeignOriginal? = nil, title: String? = nil
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
        self.original = original
        self.title = title
    }
}
