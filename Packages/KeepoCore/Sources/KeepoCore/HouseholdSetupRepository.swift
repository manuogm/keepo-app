import Foundation
import Supabase

// The client seam for `20260913100000_household_setup_and_report.sql` — the
// setup ceremony's server half. Separate from `HouseholdRepository` for the
// project's file-length lint, and because these four calls belong to one
// screen (the owner's report) rather than to the household model in general.

/// The other member of your household, in the amount the Household screen is
/// entitled to show. Comes from `household_member_profile()`, never from a
/// `profiles` select — `profiles_select` is still `id = auth.uid()`, and
/// widening it for a name and a face would hand over the whole row.
public struct HouseholdMemberProfile: Decodable, Hashable, Sendable, Identifiable {
    public let userId: UUID
    public let displayName: String?
    public let email: String?
    /// **Their** base currency, not yours. The member card says what they see
    /// their own money in, which is the one fact on that card a viewer cannot
    /// infer from their own settings.
    public let baseCurrency: String?
    public let avatarPath: String?
    /// When they joined Keepo — the "member since" line, not when they joined
    /// this household.
    public let memberSince: String?
    /// Whether they created the household. Exactly one member is the owner,
    /// so this is also how the viewer learns they are not.
    public let isOwner: Bool

    public var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case email
        case baseCurrency = "base_currency"
        case avatarPath = "avatar_path"
        case memberSince = "member_since"
        case isOwner = "is_owner"
    }
}

/// One decision that two categories are the same category, on its way to the
/// server. `name`/`icon`/`color` are the **resultant** identity — what both
/// members' rows will read as afterwards — and each falls back to `mine`'s
/// own value server-side when omitted, which is what makes the automatic
/// merge a one-field payload.
public struct CategoryMerge: Encodable, Hashable, Sendable {
    public let mine: UUID
    public let theirs: UUID
    public let name: String?
    public let icon: String?
    public let color: String?

    public init(mine: UUID, theirs: UUID, name: String? = nil, icon: String? = nil, color: String? = nil) {
        self.mine = mine
        self.theirs = theirs
        self.name = name
        self.icon = icon
        self.color = color
    }
}

public extension HouseholdRepository {
    /// `nil` while you are alone in a household, or in none at all — both are
    /// states the Household screen draws differently, and neither is an error.
    static func memberProfile(client: SupabaseClient) async throws -> HouseholdMemberProfile? {
        let rows: [HouseholdMemberProfile] = try await client.rpc("household_member_profile").execute().value
        return rows.first
    }

    /// Owner-only. Returns how many merges were applied.
    ///
    /// Batched in one call rather than one call per pair, because the setup
    /// ceremony applies every automatic match at once and a half-applied set
    /// would leave a household nobody can reason about — the RPC runs them in
    /// a single transaction.
    ///
    /// `automatic` is what earns a merged category the robot glyph in the
    /// report. It is a property of the batch, not of an element: the fuzzy
    /// pass is one call nobody was asked about, and a merge the owner filled
    /// in by hand is another.
    @discardableResult
    static func applyCategoryMerges(
        client: SupabaseClient, merges: [CategoryMerge], automatic: Bool
    ) async throws -> Int {
        guard !merges.isEmpty else { return 0 }
        return try await client.rpc(
            "apply_category_merges", params: CategoryMergesParam(merges: merges, automatic: automatic)
        ).execute().value
    }

    /// Owner-only. Addressed by the shared group rather than by a row, because
    /// half of the pair being unmerged belongs to the other member.
    static func unmergeCategoryGroup(client: SupabaseClient, groupId: UUID) async throws {
        try await client.rpc("unmerge_category_group", params: GroupIdParam(groupId: groupId)).execute()
    }

    /// Deletes a tag, first moving every transaction wearing it onto
    /// `intoTagId`. Returns how many transactions were moved.
    ///
    /// `intoTagId` is optional and `nil` is the plain delete the Tags screen
    /// has always done. The report never passes `nil`: a tag it is pruning is
    /// redundant *with respect to another tag*, and dropping the label off
    /// somebody's transactions is not what "redundant" means.
    @discardableResult
    static func deleteTag(
        client: SupabaseClient, tagId: UUID, retaggingInto intoTagId: UUID?
    ) async throws -> Int {
        try await client.rpc(
            "delete_tag_retagging", params: DeleteTagRetaggingParams(tagId: tagId, intoTagId: intoTagId)
        ).execute().value
    }
}

// MARK: - Parameters

/// The merges arrive as one `jsonb` argument: `rpc(_:params:)` sends this
/// struct as the request body, so the array sitting at `p_merges` is exactly
/// the JSON array the parameter receives. `CategoryMerge`'s own optional
/// fields encode as absent keys, which is what lets the server fall back to
/// `mine`'s name, icon and colour for an automatic merge.
private struct CategoryMergesParam: Encodable {
    let merges: [CategoryMerge]
    let automatic: Bool

    enum CodingKeys: String, CodingKey {
        case merges = "p_merges"
        case automatic = "p_automatic"
    }
}

private struct GroupIdParam: Encodable {
    let groupId: UUID
    enum CodingKeys: String, CodingKey {
        case groupId = "p_group_id"
    }
}

private struct DeleteTagRetaggingParams: Encodable {
    let tagId: UUID
    /// Omitted from the body when nil — synthesized `Encodable` uses
    /// `encodeIfPresent` for optionals — which is exactly right here: the RPC
    /// declares `p_into_tag_id default null`, so an absent key and an
    /// explicit null mean the same thing, the plain delete.
    let intoTagId: UUID?

    enum CodingKeys: String, CodingKey {
        case tagId = "p_tag_id"
        case intoTagId = "p_into_tag_id"
    }
}
