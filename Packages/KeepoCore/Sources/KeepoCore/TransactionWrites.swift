import Foundation
import Supabase

public extension TransactionRepository {
    /// The only transaction kind with an RPC — both legs, signed in SQL, in
    /// one call. `toAmount` is `nil` for a same-currency transfer (the DB
    /// infers it equals `fromAmount`); required when currencies differ.
    /// `fromId`/`toId` are the two legs' own client-generated ids — omitted
    /// (`nil`) by every ordinary online caller, in which case the DB
    /// generates them itself exactly as before. The offline outbox
    /// (Phase 11) is the one caller that supplies them: generating them
    /// once, before the first send attempt, is what makes a retry of this
    /// exact call idempotent — a repeat hits `transactions`' primary key
    /// instead of silently duplicating the transfer.
    static func createTransfer(
        client: SupabaseClient,
        fromAccountId: UUID,
        toAccountId: UUID,
        fromAmountE4: Int64,
        toAmountE4: Int64? = nil,
        occurredAt: Date = Date(),
        fromId: UUID? = nil,
        toId: UUID? = nil,
        notes: String? = nil,
        title: String? = nil
    ) async throws {
        let params = CreateTransferParams(
            fromAccountId: fromAccountId,
            toAccountId: toAccountId,
            fromAmountE4: fromAmountE4,
            toAmountE4: toAmountE4,
            occurredAt: PostgresDate.timestampString(occurredAt),
            fromId: fromId,
            toId: toId,
            notes: notes,
            title: title
        )
        try await client.rpc("create_transfer", params: params).execute()
    }

    /// A read-only pre-check the caller runs before `createTransfer` on a
    /// cross-currency transfer — never inside it, so `createTransfer`'s own
    /// signature and every existing caller stay untouched. `nil` means the
    /// divergence can't be computed at all (no market rate for that day, a
    /// missing-rate state per money rule 5) — the caller should treat that
    /// as "nothing to warn about," not as "diverges."
    static func checkTransferRateDivergence(
        client: SupabaseClient,
        fromCurrency: String,
        toCurrency: String,
        fromAmountE4: Int64,
        toAmountE4: Int64,
        occurredAt: Date = Date()
    ) async throws -> RateDivergence? {
        let params = CheckTransferRateDivergenceParams(
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            fromAmountE4: fromAmountE4,
            toAmountE4: toAmountE4,
            occurredAt: PostgresDate.timestampString(occurredAt)
        )
        let rows: [RateDivergence] = try await client.rpc("check_transfer_rate_divergence", params: params)
            .execute()
            .value
        return rows.first
    }
}

public struct RateDivergence: Decodable, Sendable {
    public let diverges: Bool
    public let impliedRate: Decimal
    public let marketRate: Decimal
    public let pctDiff: Decimal
    enum CodingKeys: String, CodingKey {
        case diverges
        case impliedRate = "implied_rate"
        case marketRate = "market_rate"
        case pctDiff = "pct_diff"
    }
}

private struct CheckTransferRateDivergenceParams: Encodable {
    let fromCurrency: String
    let toCurrency: String
    let fromAmountE4: Int64
    let toAmountE4: Int64
    let occurredAt: String
    enum CodingKeys: String, CodingKey {
        case fromCurrency = "p_from_currency"
        case toCurrency = "p_to_currency"
        case fromAmountE4 = "p_from_amount_e4"
        case toAmountE4 = "p_to_amount_e4"
        case occurredAt = "p_occurred_at"
    }
}

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
    let amountE4: Int64
    let currency: String
    let occurredAt: String
    let merchantRaw: String?
    let notes: String?
    /// Omitted from the JSON when nil, which is exactly right here: both
    /// carry `default null` in SQL, and omitting them is how an edit
    /// **clears** an original that no longer applies.
    let originalAmountE4: Int64?
    let originalCurrency: String?
    /// Same omit-to-clear semantics as the pair above: `p_title` defaults to
    /// null, so an edit that names no title leaves the row without one.
    let title: String?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
        case accountId = "p_account_id"
        case categoryId = "p_category_id"
        case amountE4 = "p_amount_e4"
        case currency = "p_currency"
        case occurredAt = "p_occurred_at"
        case merchantRaw = "p_merchant_raw"
        case notes = "p_notes"
        case originalAmountE4 = "p_original_amount_e4"
        case originalCurrency = "p_original_currency"
        case title = "p_title"
    }
}

struct UpdateTransferParams: Encodable {
    let transferGroupId: UUID
    let fromExpectedVersion: Int
    let toExpectedVersion: Int
    let fromAmountE4: Int64
    let toAmountE4: Int64
    let occurredAt: String
    let notes: String?
    let title: String?
    /// `nil` leaves that leg where it is — `update_transfer` defaults both.
    let fromAccountId: UUID?
    let toAccountId: UUID?
    enum CodingKeys: String, CodingKey {
        case transferGroupId = "p_transfer_group_id"
        case fromExpectedVersion = "p_from_expected_version"
        case toExpectedVersion = "p_to_expected_version"
        case fromAmountE4 = "p_from_amount_e4"
        case toAmountE4 = "p_to_amount_e4"
        case occurredAt = "p_occurred_at"
        case notes = "p_notes"
        case title = "p_title"
        case fromAccountId = "p_from_account_id"
        case toAccountId = "p_to_account_id"
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

private struct CreateTransferParams: Encodable {
    let fromAccountId: UUID
    let toAccountId: UUID
    let fromAmountE4: Int64
    let toAmountE4: Int64?
    let occurredAt: String
    let fromId: UUID?
    let toId: UUID?
    let notes: String?
    let title: String?
    enum CodingKeys: String, CodingKey {
        case fromAccountId = "p_from_account_id"
        case toAccountId = "p_to_account_id"
        case fromAmountE4 = "p_from_amount_e4"
        case toAmountE4 = "p_to_amount_e4"
        case occurredAt = "p_occurred_at"
        case fromId = "p_from_id"
        case toId = "p_to_id"
        case notes = "p_notes"
        case title = "p_title"
    }
}
