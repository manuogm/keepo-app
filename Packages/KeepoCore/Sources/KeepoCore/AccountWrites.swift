import Foundation
import Supabase

/// The outcome of a version-checked account write (edit or archive) —
/// parallel to `WriteResult` for transactions. `.conflict` means the DB
/// already logged the mismatch to `sync_conflicts` as part of the same
/// call; the caller should reload and let the user retry.
public enum AccountWriteResult {
    case saved(PublicSchema.AccountsSelect)
    case conflict

    init(_ row: AccountConflictRow) {
        if !row.conflict, let account = row.account {
            self = .saved(account)
        } else {
            self = .conflict
        }
    }
}

struct AccountConflictRow: Decodable {
    let conflict: Bool
    let account: PublicSchema.AccountsSelect?
}

struct AccountDeleteConflictFlag: Decodable {
    let conflict: Bool
}

struct UpdateAccountParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    let name: String
    let openingBalanceE4: Int64
    let includeInTotal: Bool
    let icon: String
    let color: String
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
        case name = "p_name"
        case openingBalanceE4 = "p_opening_balance_e4"
        case includeInTotal = "p_include_in_total"
        case icon = "p_icon"
        case color = "p_color"
    }
}

struct ArchiveAccountParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    let archived: Bool
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
        case archived = "p_archived"
    }
}

struct DeleteAccountParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
    }
}

struct SetAccountBalanceParams: Encodable {
    let accountId: UUID
    let newBalanceE4: Int64
    let expectedVersion: Int
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
        case newBalanceE4 = "p_new_balance_e4"
        case expectedVersion = "p_expected_version"
        case id = "p_id"
    }
}

/// `transactionId` is set on a successful (non-conflicting) write — every
/// account kind now takes the same adjustment-transaction path server-side
/// (see the migration's own header comment). `snapshotId` is always nil;
/// the RPC still returns the column for shape compatibility but nothing
/// populates it since balance_snapshots was dropped.
/// `conflict` mirrors every other versioned write RPC: a version mismatch
/// on a *new* edit is reported as data, not an exception — a replay of an
/// already-applied `id` is never a conflict, no matter how stale
/// `expectedVersion` has since become (checked before the version check
/// server-side, so idempotent outbox retries always succeed).
public struct SetAccountBalanceResult: Decodable, Sendable {
    public let transactionId: UUID?
    public let snapshotId: UUID?
    public let conflict: Bool
    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case snapshotId = "snapshot_id"
        case conflict
    }
}

public extension AccountRepository {
    /// Editable: name, opening_balance_e4, include_in_total, icon, color.
    /// Not editable, by omission from this call's parameters, not a
    /// client-side check: currency and kind (see migration 20260805180000's
    /// header comment for why).
    ///
    /// Six named, self-explanatory parameters — same reasoning as
    /// AccountRepository.create.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    static func update(
        client: SupabaseClient,
        id: UUID,
        expectedVersion: Int,
        name: String,
        openingBalanceE4: Int64,
        includeInTotal: Bool,
        icon: String,
        color: String
    ) async throws -> AccountWriteResult {
        let params = UpdateAccountParams(
            id: id,
            expectedVersion: expectedVersion,
            name: name,
            openingBalanceE4: openingBalanceE4,
            includeInTotal: includeInTotal,
            icon: icon,
            color: color
        )
        let rows: [AccountConflictRow] = try await client.rpc("update_account", params: params).execute().value
        return rows.first.map(AccountWriteResult.init) ?? .conflict
    }

    @discardableResult
    static func setArchived(
        client: SupabaseClient,
        id: UUID,
        expectedVersion: Int,
        archived: Bool
    ) async throws -> AccountWriteResult {
        let params = ArchiveAccountParams(id: id, expectedVersion: expectedVersion, archived: archived)
        let rows: [AccountConflictRow] = try await client.rpc("archive_account", params: params).execute().value
        return rows.first.map(AccountWriteResult.init) ?? .conflict
    }

    /// Refused by the DB (raises, not a conflict) while the account still
    /// has non-deleted transactions — archive it instead.
    static func delete(client: SupabaseClient, id: UUID, expectedVersion: Int) async throws -> Bool {
        let params = DeleteAccountParams(id: id, expectedVersion: expectedVersion)
        let rows: [AccountDeleteConflictFlag] = try await client.rpc("delete_account", params: params).execute().value
        return !(rows.first?.conflict ?? true)
    }

    /// "This account is worth X right now" — the gap against the account's
    /// own computed balance becomes an adjustment transaction (filed under
    /// "Other"), the same path for every account kind. `id` is the same
    /// client-generated idempotency key every outbox write uses — replaying it
    /// twice (e.g. a queued write synced, then retried) has no double
    /// effect and never conflicts, even against a stale `expectedVersion`
    /// (the migration's idempotency-before-version-check ordering).
    @discardableResult
    static func setBalance(
        client: SupabaseClient, accountId: UUID, newBalanceE4: Int64, expectedVersion: Int, id: UUID
    ) async throws -> SetAccountBalanceResult {
        let params = SetAccountBalanceParams(
            accountId: accountId, newBalanceE4: newBalanceE4, expectedVersion: expectedVersion, id: id
        )
        let rows: [SetAccountBalanceResult] = try await client.rpc("set_account_balance", params: params)
            .execute().value
        return rows.first ?? SetAccountBalanceResult(transactionId: nil, snapshotId: nil, conflict: false)
    }
}
