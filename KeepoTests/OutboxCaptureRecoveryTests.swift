import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `Outbox.repairLegacyCaptureQueueIfNeeded` (X-02, reopened by capture
/// quick actions — see that function's own header) — split out of
/// `OutboxTests.swift` purely to keep that file under the project's
/// type-body-length lint threshold, same precedent as
/// `ReviewCaptureLocalWriteTests.swift`.
@Suite("Outbox capture-repair sweep")
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
                    "ext-\(id.uuidString)", PostgresDate.sqliteTimestampBoundaryString(Date()),
                    PostgresDate.sqliteTimestampBoundaryString(Date())
                ]
            )
        }
    }

    /// Regression: a confirm/review/delete queued alone, its create lost —
    /// whether by the closed pre-fix `enqueue` bug or a quick action racing
    /// a still-queued create — otherwise fails "not found" forever. The
    /// sweep resends the create so the next drain succeeds normally.
    @Test("a capture-dependent write with no matching create is repaired, then drains normally")
    func confirmSelfHealsALostCapture() async throws {
        let sender = StubTransactionSender()
        sender.requireCaptureBeforeConfirm = true
        let (outbox, dbQueue) = try makeOutboxWithQueue(sender: sender)
        let id = UUID()
        try await seedPendingCapture(dbQueue, id: id)

        // Simulates the corrupted state: a confirm queued alone, no create
        // ever queued alongside it.
        await outbox.enqueue(
            id: id, kind: .confirmCaptureTransaction,
            payload: ConfirmCaptureTransactionPayload(id: id, expectedVersion: 1), expectedVersion: 1,
            lastError: "transaction not found or not accessible"
        )
        #expect(outbox.pendingCount == 1)

        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(defaults.stringArray(forKey: "app.keepo.legacyCaptureQueueRepair.repairedIds") == [id.uuidString])

        await outbox.drainAll()

        #expect(sender.captureTransactionCallCount == 1)
        #expect(outbox.pendingCount == 0)
    }

    @Test("the sweep is a no-op on a queue with nothing to repair")
    func repairSweepNoopOnHealthyQueue() async throws {
        let sender = StubTransactionSender()
        let outbox = try makeOutbox(sender: sender)
        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))

        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)

        #expect(sender.captureTransactionCallCount == 0)
        #expect(defaults.stringArray(forKey: "app.keepo.legacyCaptureQueueRepair.repairedIds") == nil)
    }

    @Test("a repair that fails to reach the network is retried on a later call")
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

        #expect((defaults.stringArray(forKey: "app.keepo.legacyCaptureQueueRepair.repairedIds") ?? []).isEmpty)

        // The network recovers — a later call (a later app launch, or the
        // next quick action) picks the same id back up rather than having
        // given up on it after one transient failure.
        sender.captureTransactionResult = .success(())
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(sender.captureTransactionCallCount == 2)
        #expect(defaults.stringArray(forKey: "app.keepo.legacyCaptureQueueRepair.repairedIds") == [id.uuidString])
    }

    /// The gate this whole file exists to prove: a row repaired once must
    /// never be resent again, however many times the sweep runs — this is
    /// what keeps a quick action calling it before every single write from
    /// burning a `capture_transaction` call (and its rate-limit budget) on
    /// an already-healthy queue, item after item.
    @Test("a repaired id is never resent, no matter how many later calls the sweep gets")
    func repairedIdIsNeverResent() async throws {
        let sender = StubTransactionSender()
        sender.requireCaptureBeforeConfirm = true
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
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)

        #expect(sender.captureTransactionCallCount == 1)
    }

    /// A second, genuinely new corruption — the exact case the old
    /// single-flag gate could never recover from once it had already
    /// tripped `done` on an earlier, unrelated queue.
    @Test("a new corrupted id is still repaired after an earlier one already was")
    func newCorruptionIsRepairedAfterAnEarlierOne() async throws {
        let sender = StubTransactionSender()
        sender.requireCaptureBeforeConfirm = true
        let (outbox, dbQueue) = try makeOutboxWithQueue(sender: sender)
        let firstId = UUID()
        try await seedPendingCapture(dbQueue, id: firstId)
        await outbox.enqueue(
            id: firstId, kind: .confirmCaptureTransaction,
            payload: ConfirmCaptureTransactionPayload(id: firstId, expectedVersion: 1), expectedVersion: 1,
            lastError: "transaction not found or not accessible"
        )
        let defaults = try #require(UserDefaults(suiteName: "OutboxTests-\(UUID().uuidString)"))
        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(sender.captureTransactionCallCount == 1)

        // A second, unrelated row goes bad later — e.g. a quick action
        // racing a still-queued create on this device's next capture.
        let secondId = UUID()
        try await seedPendingCapture(dbQueue, id: secondId)
        await outbox.enqueue(
            id: secondId, kind: .reviewCapture,
            payload: ReviewCaptureTransactionPayload(
                id: secondId, expectedVersion: 1, accountId: UUID(), categoryId: UUID(), amountE4: -45000,
                currency: "EUR", occurredAt: Date(), merchantRaw: "Blue Bottle"
            ),
            expectedVersion: 1, lastError: "transaction not found or not accessible"
        )

        await outbox.repairLegacyCaptureQueueIfNeeded(defaults: defaults)
        #expect(sender.captureTransactionCallCount == 2)
    }
}
