import Foundation
import SwiftData
import Testing
@testable import Keepo

/// Exercises the drainer's conflict/failure/collapse logic against a
/// stubbed sender — no network, no real Supabase client — per
/// keepo-v1-master-plan.md Phase 11's explicit Verify requirement.
@Suite("Outbox drainer")
@MainActor
struct OutboxTests {
    private func makeOutbox(sender: StubTransactionSender) throws -> Outbox {
        let schema = Schema(versionedSchema: OfflineSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema, migrationPlan: OfflineMigrationPlan.self, configurations: configuration
        )
        return Outbox(context: ModelContext(container), sender: sender)
    }

    @Test("a failed send queues the item; a later successful drain removes it")
    func queueThenDrainOnRecovery() async throws {
        let sender = StubTransactionSender()
        sender.createTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: UUID(), accountId: UUID(), categoryId: UUID(),
            amount: -10, currency: "EUR", occurredAt: Date()
        )

        let submitResult = await outbox.submitCreateTransaction(payload)
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
            amount: -20, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        let submitResult = await outbox.submitUpdateTransaction(payload)
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
            amount: -20, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        _ = await outbox.submitUpdateTransaction(payload)
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
            amount: -20, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )
        let secondEdit = UpdateTransactionPayload(
            id: id, expectedVersion: 1, accountId: UUID(), categoryId: UUID(),
            amount: -30, currency: "EUR", occurredAt: Date(), merchantRaw: nil
        )

        _ = await outbox.submitUpdateTransaction(firstEdit)
        _ = await outbox.submitUpdateTransaction(secondEdit)
        #expect(outbox.pendingCount == 1)

        sender.updateTransactionResult = .success(true)
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
        // The whole-row payload that actually reached the sender is the
        // LATEST desired state, never a merge of the two edits.
        #expect(sender.lastUpdateTransactionPayload?.amount == -30)
    }

    @Test("hasStalePending is threshold-relative, not a bare pending count")
    func stalePendingThreshold() async throws {
        let sender = StubTransactionSender()
        sender.createTransactionResult = .failure(StubSenderError.network)
        let outbox = try makeOutbox(sender: sender)
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: UUID(), accountId: UUID(), categoryId: UUID(),
            amount: -10, currency: "EUR", occurredAt: Date()
        )

        #expect(outbox.hasStalePending(threshold: 0) == false)
        _ = await outbox.submitCreateTransaction(payload)
        #expect(outbox.hasStalePending(threshold: 0) == true)
        #expect(outbox.hasStalePending(threshold: 60 * 60) == false)
    }
}

private enum StubSenderError: Error {
    case network
}

private final class StubTransactionSender: TransactionOutboxSending, @unchecked Sendable {
    var createTransactionResult: Result<Void, Error> = .success(())
    var createTransferResult: Result<Void, Error> = .success(())
    var updateTransactionResult: Result<Bool, Error> = .success(true)
    var updateTransferResult: Result<Bool, Error> = .success(true)
    var deleteTransactionResult: Result<Bool, Error> = .success(true)
    var deleteTransferResult: Result<Bool, Error> = .success(true)

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
}
