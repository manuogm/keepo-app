import Foundation
import Supabase

public enum AccountRepository {
    public static func fetchAllWithBalances(
        client: SupabaseClient
    ) async throws -> [PublicSchema.AccountsWithBalancesSelect] {
        try await client.from("accounts_with_balances").select().order("name").execute().value
    }

    /// The raw row, not the enriched view — `accounts_with_balances` exposes
    /// the computed running `balance`, never the stored `opening_balance`
    /// an edit form needs to prefill. Used only when opening the edit form;
    /// the list itself keeps reading the enriched view.
    public static func fetchOne(client: SupabaseClient, id: UUID) async throws -> PublicSchema.AccountsSelect {
        try await client.from("accounts").select().eq("id", value: id).single().execute().value
    }

    /// Creates an account with a client-generated id (money rule: client-
    /// generated UUIDs, not server defaults — see app-architecture.md §Data
    /// & Offline). Every account kind computes its balance the same way now
    /// (opening_balance_e4 + transactions), so there is no per-kind
    /// follow-up write — a single insert is the whole operation.
    ///
    /// `id` defaults to a fresh `UUID()` for an ordinary online caller; the
    /// offline outbox is the one caller that supplies its own, generated
    /// once before the first send attempt, so a retry of this exact call
    /// reuses the same id and hits `accounts`' primary key instead of
    /// inserting a duplicate row — same convention as
    /// `TransactionRepository.create`.
    ///
    /// Otherwise eight named, self-explanatory parameters describing one new
    /// account — splitting into a params struct here would be an
    /// indirection layer with no reader benefit, not a simplification.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        id: UUID = UUID(),
        ownerId: UUID,
        kind: PublicSchema.AccountKind,
        name: String,
        currency: String,
        openingBalanceE4: Int64,
        icon: String,
        color: String
    ) async throws -> UUID {
        let accountId = id
        let row = NewAccountRow(
            id: accountId,
            ownerId: ownerId,
            createdBy: ownerId,
            kind: kind,
            name: name,
            currency: currency,
            openingBalanceE4: openingBalanceE4,
            icon: icon,
            color: color
        )
        try await client.from("accounts").insert(row).execute()

        return accountId
    }
}

private struct NewAccountRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let createdBy: UUID
    let kind: PublicSchema.AccountKind
    let name: String
    let currency: String
    let openingBalanceE4: Int64
    let icon: String
    let color: String
    enum CodingKeys: String, CodingKey {
        case id, kind, name, currency, icon, color
        case ownerId = "owner_id"
        case createdBy = "created_by"
        case openingBalanceE4 = "opening_balance_e4"
    }
}

public enum TransactionRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        try await client.from("transactions_with_details")
            .select()
            .order("occurred_at", ascending: false)
            .execute()
            .value
    }

    /// A single row by id — used by Needs Review to open a pending capture
    /// for review (edit) or to read its current `version` before confirming
    /// it, without fetching the whole list.
    public static func fetchOne(
        client: SupabaseClient, id: UUID
    ) async throws -> PublicSchema.TransactionsWithDetailsSelect? {
        let rows: [PublicSchema.TransactionsWithDetailsSelect] = try await client.from("transactions_with_details")
            .select()
            .eq("transaction_id", value: id)
            .execute()
            .value
        return rows.first
    }

    /// Expense or income — a plain insert. The DB's sign_matches_category_kind
    /// CHECK makes a wrong sign impossible; nothing here re-signs the amount
    /// (money rule: never re-sign in application code). `amount` must
    /// already carry the correct sign for the category's kind.
    ///
    /// `id` defaults to a fresh `UUID()` for an ordinary online caller;
    /// the offline outbox (Phase 11) is the one caller that supplies its
    /// own, generated once before the first send attempt, so a retry of
    /// this exact call reuses the same id and hits `transactions`' primary
    /// key instead of inserting a duplicate row.
    ///
    /// `ownerId` is the account's owner; `createdBy` is who entered it, when
    /// that is someone else — a partner on the owner's shared account. RLS
    /// requires `created_by` to be the caller, and the foreign keys require
    /// `owner_id` to be the account's owner.
    ///
    /// Otherwise six named, self-explanatory parameters describing one
    /// transaction — same reasoning as AccountRepository.create above.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        id: UUID = UUID(),
        ownerId: UUID,
        createdBy: UUID? = nil,
        accountId: UUID,
        categoryId: UUID,
        amountE4: Int64,
        currency: String,
        occurredAt: Date = Date(),
        notes: String? = nil,
        original: ForeignOriginal? = nil,
        title: String? = nil
    ) async throws -> UUID {
        let row = NewTransactionRow(
            id: id,
            ownerId: ownerId,
            createdBy: createdBy ?? ownerId,
            accountId: accountId,
            categoryId: categoryId,
            amountE4: amountE4,
            currency: currency,
            occurredAt: PostgresDate.timestampString(occurredAt),
            notes: notes,
            originalAmountE4: original?.amountE4,
            originalCurrency: original?.currency,
            title: title
        )
        try await client.from("transactions").insert(row).execute()
        return id
    }

    /// Ledger-only edit (expense/income) — a transfer's kind and legs are
    /// locked once it exists, so a transfer goes through `updateTransfer`
    /// instead. Version-checked: the DB returns `conflict = true` rather
    /// than throwing when `expectedVersion` is stale (see `update_transaction`
    /// in migration 003 — an RPC call is one statement, so a thrown
    /// exception would also roll back its own conflict-audit row).
    ///
    /// Eight named, self-explanatory parameters describing one edit — same
    /// reasoning as AccountRepository.create above.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func update(
        client: SupabaseClient,
        id: UUID,
        expectedVersion: Int,
        accountId: UUID,
        categoryId: UUID,
        amountE4: Int64,
        currency: String,
        occurredAt: Date = Date(),
        merchantRaw: String?,
        notes: String? = nil,
        original: ForeignOriginal? = nil,
        title: String? = nil
    ) async throws -> WriteResult {
        let params = UpdateTransactionParams(
            id: id,
            expectedVersion: expectedVersion,
            accountId: accountId,
            categoryId: categoryId,
            amountE4: amountE4,
            currency: currency,
            occurredAt: PostgresDate.timestampString(occurredAt),
            merchantRaw: merchantRaw,
            notes: notes,
            originalAmountE4: original?.amountE4,
            originalCurrency: original?.currency,
            title: title
        )
        let rows: [ConflictRow] = try await client.rpc("update_transaction", params: params).execute().value
        return rows.first.map(WriteResult.init) ?? .conflict
    }

    /// Both legs' accounts, amounts and date, updated atomically with each
    /// leg's own expected version — see `update_transfer` (last restated in
    /// 20261006100000, which added the accounts: a leg may move to another
    /// account with the same owner).
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func updateTransfer(
        client: SupabaseClient,
        transferGroupId: UUID,
        fromExpectedVersion: Int,
        toExpectedVersion: Int,
        fromAmountE4: Int64,
        toAmountE4: Int64,
        occurredAt: Date = Date(),
        notes: String? = nil,
        title: String? = nil,
        fromAccountId: UUID? = nil,
        toAccountId: UUID? = nil
    ) async throws -> WriteResult {
        let params = UpdateTransferParams(
            transferGroupId: transferGroupId,
            fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion,
            fromAmountE4: fromAmountE4,
            toAmountE4: toAmountE4,
            occurredAt: PostgresDate.timestampString(occurredAt),
            notes: notes,
            title: title,
            fromAccountId: fromAccountId,
            toAccountId: toAccountId
        )
        let rows: [ConflictRow] = try await client.rpc("update_transfer", params: params).execute().value
        return rows.first.map(WriteResult.init) ?? .conflict
    }

    public static func delete(client: SupabaseClient, id: UUID, expectedVersion: Int) async throws -> Bool {
        let params = DeleteTransactionParams(id: id, expectedVersion: expectedVersion)
        let rows: [ConflictFlag] = try await client.rpc("delete_transaction", params: params).execute().value
        return !(rows.first?.conflict ?? true)
    }

    public static func deleteTransfer(
        client: SupabaseClient,
        transferGroupId: UUID,
        fromExpectedVersion: Int,
        toExpectedVersion: Int
    ) async throws -> Bool {
        let params = DeleteTransferParams(
            transferGroupId: transferGroupId,
            fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion
        )
        let rows: [ConflictFlag] = try await client.rpc("delete_transfer", params: params).execute().value
        return !(rows.first?.conflict ?? true)
    }
}

private struct NewTransactionRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let createdBy: UUID
    let accountId: UUID
    let categoryId: UUID
    let amountE4: Int64
    let currency: String
    let occurredAt: String
    let notes: String?
    /// Flattened rather than nested: these are two columns in one row, and
    /// PostgREST inserts columns. `ForeignOriginal` is the shape the app
    /// passes them around in; this is the shape the table wants.
    let originalAmountE4: Int64?
    let originalCurrency: String?
    let title: String?
    enum CodingKeys: String, CodingKey {
        case id, currency, notes, title
        case amountE4 = "amount_e4"
        case ownerId = "owner_id"
        case createdBy = "created_by"
        case accountId = "account_id"
        case categoryId = "category_id"
        case occurredAt = "occurred_at"
        case originalAmountE4 = "original_amount_e4"
        case originalCurrency = "original_currency"
    }
}
