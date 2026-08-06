import Foundation
import Supabase

public enum CurrencyRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.CurrenciesSelect] {
        try await client.from("currencies").select().order("code").execute().value
    }
}

public enum ProfileRepository {
    public static func fetchOwn(client: SupabaseClient, userId: UUID) async throws -> PublicSchema.ProfilesSelect {
        try await client.from("profiles").select().eq("id", value: userId).single().execute().value
    }

    /// Sets base_currency and onboarded_at together — the DB's
    /// onboarded_requires_base_currency CHECK constraint means these can
    /// never be split into two calls without a moment of invalid state.
    public static func completeOnboarding(client: SupabaseClient, userId: UUID, baseCurrency: String) async throws {
        let patch = ProfileOnboardingPatch(
            baseCurrency: baseCurrency,
            onboardedAt: PostgresDate.timestampString(Date())
        )
        try await client.from("profiles").update(patch).eq("id", value: userId).execute()
    }
}

private struct ProfileOnboardingPatch: Encodable {
    let baseCurrency: String
    let onboardedAt: String
    enum CodingKeys: String, CodingKey {
        case baseCurrency = "base_currency"
        case onboardedAt = "onboarded_at"
    }
}

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
    /// & Offline). For a `valuation` account, opening_balance alone is not
    /// enough to render a balance: account_balances reads valuation balances
    /// only from balance_snapshots, so this also writes the first snapshot
    /// in the same call, reusing the just-generated id rather than a
    /// round-trip insert-then-fetch.
    ///
    /// Seven named, self-explanatory parameters describing one new account —
    /// splitting into a params struct here would be an indirection layer
    /// with no reader benefit, not a simplification.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        ownerId: UUID,
        kind: PublicSchema.AccountKind,
        subtype: PublicSchema.AccountSubtype,
        name: String,
        currency: String,
        openingBalance: Decimal
    ) async throws -> UUID {
        let accountId = UUID()
        let row = NewAccountRow(
            id: accountId,
            ownerId: ownerId,
            createdBy: ownerId,
            kind: kind,
            subtype: subtype,
            name: name,
            currency: currency,
            openingBalance: openingBalance
        )
        try await client.from("accounts").insert(row).execute()

        if kind == .valuation {
            try await insertFirstSnapshot(
                client: client,
                accountId: accountId,
                currency: currency,
                value: openingBalance,
                ownerId: ownerId
            )
        }

        return accountId
    }

    private static func insertFirstSnapshot(
        client: SupabaseClient,
        accountId: UUID,
        currency: String,
        value: Decimal,
        ownerId: UUID
    ) async throws {
        let snapshot = NewSnapshotRow(
            accountId: accountId,
            currency: currency,
            asOf: PostgresDate.dateOnlyString(Date()),
            value: value,
            createdBy: ownerId
        )
        try await client.from("balance_snapshots").insert(snapshot).execute()
    }
}

private struct NewAccountRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let createdBy: UUID
    let kind: PublicSchema.AccountKind
    let subtype: PublicSchema.AccountSubtype
    let name: String
    let currency: String
    let openingBalance: Decimal
    enum CodingKeys: String, CodingKey {
        case id, kind, subtype, name, currency
        case ownerId = "owner_id"
        case createdBy = "created_by"
        case openingBalance = "opening_balance"
    }
}

private struct NewSnapshotRow: Encodable {
    let accountId: UUID
    let currency: String
    let asOf: String
    let value: Decimal
    let createdBy: UUID
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case currency, value
        case asOf = "as_of"
        case createdBy = "created_by"
    }
}

public enum CategoryRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.CategoriesSelect] {
        try await client.from("categories").select().order("kind").order("name").execute().value
    }

    @discardableResult
    public static func create(
        client: SupabaseClient,
        ownerId: UUID,
        kind: PublicSchema.CategoryKind,
        name: String
    ) async throws -> UUID {
        let id = UUID()
        let row = NewCategoryRow(id: id, ownerId: ownerId, kind: kind, name: name)
        try await client.from("categories").insert(row).execute()
        return id
    }

    public static func rename(client: SupabaseClient, categoryId: UUID, name: String) async throws {
        try await client.from("categories").update(NamePatch(name: name)).eq("id", value: categoryId).execute()
    }

    /// Rejected by the DB (prevent_default_category_deletion trigger, not
    /// just a hidden UI affordance) if this is one of the two default
    /// "Other" categories.
    public static func softDelete(client: SupabaseClient, categoryId: UUID) async throws {
        try await client.from("categories")
            .update(DeletedAtPatch(deletedAt: PostgresDate.timestampString(Date())))
            .eq("id", value: categoryId)
            .execute()
    }
}

private struct NewCategoryRow: Encodable {
    let id: UUID
    let ownerId: UUID
    let kind: PublicSchema.CategoryKind
    let name: String
    enum CodingKeys: String, CodingKey {
        case id, kind, name
        case ownerId = "owner_id"
    }
}

private struct NamePatch: Encodable {
    let name: String
}

private struct DeletedAtPatch: Encodable {
    let deletedAt: String
    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
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

    /// Expense or income — a plain insert. The DB's sign_matches_category_kind
    /// CHECK makes a wrong sign impossible; nothing here re-signs the amount
    /// (money rule: never re-sign in application code). `amount` must
    /// already carry the correct sign for the category's kind.
    ///
    /// Six named, self-explanatory parameters describing one transaction —
    /// same reasoning as AccountRepository.create above.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient,
        ownerId: UUID,
        accountId: UUID,
        categoryId: UUID,
        amount: Decimal,
        currency: String,
        occurredAt: Date = Date()
    ) async throws -> UUID {
        let id = UUID()
        let row = NewTransactionRow(
            id: id,
            ownerId: ownerId,
            createdBy: ownerId,
            accountId: accountId,
            categoryId: categoryId,
            amount: amount,
            currency: currency,
            occurredAt: PostgresDate.timestampString(occurredAt)
        )
        try await client.from("transactions").insert(row).execute()
        return id
    }

    /// The only transaction kind with an RPC — both legs, signed in SQL, in
    /// one call. `toAmount` is `nil` for a same-currency transfer (the DB
    /// infers it equals `fromAmount`); required when currencies differ.
    public static func createTransfer(
        client: SupabaseClient,
        fromAccountId: UUID,
        toAccountId: UUID,
        fromAmount: Decimal,
        toAmount: Decimal? = nil,
        occurredAt: Date = Date()
    ) async throws {
        let params = CreateTransferParams(
            fromAccountId: fromAccountId,
            toAccountId: toAccountId,
            fromAmount: fromAmount,
            toAmount: toAmount,
            occurredAt: PostgresDate.timestampString(occurredAt)
        )
        try await client.rpc("create_transfer", params: params).execute()
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
        amount: Decimal,
        currency: String,
        occurredAt: Date = Date(),
        merchantRaw: String?
    ) async throws -> WriteResult {
        let params = UpdateTransactionParams(
            id: id,
            expectedVersion: expectedVersion,
            accountId: accountId,
            categoryId: categoryId,
            amount: amount,
            currency: currency,
            occurredAt: PostgresDate.timestampString(occurredAt),
            merchantRaw: merchantRaw
        )
        let rows: [ConflictRow] = try await client.rpc("update_transaction", params: params).execute().value
        return rows.first.map(WriteResult.init) ?? .conflict
    }

    /// Both legs' amount/date, updated atomically with each leg's own
    /// expected version — see `update_transfer` in migration 003.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func updateTransfer(
        client: SupabaseClient,
        transferGroupId: UUID,
        fromExpectedVersion: Int,
        toExpectedVersion: Int,
        fromAmount: Decimal,
        toAmount: Decimal,
        occurredAt: Date = Date()
    ) async throws -> WriteResult {
        let params = UpdateTransferParams(
            transferGroupId: transferGroupId,
            fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion,
            fromAmount: fromAmount,
            toAmount: toAmount,
            occurredAt: PostgresDate.timestampString(occurredAt)
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
    let amount: Decimal
    let currency: String
    let occurredAt: String
    enum CodingKeys: String, CodingKey {
        case id, amount, currency
        case ownerId = "owner_id"
        case createdBy = "created_by"
        case accountId = "account_id"
        case categoryId = "category_id"
        case occurredAt = "occurred_at"
    }
}

private struct CreateTransferParams: Encodable {
    let fromAccountId: UUID
    let toAccountId: UUID
    let fromAmount: Decimal
    let toAmount: Decimal?
    let occurredAt: String
    enum CodingKeys: String, CodingKey {
        case fromAccountId = "p_from_account_id"
        case toAccountId = "p_to_account_id"
        case fromAmount = "p_from_amount"
        case toAmount = "p_to_amount"
        case occurredAt = "p_occurred_at"
    }
}
