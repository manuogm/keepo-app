import Foundation
import Supabase

/// Phase 7's client-side seam for the household access model. Deliberately
/// thin — invites/leave/fork are Phase 19; this only creates a household,
/// shares/unshares one of the caller's own accounts into it, and reads the
/// scoped net worth totals RLS + net_worth() already compute correctly.
public enum HouseholdRepository {
    /// `nil` if the caller doesn't belong to a household yet — RLS
    /// (`households_select`) already scopes this to at most one row.
    public static func fetchMine(client: SupabaseClient) async throws -> PublicSchema.HouseholdsSelect? {
        let rows: [PublicSchema.HouseholdsSelect] = try await client.from("households").select().execute().value
        return rows.first
    }

    public static func fetchMembers(client: SupabaseClient) async throws -> [PublicSchema.HouseholdMembersSelect] {
        try await client.from("household_members").select().order("joined_at").execute().value
    }

    /// Every account currently shared into a household the caller belongs
    /// to — cross-referenced client-side against `AccountRepository.
    /// fetchAllOwnedByMe` to build the per-account share/unshare list, so no
    /// migration was needed just to expose ownership on the enriched view.
    public static func fetchSharedAccountIds(client: SupabaseClient) async throws -> Set<UUID> {
        let rows: [PublicSchema.HouseholdAccountsSelect] = try await client.from("household_accounts")
            .select()
            .execute()
            .value
        return Set(rows.compactMap(\.accountId))
    }

    @discardableResult
    public static func create(client: SupabaseClient) async throws -> PublicSchema.HouseholdsSelect {
        try await client.rpc("create_household").execute().value
    }

    public static func share(client: SupabaseClient, accountId: UUID) async throws {
        try await client.rpc("share_account", params: AccountIdParam(accountId: accountId)).execute()
    }

    public static func unshare(client: SupabaseClient, accountId: UUID) async throws {
        try await client.rpc("unshare_account", params: AccountIdParam(accountId: accountId)).execute()
    }

    /// `nil` means "cannot be computed" (a missing FX rate somewhere in
    /// scope) — money rule 5, renders as "—", never 0. A scope with zero
    /// accounts is a real, computable 0, distinct from that; net_worth()
    /// itself is what tells the two apart, not this call site.
    public static func netWorth(client: SupabaseClient, scope: PublicSchema.AccountScope) async throws -> Decimal? {
        try await client.rpc("net_worth", params: ScopeParam(scope: scope)).execute().value
    }

    /// No `pg_cron` exists yet (Phase 13) — the client refreshes its own
    /// window before reading the trajectory. `p_user` must be the caller's
    /// own id; the RPC itself enforces that.
    public static func refreshNetWorthDaily(
        client: SupabaseClient, userId: UUID, from: Date, through: Date
    ) async throws {
        let params = RefreshNetWorthDailyParams(
            userId: userId,
            from: PostgresDate.dateOnlyString(from),
            through: PostgresDate.dateOnlyString(through)
        )
        try await client.rpc("refresh_net_worth_daily", params: params).execute()
    }

    /// One point per day that has data — a day with no accounts in scope
    /// simply isn't in the result (see the RPC's own doc comment); `total`
    /// is `nil` for a day with an unconvertible account in scope, never a
    /// silently-partial sum (money rule 5).
    public static func netWorthSeries(
        client: SupabaseClient,
        scope: PublicSchema.AccountScope,
        from: Date,
        through: Date
    ) async throws -> [NetWorthPoint] {
        let params = NetWorthSeriesParams(
            scope: scope,
            from: PostgresDate.dateOnlyString(from),
            through: PostgresDate.dateOnlyString(through)
        )
        return try await client.rpc("net_worth_series", params: params).execute().value
    }
}

public struct NetWorthPoint: Decodable, Sendable {
    public let asOf: String
    public let total: Decimal?
    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case total
    }
}

public extension AccountRepository {
    /// The raw rows the caller owns outright — used to build the Household
    /// screen's share/unshare list, which must offer only accounts the
    /// caller may legally share (share_account itself also enforces this;
    /// this just keeps the UI from offering a toggle that would just error).
    static func fetchAllOwnedByMe(client: SupabaseClient, ownerId: UUID) async throws -> [PublicSchema.AccountsSelect] {
        try await client.from("accounts")
            .select()
            .eq("owner_id", value: ownerId)
            .is("deleted_at", value: nil)
            .order("name")
            .execute()
            .value
    }
}

private struct AccountIdParam: Encodable {
    let accountId: UUID
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
    }
}

private struct ScopeParam: Encodable {
    let scope: PublicSchema.AccountScope
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
    }
}

private struct RefreshNetWorthDailyParams: Encodable {
    let userId: UUID
    let from: String
    let through: String
    enum CodingKeys: String, CodingKey {
        case userId = "p_user"
        case from = "p_from"
        case through = "p_to"
    }
}

private struct NetWorthSeriesParams: Encodable {
    let scope: PublicSchema.AccountScope
    let from: String
    let through: String
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
        case from = "p_from"
        case through = "p_to"
    }
}
