import KeepoCore
import SwiftUI

// The "Added by" pill's name lookup, split out of TransactionFormView+Data.swift
// purely to keep that file under the project's file-length lint threshold —
// same precedent as TransactionFormView+Transfer.swift.

extension TransactionFormView {
    /// The name on the "Added by" pill. Read-through against
    /// `HouseholdMemberNameCache`, keyed off the household id in the local
    /// mirror (cheap, offline-safe) — a hit skips the network entirely,
    /// which is the common case since a partner's name changes about as
    /// often as they do. Only a first-ever read, or one after a dissolve
    /// created a new household id, pays `household_member_profile()`'s round
    /// trip — best-effort like `HouseholdSnapshot.peer`: a failed or offline
    /// fetch just leaves the pill's generic fallback.
    func loadHouseholdMemberName() async {
        guard let ownerId = session.profile?.id else { return }
        let household = try? await session.dbQueue.read { database in
            try LocalTableQueries.myHousehold(database, userId: ownerId.uuidString)
        }
        guard let householdId = household?.id else { return }

        if let cached = HouseholdMemberNameCache.name(for: householdId) {
            householdMemberName = cached
            return
        }

        let peer = try? await HouseholdRepository.memberProfile(client: session.client)
        guard let name = peer?.displayName ?? peer?.email else { return }
        householdMemberName = name
        HouseholdMemberNameCache.save(name, for: householdId)
    }
}
