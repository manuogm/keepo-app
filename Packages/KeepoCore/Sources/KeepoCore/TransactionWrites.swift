import Foundation

/// The outcome of a version-checked write (edit or delete). `.conflict`
/// means the row changed since it was loaded — the DB already logged it to
/// `sync_conflicts` as part of the same successful call (see migration
/// 003's design note: raising an exception on conflict would have rolled
/// back that audit row too, since an RPC call is one statement). The caller
/// should reload and let the user retry.
public enum WriteResult {
    case saved(PublicSchema.TransactionsSelect)
    case conflict

    init(_ row: ConflictRow) {
        if !row.conflict, let transaction = row.transaction {
            self = .saved(transaction)
        } else {
            self = .conflict
        }
    }
}

struct ConflictRow: Decodable {
    let conflict: Bool
    let transaction: PublicSchema.TransactionsSelect?
}

struct ConflictFlag: Decodable {
    let conflict: Bool
}

struct UpdateTransactionParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    let accountId: UUID
    let categoryId: UUID
    let amount: Decimal
    let currency: String
    let occurredAt: String
    let merchantRaw: String?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
        case accountId = "p_account_id"
        case categoryId = "p_category_id"
        case amount = "p_amount"
        case currency = "p_currency"
        case occurredAt = "p_occurred_at"
        case merchantRaw = "p_merchant_raw"
    }
}

struct UpdateTransferParams: Encodable {
    let transferGroupId: UUID
    let fromExpectedVersion: Int
    let toExpectedVersion: Int
    let fromAmount: Decimal
    let toAmount: Decimal
    let occurredAt: String
    enum CodingKeys: String, CodingKey {
        case transferGroupId = "p_transfer_group_id"
        case fromExpectedVersion = "p_from_expected_version"
        case toExpectedVersion = "p_to_expected_version"
        case fromAmount = "p_from_amount"
        case toAmount = "p_to_amount"
        case occurredAt = "p_occurred_at"
    }
}

struct DeleteTransactionParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
    }
}

struct DeleteTransferParams: Encodable {
    let transferGroupId: UUID
    let fromExpectedVersion: Int
    let toExpectedVersion: Int
    enum CodingKeys: String, CodingKey {
        case transferGroupId = "p_transfer_group_id"
        case fromExpectedVersion = "p_from_expected_version"
        case toExpectedVersion = "p_to_expected_version"
    }
}
