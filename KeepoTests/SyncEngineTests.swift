import Foundation
import GRDB
import KeepoCore
import Supabase
import Testing
@testable import Keepo

/// Exercises `SyncEngine`'s pull loop against a stubbed RPC — no network,
/// no live Postgres — mirroring `OutboxTests`' own precedent for this
/// project's drainer-style components (Phase 11's explicit Verify
/// requirement, reused here for L5's pull loop).
@Suite("SyncEngine pull loop")
@MainActor
struct SyncEngineTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    @Test("a pull upserts every row from every table key present in the payload")
    func pullAppliesUpserts() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString
        let puller = StubSyncPuller(results: [
            pullResult(accounts: [accountJSON(id: "acc-1")], nextCursor: 5, epoch: 1)
        ])
        let engine = SyncEngine(dbQueue: dbQueue, puller: puller, userId: userId)

        await engine.pull()

        let stored = try await dbQueue.read { database in
            try Row.fetchOne(database, sql: "SELECT name, currency FROM accounts WHERE id = 'acc-1'")
        }
        #expect(stored?["name"] == "Checking")
        #expect(stored?["currency"] == "EUR")
        #expect(engine.lastErrorMessage == nil)
    }

    @Test("a tombstoned row (deleted_at set) still upserts — no special DELETE path")
    func pullAppliesTombstones() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString
        let puller = StubSyncPuller(results: [
            pullResult(
                accounts: [accountJSON(id: "acc-2", deletedAt: "2026-08-13T00:00:00.000000+00:00")],
                nextCursor: 3, epoch: 1
            )
        ])
        let engine = SyncEngine(dbQueue: dbQueue, puller: puller, userId: userId)

        await engine.pull()

        let stored = try await dbQueue.read { database in
            try Row.fetchOne(database, sql: "SELECT deleted_at FROM accounts WHERE id = 'acc-2'")
        }
        #expect(stored != nil, "the row still exists locally — a tombstone is an upsert, not a delete")
        #expect(stored?["deleted_at"] == "2026-08-13T00:00:00.000000+00:00")
    }

    @Test("the cursor advances to next_cursor after a pull, and the next pull uses it")
    func cursorAdvances() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString
        let puller = StubSyncPuller(results: [
            PullChangesResult(payload: .object([:]), nextCursor: 42, nextGlobalCursor: 7, syncEpoch: 1),
            PullChangesResult(payload: .object([:]), nextCursor: 42, nextGlobalCursor: 7, syncEpoch: 1)
        ])
        let engine = SyncEngine(dbQueue: dbQueue, puller: puller, userId: userId)

        await engine.pull()
        #expect(SyncCursorStore.cursor(for: userId) == 42)
        #expect(SyncCursorStore.globalCursor(for: userId) == 7)

        await engine.pull()
        #expect(puller.receivedCursors == [0, 42])
    }

    @Test("an epoch mismatch wipes every server-derived table, resets the cursor, and re-pulls from 0")
    func epochMismatchWipesAndRepulls() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString

        // First pull: epoch 1, seeds an account and advances the cursor.
        let firstPuller = StubSyncPuller(results: [
            pullResult(accounts: [accountJSON(id: "acc-3")], nextCursor: 10, epoch: 1)
        ])
        let firstEngine = SyncEngine(dbQueue: dbQueue, puller: firstPuller, userId: userId)
        await firstEngine.pull()
        #expect(SyncCursorStore.cursor(for: userId) == 10)

        // Second pull: epoch jumps to 2 (a share/unshare/leave happened
        // server-side) — the stub's FIRST response (called with the stale
        // cursor 10) reports the new epoch; SyncEngine must then wipe,
        // reset, and issue a SECOND call with cursor 0, whose response is
        // what actually lands in the store.
        let secondPuller = StubSyncPuller(results: [
            pullResult(accounts: [accountJSON(id: "acc-4")], nextCursor: 1, epoch: 2),
            pullResult(accounts: [accountJSON(id: "acc-5")], nextCursor: 2, epoch: 2)
        ])
        let secondEngine = SyncEngine(dbQueue: dbQueue, puller: secondPuller, userId: userId)
        await secondEngine.pull()

        #expect(secondPuller.receivedCursors == [10, 0], "a mismatch forces a second call from cursor 0")

        let accounts = try await dbQueue.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM accounts ORDER BY id")
        }
        // acc-3 (from before the epoch change) is gone — wiped, not just
        // superseded — and acc-4 (the FIRST response, made stale by the
        // mismatch it itself reported) never landed; only the re-pull's
        // acc-5 is present.
        #expect(accounts == ["acc-5"])
        #expect(SyncCursorStore.cursor(for: userId) == 2)
    }

    @Test("two overlapping pull() calls do not race — the second is a no-op while the first is in flight")
    func overlappingPullsDoNotRace() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString
        let puller = SlowStubSyncPuller(
            result: PullChangesResult(payload: .object([:]), nextCursor: 1, nextGlobalCursor: 0, syncEpoch: 1)
        )
        let engine = SyncEngine(dbQueue: dbQueue, puller: puller, userId: userId)

        async let first: Void = engine.pull()
        async let second: Void = engine.pull()
        _ = await (first, second)

        #expect(puller.callCount == 1)
    }

    private func pullResult(accounts: [AnyJSON], nextCursor: Int64, epoch: Int64) -> PullChangesResult {
        PullChangesResult(
            payload: .object(["accounts": .array(accounts)]), nextCursor: nextCursor, nextGlobalCursor: 0,
            syncEpoch: epoch
        )
    }

    private func accountJSON(id: String, deletedAt: String? = nil) -> AnyJSON {
        .object([
            "id": .string(id), "owner_id": .string("owner-1"), "created_by": .string("owner-1"),
            "kind": .string("regular"), "name": .string("Checking"),
            "currency": .string("EUR"), "opening_balance_e4": .integer(0),
            "opening_balance_at": .string("2026-01-01"), "include_in_total": .bool(true),
            "icon": .string("banknote"), "color": .string("#8E8E93"), "version": .integer(1),
            "deleted_at": deletedAt.map(AnyJSON.string) ?? .null,
            "created_at": .string("2026-01-01T00:00:00.000000+00:00"),
            "updated_at": .string("2026-01-01T00:00:00.000000+00:00"), "sync_seq": .integer(1)
        ])
    }
}

private final class StubSyncPuller: SyncPulling, @unchecked Sendable {
    private var results: [PullChangesResult]
    private(set) var receivedCursors: [Int64] = []

    init(results: [PullChangesResult]) {
        self.results = results
    }

    func pullChanges(cursor: Int64, globalCursor: Int64) async throws -> PullChangesResult {
        receivedCursors.append(cursor)
        guard !results.isEmpty else {
            return PullChangesResult(
                payload: .object([:]), nextCursor: cursor, nextGlobalCursor: globalCursor, syncEpoch: 1
            )
        }
        return results.removeFirst()
    }
}

/// A slow stub for the overlapping-call test — real work (the DB write)
/// finishes fast enough that only an artificial delay in the RPC call
/// itself reliably keeps the first `pull()` "in flight" while the second
/// one is issued.
private final class SlowStubSyncPuller: SyncPulling, @unchecked Sendable {
    private let result: PullChangesResult
    private(set) var callCount = 0

    init(result: PullChangesResult) {
        self.result = result
    }

    func pullChanges(cursor: Int64, globalCursor: Int64) async throws -> PullChangesResult {
        callCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return result
    }
}
