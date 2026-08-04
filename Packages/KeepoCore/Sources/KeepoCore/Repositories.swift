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
            onboardedAt: ISO8601DateFormatter().string(from: Date())
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
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let snapshot = NewSnapshotRow(
            accountId: accountId,
            currency: currency,
            asOf: String(today),
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
