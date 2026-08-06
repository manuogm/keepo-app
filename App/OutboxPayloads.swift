import Foundation

// MARK: - Payloads (whole-row, never a per-field merge)

public struct CreateTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let accountId: UUID
    public let categoryId: UUID
    public let amount: Decimal
    public let currency: String
    public let occurredAt: Date

    public init(
        id: UUID, ownerId: UUID, accountId: UUID, categoryId: UUID, amount: Decimal, currency: String, occurredAt: Date
    ) {
        self.id = id
        self.ownerId = ownerId
        self.accountId = accountId
        self.categoryId = categoryId
        self.amount = amount
        self.currency = currency
        self.occurredAt = occurredAt
    }
}

public struct CreateTransferPayload: Codable, Sendable {
    public let fromId: UUID
    public let toId: UUID
    public let fromAccountId: UUID
    public let toAccountId: UUID
    public let fromAmount: Decimal
    public let toAmount: Decimal?
    public let occurredAt: Date

    public init(
        fromId: UUID, toId: UUID, fromAccountId: UUID, toAccountId: UUID,
        fromAmount: Decimal, toAmount: Decimal?, occurredAt: Date
    ) {
        self.fromId = fromId
        self.toId = toId
        self.fromAccountId = fromAccountId
        self.toAccountId = toAccountId
        self.fromAmount = fromAmount
        self.toAmount = toAmount
        self.occurredAt = occurredAt
    }
}

public struct UpdateTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let accountId: UUID
    public let categoryId: UUID
    public let amount: Decimal
    public let currency: String
    public let occurredAt: Date
    public let merchantRaw: String?

    public init(
        id: UUID, expectedVersion: Int, accountId: UUID, categoryId: UUID,
        amount: Decimal, currency: String, occurredAt: Date, merchantRaw: String?
    ) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.accountId = accountId
        self.categoryId = categoryId
        self.amount = amount
        self.currency = currency
        self.occurredAt = occurredAt
        self.merchantRaw = merchantRaw
    }
}

public struct UpdateTransferPayload: Codable, Sendable {
    public let transferGroupId: UUID
    public let fromExpectedVersion: Int
    public let toExpectedVersion: Int
    public let fromAmount: Decimal
    public let toAmount: Decimal
    public let occurredAt: Date

    public init(
        transferGroupId: UUID, fromExpectedVersion: Int, toExpectedVersion: Int,
        fromAmount: Decimal, toAmount: Decimal, occurredAt: Date
    ) {
        self.transferGroupId = transferGroupId
        self.fromExpectedVersion = fromExpectedVersion
        self.toExpectedVersion = toExpectedVersion
        self.fromAmount = fromAmount
        self.toAmount = toAmount
        self.occurredAt = occurredAt
    }
}

public struct DeleteTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int

    public init(id: UUID, expectedVersion: Int) {
        self.id = id
        self.expectedVersion = expectedVersion
    }
}

/// The App Intent's write, generalized into the outbox as its 7th
/// operation (anticipated in Phase 11's log). No `expectedVersion` — a
/// capture has nothing to conflict against, it's an insert-or-noop keyed by
/// `externalId`, not an edit of an existing row.
public struct CaptureTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let cardIdentifier: String
    public let merchantRaw: String
    public let merchantNormalized: String
    public let amount: Decimal
    public let occurredAt: Date
    public let externalId: String

    public init(
        id: UUID, cardIdentifier: String, merchantRaw: String, merchantNormalized: String,
        amount: Decimal, occurredAt: Date, externalId: String
    ) {
        self.id = id
        self.cardIdentifier = cardIdentifier
        self.merchantRaw = merchantRaw
        self.merchantNormalized = merchantNormalized
        self.amount = amount
        self.occurredAt = occurredAt
        self.externalId = externalId
    }
}

public struct DeleteTransferPayload: Codable, Sendable {
    public let transferGroupId: UUID
    public let fromExpectedVersion: Int
    public let toExpectedVersion: Int

    public init(transferGroupId: UUID, fromExpectedVersion: Int, toExpectedVersion: Int) {
        self.transferGroupId = transferGroupId
        self.fromExpectedVersion = fromExpectedVersion
        self.toExpectedVersion = toExpectedVersion
    }
}
