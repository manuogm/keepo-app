import Foundation
import GRDB
import KeepoCore
import Supabase

/// The pull side of Phase L5's sync engine (`keepo-local-first-plan.md`) —
/// `Outbox` already is, and remains, the push side; nothing about pushing
/// changes here. One `pull()` call round-trips `pull_changes` once and
/// applies the result: the RPC itself has no pagination (`jsonb_agg` of
/// every row past the cursor, unbounded), so a single call already returns
/// the full backlog, however large — no internal retry loop is needed for
/// that. `pull()` is triggered from the same seams `Outbox.drainAll()`
/// already uses (`RootView`'s scenePhase-active handler, `NetworkMonitor`
/// regaining connectivity, and every sign-in path in `SessionStore`) — see
/// that file's own header comment for why a Realtime nudge is deferred
/// rather than built here.
@Observable @MainActor
public final class SyncEngine {
    private let dbQueue: DatabaseQueue
    private let puller: SyncPulling
    private let userId: String
    public private(set) var isSyncing = false
    public private(set) var lastErrorMessage: String?
    /// Backs `OfflineStatusBar`'s "Last synced …" — persisted in
    /// `SyncCursorStore` (not just in-memory) so a relaunch shows a real
    /// timestamp from before this session started, not nothing until the
    /// next pull completes.
    public var lastSyncedAt: Date? { SyncCursorStore.lastSyncedAt(for: userId) }

    public init(dbQueue: DatabaseQueue, puller: SyncPulling, userId: String) {
        self.dbQueue = dbQueue
        self.puller = puller
        self.userId = userId
    }

    /// A no-op while a pull is already in flight — the four trigger sites
    /// can fire close together (e.g. sign-in immediately followed by the
    /// scene becoming active), and two overlapping pulls racing to write
    /// the same cursor would be a real hazard, not just wasted work.
    public func pull() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await pullOnce()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = UserFacingError.describe(error)
        }
    }

    private func pullOnce() async throws {
        let cursor = SyncCursorStore.cursor(for: userId)
        let globalCursor = SyncCursorStore.globalCursor(for: userId)
        let storedEpoch = SyncCursorStore.epoch(for: userId)

        let result = try await puller.pullChanges(cursor: cursor, globalCursor: globalCursor)

        // A stored epoch that differs from the fresh one means this
        // device's access changed since its last pull (gained or lost a
        // shared account, left/joined a household) — every cursor value
        // this device holds is denominated in a domain numbering that may
        // no longer even apply. The plan's own answer: drop every
        // server-derived table (never the outbox — unsynced local writes
        // are not what changed), reset cursors to 0, and re-pull fresh.
        guard let storedEpoch, storedEpoch != result.syncEpoch else {
            try await applyAndSave(result)
            return
        }

        try await dbQueue.write { database in try SyncApply.wipeServerDerivedTables(database) }
        SyncCursorStore.reset(for: userId)
        let freshResult = try await puller.pullChanges(cursor: 0, globalCursor: 0)
        try await applyAndSave(freshResult)
    }

    private func applyAndSave(_ result: PullChangesResult) async throws {
        try await dbQueue.write { database in try SyncApply.apply(result.payload, in: database) }
        SyncCursorStore.save(
            cursor: result.nextCursor, globalCursor: result.nextGlobalCursor, epoch: result.syncEpoch, for: userId
        )
    }
}

/// The protocol seam `SyncEngineTests` stubs — same reasoning as `Outbox`'s
/// own `OutboxSending`: a live network call has no place in a unit test.
public protocol SyncPulling: Sendable {
    func pullChanges(cursor: Int64, globalCursor: Int64) async throws -> PullChangesResult
}

public struct LiveSyncPuller: SyncPulling {
    public let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public func pullChanges(cursor: Int64, globalCursor: Int64) async throws -> PullChangesResult {
        try await SyncRepository.pullChanges(client: client, cursor: cursor, globalCursor: globalCursor)
    }
}
