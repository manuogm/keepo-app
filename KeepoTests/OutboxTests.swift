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
