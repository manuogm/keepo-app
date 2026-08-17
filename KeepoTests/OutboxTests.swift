import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// Exercises the drainer's conflict/failure/collapse logic against a
/// stubbed sender — no network, no real Supabase client — per
/// keepo-v1-master-plan.md Phase 11's explicit Verify requirement.
@Suite("Outbox drainer")
@MainActor
struct OutboxTests {
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

    @Test("a failed send queues the item; a later successful drain removes it")
    func queueThenDrainOnRecovery() async throws {
        let sender = StubTransactionSender()
        sender.createTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: UUID(), accountId: UUID(), categoryId: UUID(),
            amountE4: -100000, currency: "EUR", occurredAt: Date()
        )

        let submitResult = await outbox.submitCreateTransaction(payload).value
        #expect(submitResult == .queued)
        #expect(outbox.pendingCount == 1)

        sender.createTransactionResult = .success(())
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    @Test("a conflict is a delivered write, not a failure — nothing is ever queued for it")
    func conflictNeverQueues() async throws {
        let sender = StubTransactionSender()
        sender.updateTransactionResult = .success(false)
        let outbox = try makeOutbox(sender: sender)
        let payload = UpdateTransactionPayload(
            id: UUID(), expectedVersion: 1, accountId: UUID(), categoryId: UUID(),
            amountE4: -200000, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        let submitResult = await outbox.submitUpdateTransaction(payload).value
        #expect(submitResult == .conflict)
        #expect(outbox.pendingCount == 0)
    }

    @Test("draining a queued item that resolves to conflict still dequeues it")
    func drainTreatsConflictAsDelivered() async throws {
        let sender = StubTransactionSender()
        sender.updateTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = UpdateTransactionPayload(
            id: UUID(), expectedVersion: 1, accountId: UUID(), categoryId: UUID(),
            amountE4: -200000, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        _ = await outbox.submitUpdateTransaction(payload).value
        #expect(outbox.pendingCount == 1)

        // The retry during drain succeeds at the network level but resolves
        // to a version conflict — sync_conflicts already has the audit row
        // server-side; the outbox's only remaining job is to stop retrying.
        sender.updateTransactionResult = .success(false)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    @Test("two offline edits to the same row collapse into one queued item")
    func repeatedEditsCollapse() async throws {
        let sender = StubTransactionSender()
        sender.updateTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let id = UUID()
        let firstEdit = UpdateTransactionPayload(
            id: id, expectedVersion: 1, accountId: UUID(), categoryId: UUID(),
            amountE4: -200000, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )
        let secondEdit = UpdateTransactionPayload(
            id: id, expectedVersion: 1, accountId: UUID(), categoryId: UUID(),
            amountE4: -300000, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        _ = await outbox.submitUpdateTransaction(firstEdit).value
        _ = await outbox.submitUpdateTransaction(secondEdit).value
        #expect(outbox.pendingCount == 1)

        sender.updateTransactionResult = .success(true)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
        // The whole-row payload that actually reached the sender is the
        // LATEST desired state, never a merge of the two edits.
        #expect(sender.lastUpdateTransactionPayload?.amountE4 == -300000)
    }

    @Test("B: archiving an account queues on failure and drains on recovery, same as any other edit")
    func archiveAccountQueuesThenDrains() async throws {
        let sender = StubTransactionSender()
        sender.archiveAccountResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = ArchiveAccountPayload(id: UUID(), expectedVersion: 1, archived: true)

        let submitResult = await outbox.submitArchiveAccount(payload).value
        #expect(submitResult == .queued)
        #expect(outbox.pendingCount == 1)

        sender.archiveAccountResult = .success(true)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    /// Regression: a server-side RPC signature mismatch (an unpushed
    /// migration) failed every capture while the queue reported only a
    /// growing count and no reason — the failure that made a one-line
    /// server fix take five rounds of device testing to find.
    @Test("a queued write exposes why it failed, not just that it is pending")
    func queuedWriteExposesItsFailureReason() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: -45000, occurredAt: Date(), externalId: "ext-1"
        )

        _ = await outbox.submitCaptureTransaction(payload)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.lastError != nil)

        sender.captureTransactionResult = .success(())
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
        #expect(outbox.lastError == nil)
    }

    @Test("a capture that fails to send is queued; draining replays it")
    func captureQueuesThenDrains() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: -45000, occurredAt: Date(), externalId: "ext-1"
        )

        let submitResult = await outbox.submitCaptureTransaction(payload)
        #expect(submitResult == .queued)
        #expect(outbox.pendingCount == 1)

        sender.captureTransactionResult = .success(())
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    @Test("a capture delivered immediately over the RPC-only path is applied, not queued")
    func captureRPCOnlyIsDeliveredNotQueued() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .success(())
        let outbox = try makeOutbox(sender: sender)
        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: -45000, occurredAt: Date(), externalId: "ext-1"
        )

        let submitResult = await outbox.submitCaptureTransaction(payload)
        #expect(submitResult == .applied)
        #expect(outbox.pendingCount == 0)
    }

    @Test("confirming a capture that fails to send is queued; draining replays it")
    func confirmCaptureQueuesThenDrains() async throws {
        let sender = StubTransactionSender()
        sender.confirmCaptureTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = ConfirmCaptureTransactionPayload(id: UUID(), expectedVersion: 1)

        let submitResult = await outbox.submitConfirmCaptureTransaction(payload).value
        #expect(submitResult == .queued)
        #expect(outbox.pendingCount == 1)

        sender.confirmCaptureTransactionResult = .success(true)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    /// Regression: `enqueue` used to collapse-by-id unconditionally, so a
    /// confirm for a capture whose create hadn't reached the server yet
    /// silently discarded that create, permanently. Both must survive as
    /// their own items so a drain replays the create first, then the confirm.
    @Test("a confirm for a not-yet-created capture queues separately, never discarding the create")
    func confirmDuringPendingCaptureDoesNotDiscardTheCreate() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .failure(StubSenderError.network)
        sender.confirmCaptureTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let id = UUID()
        let payload = CaptureTransactionPayload(
            id: id, cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: -45000, occurredAt: Date(), externalId: "ext-1"
        )

        _ = await outbox.submitCaptureTransaction(payload)
        #expect(outbox.pendingCount == 1)

        _ = await outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: id, expectedVersion: 1)
        ).value
        #expect(outbox.pendingCount == 2)

        sender.captureTransactionResult = .success(())
        sender.confirmCaptureTransactionResult = .success(true)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    /// Regression: recovers items already corrupted by the bug above — a
    /// confirm queued alone (its create lost) permanently fails "not
    /// found." If the local mirror still has the capture, one recovery
    /// attempt recreates it, then retries the write that actually failed.
    @Test("a confirm for a capture whose create was lost self-heals by recreating it, then retries")
    func confirmSelfHealsALostCapture() async throws {
        let sender = StubTransactionSender()
        sender.requireCaptureBeforeConfirm = true
        let (outbox, dbQueue) = try makeOutboxWithQueue(sender: sender)
        let id = UUID()

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
        // Simulates the already-corrupted state: a confirm queued alone,
        // no create ever queued alongside it, exactly what the old
        // `enqueue` produced.
        await outbox.enqueue(
            id: id, kind: .confirmCaptureTransaction,
            payload: ConfirmCaptureTransactionPayload(id: id, expectedVersion: 1), expectedVersion: 1,
            lastError: "transaction not found or not accessible"
        )
        #expect(outbox.pendingCount == 1)

        await outbox.drainAll()

        #expect(sender.captureTransactionCallCount == 1)
        #expect(outbox.pendingCount == 0)
    }

    @Test("hasStalePending is threshold-relative, not a bare pending count")
    func stalePendingThreshold() async throws {
        let sender = StubTransactionSender()
        sender.createTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: UUID(), accountId: UUID(), categoryId: UUID(),
            amountE4: -100000, currency: "EUR", occurredAt: Date()
        )

        #expect(outbox.hasStalePending(threshold: 0) == false)
        _ = await outbox.submitCreateTransaction(payload).value
        // A real clock tick between `enqueue`'s `Date()` and this one — on a
        // fast in-memory GRDB write, both can otherwise land in the same
        // clock tick and make a `threshold: 0` comparison flake at the
        // boundary; this isn't testing anything about that boundary itself.
        try await Task.sleep(nanoseconds: 1_000_000)
        #expect(outbox.hasStalePending(threshold: 0) == true)
        #expect(outbox.hasStalePending(threshold: 60 * 60) == false)
    }
}

private enum StubSenderError: Error {
    case network
}

private final class StubTransactionSender: OutboxSending, @unchecked Sendable {
    var createTransactionResult: Result<Void, Error> = .success(())
    var createTransferResult: Result<Void, Error> = .success(())
    var updateTransactionResult: Result<Bool, Error> = .success(true)
    var updateTransferResult: Result<Bool, Error> = .success(true)
    var deleteTransactionResult: Result<Bool, Error> = .success(true)
    var deleteTransferResult: Result<Bool, Error> = .success(true)
    var captureTransactionResult: Result<Void, Error> = .success(())

    private(set) var lastUpdateTransactionPayload: UpdateTransactionPayload?

    func createTransaction(_ payload: CreateTransactionPayload) async throws {
        try createTransactionResult.get()
    }

    func createTransfer(_ payload: CreateTransferPayload) async throws {
        try createTransferResult.get()
    }

    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool {
        lastUpdateTransactionPayload = payload
        return try updateTransactionResult.get()
    }

    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool {
        try updateTransferResult.get()
    }

    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool {
        try deleteTransactionResult.get()
    }

    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool {
        try deleteTransferResult.get()
    }

    private(set) var captureTransactionCallCount = 0
    /// Opt-in for `confirmSelfHealsALostCapture` only — every other test
    /// leaves this `false`, so `confirmCaptureTransaction` behaves exactly
    /// as before (governed purely by `confirmCaptureTransactionResult`).
    var requireCaptureBeforeConfirm = false

    func captureTransaction(_ payload: CaptureTransactionPayload) async throws {
        captureTransactionCallCount += 1
        try captureTransactionResult.get()
    }

    var createAccountResult: Result<Void, Error> = .success(())
    var updateAccountResult: Result<Bool, Error> = .success(true)
    var setAccountBalanceResult: Result<Bool, Error> = .success(true)
    var archiveAccountResult: Result<Bool, Error> = .success(true)
    var createCategoryResult: Result<Void, Error> = .success(())
    var updateCategoryResult: Result<Void, Error> = .success(())

    func createAccount(_ payload: CreateAccountPayload) async throws {
        try createAccountResult.get()
    }

    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool {
        try updateAccountResult.get()
    }

    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool {
        try setAccountBalanceResult.get()
    }

    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool {
        try archiveAccountResult.get()
    }

    func createCategory(_ payload: CreateCategoryPayload) async throws {
        try createCategoryResult.get()
    }

    func updateCategory(_ payload: UpdateCategoryPayload) async throws {
        try updateCategoryResult.get()
    }

    var renameCardMappingResult: Result<Void, Error> = .success(())
    var unmapCardResult: Result<Void, Error> = .success(())
    var mapCardResult: Result<Void, Error> = .success(())
    var confirmCaptureTransactionResult: Result<Bool, Error> = .success(true)

    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws {
        try renameCardMappingResult.get()
    }

    func unmapCard(_ payload: UnmapCardPayload) async throws {
        try unmapCardResult.get()
    }

    func mapCard(_ payload: MapCardPayload) async throws {
        try mapCardResult.get()
    }

    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        if requireCaptureBeforeConfirm, captureTransactionCallCount == 0 {
            throw StubSenderError.network
        }
        return try confirmCaptureTransactionResult.get()
    }
}
