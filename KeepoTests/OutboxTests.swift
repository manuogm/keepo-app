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
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return Outbox(dbQueue: dbQueue, sender: sender)
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

        sender.captureTransactionResult = .success(CaptureResult(mapped: true, accountId: UUID()))
        await outbox.drainAll()
        #expect(outbox.pendingCount == 0)
    }

    @Test("an unmapped-card capture is delivered, not queued — mapped=false is data, not a failure")
    func captureUnmappedIsDeliveredNotQueued() async throws {
        let sender = StubTransactionSender()
        sender.captureTransactionResult = .success(CaptureResult(mapped: false, accountId: nil))
        let outbox = try makeOutbox(sender: sender)
        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: -45000, occurredAt: Date(), externalId: "ext-1"
        )

        let submitResult = await outbox.submitCaptureTransaction(payload)
        #expect(submitResult == .applied(mapped: false))
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
    var captureTransactionResult: Result<CaptureResult, Error> = .success(CaptureResult(mapped: true, accountId: nil))

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

    func captureTransaction(_ payload: CaptureTransactionPayload) async throws -> CaptureResult {
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
}
