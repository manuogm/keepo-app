import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `Outbox.repairLegacyCaptureQueueIfNeeded` (X-02) — split out of
/// `OutboxTests.swift` purely to keep that file under the project's
/// type-body-length lint threshold, same precedent as
/// `ReviewCaptureLocalWriteTests.swift`.
@Suite("Outbox legacy-capture repair sweep")
@MainActor
struct OutboxCaptureRecoveryTests {
    private func makeOutbox(sender: StubTransactionSender) throws -> Outbox {
        try makeOutboxWithQueue(sender: sender).0
    }

    private func makeOutboxWithQueue(sender: StubTransactionSender) throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: sender), dbQueue)
    }

    private func seedPendingCapture(_ dbQueue: DatabaseQueue, id: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, category_id, amount_e4, occurred_at, merchant_raw,
                    merchant_normalized, card_identifier, source, status, external_id, version,
                    created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'capture', 'pending', ?, 1, ?, ?, 0)
                """,
                arguments: [
                    id.uuidString, "owner-1", "owner-1", UUID().uuidString, -45000,
                    PostgresDate.sqliteTimestampBoundaryString(Date()), "Blue Bottle", "BLUE BOTTLE", "card-1",
                    "ext-1", PostgresDate.sqliteTimestampBoundaryString(Date()),
                    PostgresDate.sqliteTimestampBoundaryString(Date())
                ]
            )
        }
    }

    /// Regression: repairs items already corrupted by the pre-fix
    /// `enqueue` bug — a confirm queued alone (its create lost) would
    /// otherwise permanently fail "not found." X-02: this is now a
    /// one-time proactive sweep (`SessionStore.start()` calls it before
    /// the first drain), not a per-replay reactive fallback — so the test
    /// calls it explicitly, standing in for that startup call, before
    /// `drainAll()`.
    @Test("a legacy-corrupted confirm is repaired by the startup sweep, then drains normally")
    func confirmSelfHealsALostCapture() async throws {
        let sender = StubTransactionSender()
        sender.requireCaptureBeforeConfirm = true
        let (outbox, dbQueue) = try makeOutboxWithQueue(sender: sender)
        let id = UUID()
        try await seedPendingCapture(dbQueue, id: id)

        // Simulates the already-corrupted state: a confirm queued alone,
        // no create ever queued alongside it, exactly what the old
        // `enqueue` produced.
        await outbox.enqueue(
            id: id, kind: .confirmCaptureTransaction,
            payload: ConfirmCaptureTransactionPayload(id: id, expectedVersion: 1), expectedVersion: 1,
            lastError: "transaction not found or not accessible"
        )
        #expect(outbox.pendingCount == 1)

        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(defaults.bool(forKey: "app.keepo.legacyCaptureQueueRepair.done"))

        await outbox.drainAll()

        #expect(sender.captureTransactionCallCount == 1)
        #expect(outbox.pendingCount == 0)
    }

    @Test("the legacy-capture sweep is a no-op — and marks itself done — on a queue with nothing to repair")
    func repairSweepNoopOnHealthyQueue() async throws {
        let sender = StubTransactionSender()
        let outbox = try makeOutbox(sender: sender)
        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))

        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)

        #expect(sender.captureTransactionCallCount == 0)
        #expect(defaults.bool(forKey: "app.keepo.legacyCaptureQueueRepair.done"))

        // Second call is a true no-op — the flag alone short-circuits it,
        // no queue scan, no sender calls.
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(sender.captureTransactionCallCount == 0)
    }

    @Test("a repair that fails to reach the network leaves the flag unset for a later retry")
    func repairSweepRetriesAfterNetworkFailure() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .failure(StubSenderError.network)
        let (outbox, dbQueue) = try makeOutboxWithQueue(sender: sender)
        let id = UUID()
        try await seedPendingCapture(dbQueue, id: id)

        await outbox.enqueue(
            id: id, kind: .confirmCaptureTransaction,
            payload: ConfirmCaptureTransactionPayload(id: id, expectedVersion: 1), expectedVersion: 1,
            lastError: "transaction not found or not accessible"
        )

        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)

        #expect(defaults.bool(forKey: "app.keepo.legacyCaptureQueueRepair.done") == false)
    }
}
