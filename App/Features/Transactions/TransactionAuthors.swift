import Foundation
import KeepoCore

/// One person who can have entered a transaction this viewer can see.
///
/// `id` is a `transactions.created_by` value, which is what the ledger's
/// "Added by" filter puts in `TransactionFilter.createdByIds` — the id is the
/// filter and the name is only how it is labelled.
struct TransactionAuthor: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Who the ledger's "Added by" filter may offer.
///
/// **Empty unless a paired household exists**, and that is the whole
/// condition the screen needs: without a partner every row was entered by the
/// viewer, so the filter would be a control with one option that can only
/// ever change nothing. A household mid-pairing has a single member and is
/// treated the same way.
enum TransactionAuthors {
    /// The viewer first, then their partner — the order the drop-down lists
    /// them in, and the order a two-row sheet reads best in.
    ///
    /// Ids come from the local `household_members` mirror (offline-safe); the
    /// partner's *name* comes from `HouseholdMemberNameCache`'s read-through,
    /// the same one the transaction form's "Added by" pill uses, so a name
    /// already on this device costs no round trip. A name that cannot be
    /// resolved falls back to the wording that pill falls back to rather than
    /// dropping the partner from the filter — the rows exist either way, and
    /// hiding one because its label is unknown would silently narrow what the
    /// user can ask for.
    @MainActor
    static func load(session: SessionStore) async -> [TransactionAuthor] {
        guard let viewerId = session.profile?.id else { return [] }
        let household = try? await session.dbQueue.read { database -> (UUID, [UUID])? in
            guard let household = try LocalTableQueries.myHousehold(
                database, userId: viewerId.uuidString
            ) else { return nil }
            let members = try LocalTableQueries.householdMembers(
                database, householdId: household.id.uuidString
            )
            return (household.id, members.map(\.userId))
        }
        guard let (householdId, memberIds) = household,
              let partnerId = memberIds.first(where: { $0 != viewerId })
        else { return [] }

        let partnerName = await HouseholdMemberNameCache.resolvedName(
            for: householdId, client: session.client
        )
        return [
            TransactionAuthor(id: viewerId, name: "You"),
            TransactionAuthor(id: partnerId, name: partnerName ?? "Your household member")
        ]
    }
}
