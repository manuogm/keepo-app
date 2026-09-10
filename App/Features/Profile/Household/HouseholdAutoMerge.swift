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

        /// True when not one shared group held both members' rows, which is
        /// what an incomplete mirror looks like — never what a real
        /// two-member household looks like, since sharing anything at all
        /// mints the other member's row in the same transaction.
        var sawNoPairs: Bool { mine.isEmpty && theirs.isEmpty }
    }

    /// Runs the pass and returns the shared groups it created, if any.
    @discardableResult
    static func run(session: SessionStore, selectedCategoryIds: [UUID]) async throws -> Set<UUID> {
        guard let viewer = session.profile?.id else { return [] }
        let selected = Set(selectedCategoryIds)

        var candidates = await read(session: session, viewer: viewer, selected: selected)
        // The pass reads the local mirror, and it runs seconds after the
        // other phone's `accept_invite` — so the one way it can find nothing
        // is that the pull carrying their rows has not landed. Looking once
        // and quietly concluding "nothing to merge" is how a household ends
        // up built with every near-miss unmatched and no sign anything went
        // wrong. Ask again before believing it.
        if candidates.sawNoPairs {
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
                  let theirRow = rows.first(where: { $0.ownerId != viewer }) else { continue }
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
