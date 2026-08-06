import Foundation
import Supabase

/// Phase 9's client-side seam for the Sync Ritual. The ritual never stores a
/// balance itself — `reconcile_ledger_account`/`reconcile_valuation_account`
/// are the only writers, and `accounts_sync_status` is the only reader of
/// "how stale is this account."
public enum ReconciliationRepository {
    public static func fetchSyncStatus(client: SupabaseClient) async throws -> [PublicSchema.AccountsSyncStatusSelect] {
        try await client.from("accounts_sync_status").select().order("name").execute().value
    }

    /// `expectedLastReconciliationId` is the concurrency guard: pass the id
    /// the caller last saw as the account's latest reconciliation (`nil` if
    /// it has never been reconciled). If that's gone stale — someone else
    /// reconciled the same account in between — the DB refuses with
    /// `.conflict` rather than risk a double-counted adjustment; the
    /// caller's own retry (re-fetch `accounts_sync_status`, recompute the
    /// gap) is the "rebase" the ritual promises, not a separate code path.
    @discardableResult
    public static func reconcileLedgerAccount(
        client: SupabaseClient,
        accountId: UUID,
        enteredBalance: Decimal,
        expectedLastReconciliationId: UUID?
    ) async throws -> ReconciliationWriteResult {
        let params = ReconcileLedgerAccountParams(
            accountId: accountId,
            enteredBalance: enteredBalance,
            expectedLastReconciliationId: expectedLastReconciliationId
        )
        let rows: [LedgerReconciliationRow] = try await client.rpc("reconcile_ledger_account", params: params)
            .execute().value
        return rows.first.map(ReconciliationWriteResult.init) ?? .conflict
    }

    /// Direct balance update writing a snapshot — no transaction review, no
    /// adjustment (spec, explicit: valuation accounts never generate one).
    @discardableResult
    public static func reconcileValuationAccount(
        client: SupabaseClient,
        accountId: UUID,
        enteredValue: Decimal,
        expectedLastReconciliationId: UUID?
    ) async throws -> ReconciliationWriteResult {
        let params = ReconcileValuationAccountParams(
            accountId: accountId,
            enteredValue: enteredValue,
            expectedLastReconciliationId: expectedLastReconciliationId
        )
        let rows: [ValuationReconciliationRow] = try await client.rpc("reconcile_valuation_account", params: params)
            .execute().value
        return rows.first.map(ReconciliationWriteResult.init) ?? .conflict
    }
}

/// `adjustment` is `nil` for a valuation reconciliation (never posts one)
/// and for a zero-gap ledger reconciliation (never posts a $0 adjustment
/// nobody asked for) — distinct from `.conflict`, which means nothing at
/// all was written.
public enum ReconciliationWriteResult {
    case saved(PublicSchema.ReconciliationsSelect, adjustment: PublicSchema.TransactionsSelect?)
    case conflict

    init(_ row: LedgerReconciliationRow) {
        if !row.conflict, let reconciliation = row.reconciliation {
            self = .saved(reconciliation, adjustment: row.adjustment)
        } else {
            self = .conflict
        }
    }

    init(_ row: ValuationReconciliationRow) {
        if !row.conflict, let reconciliation = row.reconciliation {
            self = .saved(reconciliation, adjustment: nil)
        } else {
            self = .conflict
        }
    }
}

struct LedgerReconciliationRow: Decodable {
    let conflict: Bool
    let reconciliation: PublicSchema.ReconciliationsSelect?
    let adjustment: PublicSchema.TransactionsSelect?
}

struct ValuationReconciliationRow: Decodable {
    let conflict: Bool
    let reconciliation: PublicSchema.ReconciliationsSelect?
}

struct ReconcileLedgerAccountParams: Encodable {
    let accountId: UUID
    let enteredBalance: Decimal
    let expectedLastReconciliationId: UUID?
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
        case enteredBalance = "p_entered_balance"
        case expectedLastReconciliationId = "p_expected_last_reconciliation_id"
    }
}

struct ReconcileValuationAccountParams: Encodable {
    let accountId: UUID
    let enteredValue: Decimal
    let expectedLastReconciliationId: UUID?
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
        case enteredValue = "p_entered_value"
        case expectedLastReconciliationId = "p_expected_last_reconciliation_id"
    }
}
