import KeepoCore
import SwiftUI

/// The automatic pass that proposes which of the two members' categories are
/// the same category.
///
/// Its own type rather than a method on `HouseholdSetupCoordinator`, because
/// **both** roads into a household need it and only one of them has a
/// coordinator: the ceremony runs it as its "Merging Categories" step, and the
/// QR fallback — which has no peer link and therefore no ceremony — has to run
/// exactly the same pass the moment the other member appears. Leaving it on
/// the coordinator meant a household built over QR silently arrived with every
/// near-miss unmatched, which is the one thing the report exists to prevent.
///
/// ## Telling an original from a twin
///
/// After `accept_invite`, every shared category is a *pair* of rows —
/// `ensure_category_twin` creates the other member's row when they had no
/// exact name match. So both members now own rows they never made, and
/// fuzzy-matching everything against everything would propose merging my
/// "Dine Out" with the copy of my own "Dine Out" sitting on their phone.
///
/// The discriminator is `selectedCategoryIds`: a group whose row **on my
/// side** is one I chose to share is a group I originated, so my row is the
/// original and theirs is the twin. Every other group came from them, so
/// their row is the original. Matching originals against originals is the
/// only pairing that means anything.
@MainActor
enum HouseholdAutoMerge {
    /// One side's candidates, and their kinds — everything `pair` needs.
    private struct Candidates {
        var mine: [CategoryNameMatcher.Candidate<UUID>] = []
        var theirs: [CategoryNameMatcher.Candidate<UUID>] = []
        var kinds: [UUID: PublicSchema.CategoryKind] = [:]
        /// Shared groups the mirror held only half of.
        var halfGroups = 0

        /// Whether the mirror can be believed.
        ///
        /// **One row per member per shared group is the invariant**, written
        /// in the same transaction that creates the group — so a group with
        /// one row locally is never a real state of the household, it is a
        /// pull that has not finished landing. Every such group is skipped,
        /// silently, and a skipped group is a near-miss nobody will ever be
        /// offered again: the report's own `split` drops it too, so it does
        /// not even appear under Extra for the owner to merge by hand.
        ///
        /// This used to ask only whether the pass had found *nothing*, which
        /// catches a mirror that is entirely empty and misses the far more
        /// likely one that is merely behind — half the groups landed, half
        /// did not, and the household is built with an arbitrary subset of
        /// its duplicates merged.
        var isTrustworthy: Bool { halfGroups == 0 && !(mine.isEmpty && theirs.isEmpty) }
    }

    /// Runs the pass and returns the shared groups it created, if any.
    @discardableResult
    static func run(session: SessionStore, selectedCategoryIds: [UUID]) async throws -> Set<UUID> {
        guard let viewer = session.profile?.id else { return [] }
        let selected = Set(selectedCategoryIds)

        var candidates = await read(session: session, viewer: viewer, selected: selected)
        // The pass reads the local mirror, and it runs seconds after the
        // other phone's `accept_invite` — so anything missing from it is a
        // pull still in flight, not a fact about the household. Believing it
        // first time is how a household gets built with an arbitrary subset
        // of its near-misses merged and no sign anything went wrong. Ask
        // again before believing it.
        if !candidates.isTrustworthy {
            await session.syncNow()
            candidates = await read(session: session, viewer: viewer, selected: selected)
        }

        let mine = candidates.mine
        let theirs = candidates.theirs
        let kinds = candidates.kinds

        // Kind is part of what a category *is*, so the two lists are paired
        // once per kind rather than filtered afterwards — an expense
        // "Transport" must never be offered the income "Transport" as a
        // partner just because it scored well, and the RPC would refuse it
        // anyway.
        var merges: [CategoryMerge] = []
        for kind in [PublicSchema.CategoryKind.expense, .income] {
            let matches = CategoryNameMatcher.pair(
                mine: mine.filter { kinds[$0.id] == kind },
                theirs: theirs.filter { kinds[$0.id] == kind }
            )
            merges.append(contentsOf: matches.map { CategoryMerge(mine: $0.mine, theirs: $0.theirs) })
        }

        guard !merges.isEmpty else { return [] }
        try await HouseholdRepository.applyCategoryMerges(
            client: session.client, merges: merges, automatic: true
        )
        await session.syncNow()
        return await groupIds(session: session, for: merges.map(\.mine))
    }

    /// Both members' shared categories, sorted into the two sides of a
    /// pairing.
    private static func read(
        session: SessionStore, viewer: UUID, selected: Set<UUID>
    ) async -> Candidates {
        let categories = (try? await session.dbQueue.read { database in
            try LocalTableQueries.householdCategories(database)
        }) ?? []

        let shared = categories.filter { $0.sharedGroupId != nil && !$0.isDefault }
        let byGroup = Dictionary(grouping: shared, by: { $0.sharedGroupId ?? UUID() })

        var candidates = Candidates()
        for (_, rows) in byGroup {
            guard let myRow = rows.first(where: { $0.ownerId == viewer }),
                  let theirRow = rows.first(where: { $0.ownerId != viewer }) else {
                candidates.halfGroups += 1
                continue
            }
            candidates.kinds[myRow.id] = myRow.kind
            candidates.kinds[theirRow.id] = theirRow.kind
            if selected.contains(myRow.id) {
                candidates.mine.append(.init(id: myRow.id, name: myRow.name))
            } else {
                candidates.theirs.append(.init(id: theirRow.id, name: theirRow.name))
            }
        }
        return candidates
    }

    /// Which shared groups the pass produced. Read back rather than assumed:
    /// `apply_category_merges` reuses whichever group already existed, so the
    /// id is the server's answer, not one this side chose.
    private static func groupIds(session: SessionStore, for categoryIds: [UUID]) async -> Set<UUID> {
        let wanted = Set(categoryIds)
        let categories = (try? await session.dbQueue.read { database in
            try LocalTableQueries.householdCategories(database)
        }) ?? []
        return Set(categories.filter { wanted.contains($0.id) }.compactMap(\.sharedGroupId))
    }
}
