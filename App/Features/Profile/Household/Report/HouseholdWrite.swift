import GRDB
import KeepoCore
import SwiftUI

/// The report's one write path: call the server, pull, and refuse to call it
/// done until **this device can actually see it**.
///
/// ## Why a shared seam rather than three copies of four lines
///
/// Every action on the report was written the same way — call the RPC, sync,
/// tell the parent to reload, dismiss — and every one of them treated *the
/// RPC returning* as the end of the operation. It is not. The report's whole
/// content comes from the local mirror, so an action is finished when the
/// mirror reflects it, and the gap between those two moments is where all
/// three reported failures lived:
///
///   * A tombstone the server wrote but RLS hid from this member
///     (`delete_tag_retagging` before `20260918100000`).
///   * A pull that failed — rate-limited, timed out, offline — after a write
///     that succeeded.
///   * A pull that was silently dropped because another one was in flight
///     (`SyncEngine.pull()` before it chained callers).
///
/// In all three the sheet closed, the list redrew exactly as it was, and
/// nothing anywhere said a word. From the user's side that is
/// indistinguishable from the button doing nothing — which is precisely how
/// it was reported, three times, for three different underlying causes.
///
/// So the confirmation is part of the act. `landed` is asked of the mirror
/// after the pull; if it says no, the write is reported as *not visible*
/// rather than as done, the sheet stays open, and the message carries
/// whatever the sync layer itself complained about. The user gets a retry
/// instead of a shrug, and the next bug in this area arrives with a sentence
/// attached.
///
/// Three call sites is exactly the point CLAUDE.md says to extract at.
@MainActor
enum HouseholdWrite {
    /// The server took it; this device cannot see it.
    ///
    /// Deliberately **not** phrased as a failure of the action — it did
    /// happen, and telling somebody their merge failed when it did not would
    /// invite them to do it twice.
    struct NotVisible: LocalizedError {
        /// What the sync layer said, when it said anything. A pull that
        /// succeeded and simply carried nothing leaves this nil, which is its
        /// own diagnosis.
        let reason: String?

        var errorDescription: String? {
            let base = "Saved, but this phone hasn't caught up yet."
            guard let reason else { return base + " Check your connection and try again." }
            // The reason is whatever the sync layer said, and a Postgres
            // message ("rate limit exceeded") arrives uncapitalised — it is
            // the second sentence here, not the first, so it gets a capital
            // rather than a rewrite. Rewriting it would hide the one word
            // that says which layer failed.
            return base + " " + reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    /// `UserFacingError.describe` suppresses anything it does not recognise
    /// into "Something went wrong" — the right default for a raw Postgres
    /// error and the wrong one for a sentence written for this screen. Same
    /// reasoning as `HouseholdSetupCoordinator`'s handling of
    /// `HouseholdLinkError`.
    static func describe(_ error: Error) -> String {
        (error as? NotVisible)?.errorDescription ?? UserFacingError.describe(error)
    }

    /// What the mirror holds, for `landed` to make its judgement on. Both
    /// lists, because a merge is answered by categories and a prune by tags,
    /// and one shape for the seam beats two near-identical ones.
    struct Mirror {
        let categories: [PublicSchema.CategoriesSelect]
        let tags: [PublicSchema.TagsSelect]
    }

    /// Runs `perform`, pulls, and confirms against the mirror.
    ///
    /// The second look is not superstition: `bump_household_sync_epochs`
    /// makes the pull behind these writes a wipe-and-re-pull, and the report
    /// can ask its question while that is still landing. One extra sync is
    /// cheap next to reporting a false negative on a write that did happen.
    static func apply(
        session: SessionStore,
        perform: () async throws -> Void,
        landed: (Mirror) -> Bool
    ) async throws {
        try await perform()

        await session.syncNow()
        if landed(await read(session: session)) {
            session.refresh.bump()
            return
        }

        await session.syncNow()
        guard landed(await read(session: session)) else {
            throw NotVisible(reason: session.syncEngine?.lastErrorMessage)
        }
        session.refresh.bump()
    }

    private static func read(session: SessionStore) async -> Mirror {
        let rows = try? await session.dbQueue.read { database in
            (
                try LocalTableQueries.householdCategories(database),
                try LocalTableQueries.tags(database)
            )
        }
        return Mirror(categories: rows?.0 ?? [], tags: rows?.1 ?? [])
    }
}

extension HouseholdWrite.Mirror {
    /// Both rows are live, in one group, and that group is recorded as a
    /// merge — the three facts that make the report draw them as one
    /// category. Anything less and the screen would not change, which is the
    /// whole thing being checked.
    func isMerged(mine: UUID, theirs: UUID) -> Bool {
        guard let myRow = categories.first(where: { $0.id == mine }),
              let theirRow = categories.first(where: { $0.id == theirs }),
              let group = myRow.sharedGroupId else { return false }
        return theirRow.sharedGroupId == group && myRow.mergeOrigin != nil
    }

    /// No live row still carries the group. An unmerge that left one behind
    /// would redraw as still merged.
    func isUnmerged(group: UUID) -> Bool {
        !categories.contains { $0.sharedGroupId == group }
    }

    /// The tag is gone from this device's list — which, for the other
    /// member's tag, arrives as a full re-pull rather than as a tombstone.
    func isGone(tag: UUID) -> Bool {
        !tags.contains { $0.id == tag }
    }
}
