import Foundation
import KeepoCore
import Supabase

/// The household partner's display name, cached device-locally so reading it
/// — the transaction form's "Added by" pill, chiefly — almost never costs the
/// `household_member_profile()` round trip `HouseholdMemberProfile` itself
/// requires (that RPC exists *because* `profiles_select` keeps the other
/// member's row out of the local mirror; nothing here changes that, it just
/// stops the same answer being re-fetched for a fact that essentially never
/// changes).
///
/// **Keyed by household id, not stored flat.** That is the entire
/// invalidation strategy: the one case this needs to go stale without the
/// user renaming anything is a dissolve + a new household, and by then the
/// local mirror already has a different `households.id` — a mismatch is
/// self-evidently "fetch again," with no separate signal to keep in sync. A
/// rename, the other way this goes stale, is deliberately not chased with a
/// TTL or a push: `HouseholdDataLoader.load()` (the live Household screen and
/// the setup report) already re-fetches the peer profile fresh on every
/// visit and writes through here, so the cache heals itself the next time
/// either screen opens.
enum HouseholdMemberNameCache {
    private static let householdIdKey = "app.keepo.household.peerNameHouseholdId"
    private static let nameKey = "app.keepo.household.peerName"

    /// `nil` for a first-ever read, or one for a different household than the
    /// entry on disk (a dissolve since the last write) — either way, the
    /// caller's cue to fetch fresh and `save` the answer.
    static func name(for householdId: UUID) -> String? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: householdIdKey) == householdId.uuidString else { return nil }
        return defaults.string(forKey: nameKey)
    }

    static func save(_ name: String, for householdId: UUID) {
        let defaults = UserDefaults.standard
        defaults.set(householdId.uuidString, forKey: householdIdKey)
        defaults.set(name, forKey: nameKey)
    }

    /// The partner's name for a household, cache first and the network only
    /// when the cache cannot answer — **the** read-through, called by the
    /// transaction form's "Added by" pill and by the ledger's "Added by"
    /// filter. Two copies of this would be two devices' worth of round trips
    /// and one more place to forget the `save`.
    ///
    /// `nil` is "not known on this device right now" (offline, or the RPC
    /// refused), never "no partner" — callers fall back to their own generic
    /// wording rather than asserting anything about the household.
    static func resolvedName(for householdId: UUID, client: SupabaseClient) async -> String? {
        if let cached = name(for: householdId) { return cached }
        guard let peer = try? await HouseholdRepository.memberProfile(client: client),
              let name = peer.displayName ?? peer.email
        else { return nil }
        save(name, for: householdId)
        return name
    }

    /// Called alongside `AvatarStore.clearAllCached()` and
    /// `SyncCursorStore.resetAll()` in `SessionStore.signOut()` — a name
    /// cached for one identity's partner must never render for the next
    /// person who signs into this device.
    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: householdIdKey)
        defaults.removeObject(forKey: nameKey)
    }
}
