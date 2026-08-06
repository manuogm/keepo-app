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
    let subtype: PublicSchema.AccountSubtype
    let openingBalance: Decimal
    let includeInTotal: Bool
    let countsTowardFi: Bool
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
        case name = "p_name"
        case subtype = "p_subtype"
        case openingBalance = "p_opening_balance"
        case includeInTotal = "p_include_in_total"
        case countsTowardFi = "p_counts_toward_fi"
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

public extension AccountRepository {
    /// Editable: name, subtype, opening_balance, include_in_total,
    /// counts_toward_fi. Not editable, by omission from this call's
    /// parameters, not a client-side check: currency and kind (see
    /// migration 20260805180000's header comment for why).
    ///
    /// Seven named, self-explanatory parameters — same reasoning as
    /// AccountRepository.create.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    static func update(
        client: SupabaseClient,
        id: UUID,
        expectedVersion: Int,
        name: String,
        subtype: PublicSchema.AccountSubtype,
        openingBalance: Decimal,
        includeInTotal: Bool,
        countsTowardFi: Bool
    ) async throws -> AccountWriteResult {
        let params = UpdateAccountParams(
            id: id,
            expectedVersion: expectedVersion,
            name: name,
            subtype: subtype,
            openingBalance: openingBalance,
            includeInTotal: includeInTotal,
            countsTowardFi: countsTowardFi
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
}
