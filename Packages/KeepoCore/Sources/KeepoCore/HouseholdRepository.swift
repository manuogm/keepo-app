import Foundation
import Supabase

/// Phase 7's client-side seam for the household access model, widened in
/// Phase 19 with the actual lifecycle: invites, leave (fork), erase.
public enum HouseholdRepository {
    /// The plaintext token, returned exactly once — never stored, never
    /// retrievable again. The caller is responsible for putting it in front
    /// of the invitee (share sheet, copy button, ...).
    /// The selections travel **with the invite**, not as writes made when it
    /// is created: until somebody accepts there is nobody to share with, and
    /// an invite that quietly changed the inviter's data before anyone used
    /// it would be a surprise the day it expired unused.
    ///
    /// `fullHistoryAccountIds` are the shared accounts that come with every
    /// past transaction; the rest are shared from the day the invite is
    /// accepted.
    public static func createInvite(
        client: SupabaseClient, accountIds: [UUID] = [], categoryIds: [UUID] = [], fullHistoryAccountIds: [UUID] = []
    ) async throws -> String {
        try await client.rpc(
            "create_invite",
            params: InviteSelectionParams(
                accountIds: accountIds, categoryIds: categoryIds, fullHistoryAccountIds: fullHistoryAccountIds
            )
        ).execute().value
    }

    /// What the invitee is about to receive, by name, holding nothing but the
    /// token — so "join this household" is a decision made with the answer in
    /// front of them rather than after the fact.
    public static func previewInvite(client: SupabaseClient, token: String) async throws -> [InvitePreviewRow] {
        try await client.rpc("preview_invite", params: TokenParam(token: token)).execute().value
    }

    /// Returns the household id the caller just joined. Both members' choices
    /// are applied here, in one transaction: the inviter's from the invite,
    /// the invitee's from these arguments.
    @discardableResult
    public static func acceptInvite(
        client: SupabaseClient, token: String, accountIds: [UUID] = [], categoryIds: [UUID] = [],
        fullHistoryAccountIds: [UUID] = []
    ) async throws -> UUID {
        try await client.rpc(
            "accept_invite",
            params: AcceptInviteParams(
                token: token, accountIds: accountIds, categoryIds: categoryIds,
                fullHistoryAccountIds: fullHistoryAccountIds
            )
        ).execute().value
    }

    /// A category becomes shared, or stops being. Same shape as `share`/
    /// `unshare` above so the Household screen can offer both identically.
    public static func shareCategory(client: SupabaseClient, categoryId: UUID) async throws {
        try await client.rpc("share_category", params: CategoryIdParam(categoryId: categoryId)).execute()
    }

    public static func unshareCategory(client: SupabaseClient, categoryId: UUID) async throws {
        try await client.rpc("unshare_category", params: CategoryIdParam(categoryId: categoryId)).execute()
    }

    /// Ends the household. Each member keeps their own accounts as they are,
    /// and is handed a copy of what they could see of the other's
    /// (20261012100000).
    public static func leave(client: SupabaseClient) async throws {
        try await client.rpc("leave_household").execute()
    }

    /// Undoes a household nobody has agreed to yet, which is **not** what
    /// `leave` does.
    ///
    /// Leaving dissolves a household that has existed, and forks every shared
    /// account into a private copy per member so neither loses the ledger
    /// they kept together. Using it to back out of a setup gave both people a
    /// duplicate of the other's accounts every time — right verb, wrong
    /// moment. This one removes the listing, unpicks the category sharing,
    /// deletes the rows the sharing minted, and leaves both members with
    /// exactly what they had. Either member may call it; the household is not
    /// real until the owner accepts the report.
    public static func discardHousehold(client: SupabaseClient) async throws {
        try await client.rpc("discard_household").execute()
    }

    /// The owner accepted the report: from here the household is real.
    ///
    /// Drops the undo log that made everything before this point reversible
    /// — chiefly the record of which transactions a pruned tag's labels moved
    /// to. Left lying about, a *later* household's abort could reach back and
    /// revert a prune that has been part of this one's history for months.
    public static func finalizeHousehold(client: SupabaseClient) async throws {
        try await client.rpc("finalize_household").execute()
    }

    /// Same fork, plus scrubbing the caller's own resulting copy's free-text
    /// fields (merchant names, filenames, ...) — never the other member's.
    public static func eraseOwnAccount(client: SupabaseClient) async throws {
        try await client.rpc("erase_own_account").execute()
    }

    /// The no-op-transport notification seam's read side — the client polls
    /// this rather than waiting on a push (Phase 20 swaps the transport,
    /// not this read path).
    public static func fetchEvents(client: SupabaseClient) async throws -> [PublicSchema.HouseholdEventsSelect] {
        try await client.from("household_events")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

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

    /// `fullHistory` false shares the account from the start of today; true
    /// shares every past transaction too.
    public static func share(client: SupabaseClient, accountId: UUID, fullHistory: Bool) async throws {
        try await client.rpc(
            "share_account", params: ShareAccountParams(accountId: accountId, fullHistory: fullHistory)
        ).execute()
    }

    /// Turns a share that began on a date into one with full history. There
    /// is no way back: narrowing a share is not offered.
    public static func shareFullHistory(client: SupabaseClient, accountId: UUID) async throws {
        try await client.rpc("share_full_history", params: AccountIdParam(accountId: accountId)).execute()
    }

    public static func unshare(client: SupabaseClient, accountId: UUID) async throws {
        try await client.rpc("unshare_account", params: AccountIdParam(accountId: accountId)).execute()
    }

    /// `nil` means "cannot be computed" (a missing FX rate somewhere in
    /// scope) — money rule 5, renders as "—", never 0. A scope with zero
    /// accounts is a real, computable 0, distinct from that; net_worth()
    /// itself is what tells the two apart, not this call site.
    public static func netWorth(client: SupabaseClient, scope: PublicSchema.AccountScope) async throws -> Int64? {
        try await client.rpc("net_worth", params: ScopeParam(scope: scope)).execute().value
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

private struct TokenParam: Encodable {
    let token: String
    enum CodingKeys: String, CodingKey {
        case token = "p_token"
    }
}

private struct ScopeParam: Encodable {
    let scope: PublicSchema.AccountScope
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
    }
}

/// One line of `preview_invite`: an account name, or a category name and its
/// kind. Exactly one of the two is non-nil per row — the RPC unions two
/// selects, because "what am I being given" is one list to the person reading
/// it even though it comes from two tables.
public struct InvitePreviewRow: Decodable, Hashable, Sendable {
    public let accountName: String?
    public let categoryName: String?
    public let categoryKind: PublicSchema.CategoryKind?
    /// On an account line: whether it comes with its past transactions.
    public let fullHistory: Bool?

    enum CodingKeys: String, CodingKey {
        case accountName = "account_name"
        case categoryName = "category_name"
        case categoryKind = "category_kind"
        case fullHistory = "full_history"
    }
}

private struct InviteSelectionParams: Encodable {
    let accountIds: [UUID]
    let categoryIds: [UUID]
    let fullHistoryAccountIds: [UUID]
    enum CodingKeys: String, CodingKey {
        case accountIds = "p_share_account_ids"
        case categoryIds = "p_share_category_ids"
        case fullHistoryAccountIds = "p_full_history_account_ids"
    }
}

private struct AcceptInviteParams: Encodable {
    let token: String
    let accountIds: [UUID]
    let categoryIds: [UUID]
    let fullHistoryAccountIds: [UUID]
    enum CodingKeys: String, CodingKey {
        case token = "p_token"
        case accountIds = "p_share_account_ids"
        case categoryIds = "p_share_category_ids"
        case fullHistoryAccountIds = "p_full_history_account_ids"
    }
}

private struct ShareAccountParams: Encodable {
    let accountId: UUID
    let fullHistory: Bool
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
        case fullHistory = "p_full_history"
    }
}

private struct CategoryIdParam: Encodable {
    let categoryId: UUID
    enum CodingKeys: String, CodingKey {
        case categoryId = "p_category_id"
    }
}
