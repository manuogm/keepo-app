import Foundation
import GRDB
import KeepoCore

/// Extracted from `HouseholdView` purely to stay under the project's
/// type-body-length lint threshold — the load fan-out has no view state of
/// its own, only what `session` already exposes.
struct HouseholdViewState {
    var household: PublicSchema.HouseholdsSelect?
    var members: [PublicSchema.HouseholdMembersSelect] = []
    var myAccounts: [PublicSchema.AccountsSelect] = []
    var sharedAccountIds: Set<UUID> = []
    var events: [PublicSchema.HouseholdEventsSelect] = []
}

/// Everything here is a local read (Phase L6) except `events` —
/// `household_events` has no local table (it's a notification feed, not
/// money-bearing data, and the plan never called for mirroring it), so that
/// one piece stays a network call. This is the one screen L6 leaves
/// partially online-first, deliberately: fetching it is best-effort and its
/// absence never blocks the rest of the screen from working offline.
@MainActor
enum HouseholdViewLoader {
    static func load(session: SessionStore) async throws -> HouseholdViewState {
        guard let userId = session.profile?.id else { return HouseholdViewState() }
        var state = try await session.dbQueue.read { database in
            try loadLocal(database, userId: userId)
        }
        if state.household != nil {
            state.events = (try? await HouseholdRepository.fetchEvents(client: session.client)) ?? []
        }
        return state
    }

    private nonisolated static func loadLocal(_ database: Database, userId: UUID) throws -> HouseholdViewState {
        var state = HouseholdViewState()
        state.household = try LocalTableQueries.myHousehold(database, userId: userId.uuidString)
        if let household = state.household {
            state.members = try LocalTableQueries.householdMembers(database, householdId: household.id.uuidString)
            let sharedIds = try LocalTableQueries.sharedAccountIds(database, householdId: household.id.uuidString)
            state.sharedAccountIds = Set(sharedIds.compactMap { UUID(uuidString: $0) })
        }
        state.myAccounts = try LocalTableQueries.accountsOwnedBy(database, ownerId: userId.uuidString)
        return state
    }
}
