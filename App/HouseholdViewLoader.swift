import KeepoCore
import Foundation

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

@MainActor
enum HouseholdViewLoader {
    static func load(session: SessionStore) async throws -> HouseholdViewState {
        var state = HouseholdViewState()
        state.household = try await HouseholdRepository.fetchMine(client: session.client)

        if state.household != nil {
            async let membersResult = HouseholdRepository.fetchMembers(client: session.client)
            async let sharedResult = HouseholdRepository.fetchSharedAccountIds(client: session.client)
            async let eventsResult = HouseholdRepository.fetchEvents(client: session.client)
            state.members = try await membersResult
            state.sharedAccountIds = try await sharedResult
            state.events = try await eventsResult
        }

        if let userId = session.profile?.id {
            state.myAccounts = try await AccountRepository.fetchAllOwnedByMe(client: session.client, ownerId: userId)
        }

        return state
    }
}
