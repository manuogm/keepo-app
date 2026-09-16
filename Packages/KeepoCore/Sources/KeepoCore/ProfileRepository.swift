import Foundation
import Supabase

// The two repositories that read and write **who the user is** rather than
// what their money is doing: the supported-currency list, and the profile
// row that names their base currency, their display name and their avatar.
//
// Split out of `Repositories.swift` for the package's file-length lint,
// along the seam that was already there — everything below is about
// `profiles` and `currencies`, and nothing in it touches accounts or
// transactions.

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
    ///
    /// The name rides along in the same patch rather than being written when
    /// the user typed it, several steps earlier: onboarding can be abandoned
    /// at any step, and a profile carrying a name but no base currency is a
    /// half-signed-up user the rest of the app has no shape for.
    ///
    /// **`displayName` is optional because skipping the profile step is a
    /// real answer**, and the column's own CHECK
    /// (`profiles_display_name_length`) allows null but refuses an empty
    /// string — so "no name" has to be *absence*, not `""`. `nil` therefore
    /// omits the key entirely (synthesised `Encodable` uses
    /// `encodeIfPresent` for optionals), which also means a replayed
    /// onboarding cannot wipe a name the user already has.
    public static func completeOnboarding(
        client: SupabaseClient, userId: UUID, baseCurrency: String, displayName: String?
    ) async throws {
        let patch = ProfileOnboardingPatch(
            baseCurrency: baseCurrency,
            displayName: displayName,
            onboardedAt: PostgresDate.timestampString(Date())
        )
        try await client.from("profiles").update(patch).eq("id", value: userId).execute()
    }

    #if DEBUG
    /// Puts the account back to "never onboarded" so the setup flow can be
    /// walked again on a real device without deleting the app.
    ///
    /// **DEBUG only, and it is not a tidy-up**: it clears `onboarded_at`
    /// and nothing else, so the accounts, categories and dashboard a
    /// previous run created are all still there. That is deliberate — the
    /// thing worth replaying is the *flow*, and destroying a tester's data
    /// to do it would make the affordance too dangerous to reach for.
    ///
    /// It works at all because `onboarded_at` is inside profiles' own
    /// column-scoped UPDATE grant (S-06), alongside `base_currency`,
    /// `display_name` and `avatar_path`.
    public static func resetOnboarding(client: SupabaseClient, userId: UUID) async throws {
        try await client.from("profiles")
            .update(ProfileOnboardingResetPatch(onboardedAt: nil))
            .eq("id", value: userId)
            .execute()
    }
    #endif

    /// Online-only, deliberately, and the same for `updateBaseCurrency`
    /// below: the app reads `session.profile` from the **server**, not from
    /// the local mirror, so an offline write queued through the outbox would
    /// land in a table nothing renders from while the name on screen stayed
    /// stale. Both of a profile's editable fields behave the same way rather
    /// than one of them being quietly special.
    public static func updateDisplayName(client: SupabaseClient, userId: UUID, displayName: String) async throws {
        let patch = ProfileDisplayNamePatch(displayName: displayName)
        try await client.from("profiles").update(patch).eq("id", value: userId).execute()
    }

    /// `nil` clears it. The column's own CHECK requires any non-nil value to
    /// start with the profile's id, so this cannot record another user's
    /// object even if a caller tried.
    public static func updateAvatarPath(client: SupabaseClient, userId: UUID, avatarPath: String?) async throws {
        let patch = ProfileAvatarPathPatch(avatarPath: avatarPath)
        try await client.from("profiles").update(patch).eq("id", value: userId).execute()
    }

    /// A plain RLS-scoped update — `profiles_update`'s policy already
    /// allows this. Changing `base_currency` fires
    /// `profiles_backfill_fx_on_base_currency_change` (Phase 13) server-side
    /// automatically; nothing extra to trigger from here.
    public static func updateBaseCurrency(client: SupabaseClient, userId: UUID, baseCurrency: String) async throws {
        let patch = ProfileBaseCurrencyPatch(baseCurrency: baseCurrency)
        try await client.from("profiles").update(patch).eq("id", value: userId).execute()
    }
}

private struct ProfileOnboardingPatch: Encodable {
    let baseCurrency: String
    /// Omitted when nil, deliberately — see `completeOnboarding`. The
    /// opposite case needed a hand-written encoder (`ProfileOnboardingResetPatch`).
    let displayName: String?
    let onboardedAt: String
    enum CodingKeys: String, CodingKey {
        case baseCurrency = "base_currency"
        case displayName = "display_name"
        case onboardedAt = "onboarded_at"
    }
}

private struct ProfileDisplayNamePatch: Encodable {
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct ProfileAvatarPathPatch: Encodable {
    let avatarPath: String?
    enum CodingKeys: String, CodingKey {
        case avatarPath = "avatar_path"
    }
}

private struct ProfileBaseCurrencyPatch: Encodable {
    let baseCurrency: String
    enum CodingKeys: String, CodingKey {
        case baseCurrency = "base_currency"
    }
}

#if DEBUG
/// `onboarded_at` alone, explicitly `null`. A separate type from
/// `ProfileOnboardingPatch` because Swift's synthesized `Encodable` uses
/// `encodeIfPresent` for optionals — a nil field is **omitted**, not sent
/// as JSON null — so reusing that type would send an empty patch and change
/// nothing at all. This one encodes the null by hand.
private struct ProfileOnboardingResetPatch: Encodable {
    let onboardedAt: String?

    enum CodingKeys: String, CodingKey {
        case onboardedAt = "onboarded_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(onboardedAt, forKey: .onboardedAt)
    }
}
#endif
