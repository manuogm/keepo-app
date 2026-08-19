import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// Phase L6's optimistic write-through — every `Outbox.submitX` call must
/// leave the local GRDB mirror in a state `LocalMoneyQueries` immediately
/// reads correctly, both when the send fails (queued offline) and when it
/// succeeds outright (online), since `applyLocally` runs unconditionally
/// before either path. Uses an always-failing sender throughout, since the
/// write-through step itself doesn't care about network outcome — it's
/// exercised identically in `OutboxTests`' success cases too.
@Suite("Outbox local write-through")
@MainActor
struct OutboxLocalWriteTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    private func seedAccount(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, kind: String = "regular", currency: String = "EUR",
        openingBalanceE4: Int64 = 0
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, 'Test', ?, ?, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString, kind, currency, openingBalanceE4]
            )
        }
    }

    private func seedCategory(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, kind: String = "expense"
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'Test', 0, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, kind]
            )
        }
    }

    private func seedDefaultCategory(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Other', 1, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedCardMapping(
        _ dbQueue: DatabaseQueue, ownerId: UUID, cardIdentifier: String, accountId: UUID?
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [UUID().uuidString, ownerId.uuidString, cardIdentifier, accountId?.uuidString]
            )
        }
    }

    private func balance(_ dbQueue: DatabaseQueue, accountId: UUID) async throws -> Int64? {
        try await dbQueue.read { database in
            try LocalMoneyQueries.accountBalance(
                database, accountId: accountId.uuidString, asOf: "2026-12-31", now: Date()
            )
        }
    }

    @Test("a created transaction is visible in the local balance immediately, before any sync pull")
    func createTransactionAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let categoryId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)

        let result = await outbox.submitCreateTransaction(
            CreateTransactionPayload(
                id: UUID(), ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: -50000, currency: "EUR", occurredAt: Date()
            )
        )

        #expect(await result.value == .queued)
        #expect(try await balance(dbQueue, accountId: accountId) == -50000)
    }

    @Test("a deleted transaction stops counting toward the balance immediately")
    func deleteTransactionAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        _ = await outbox.submitCreateTransaction(
            CreateTransactionPayload(
                id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: -50000, currency: "EUR", occurredAt: Date()
            )
        )
        #expect(try await balance(dbQueue, accountId: accountId) == -50000)

        _ = await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: transactionId, expectedVersion: 1))

        #expect(try await balance(dbQueue, accountId: accountId) == 0)
    }

    @Test("both legs of a created transfer move both accounts' local balances")
    func createTransferAppliesBothLegsLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId)

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: -30000, toAmountE4: 30000, occurredAt: Date()
            )
        )

        #expect(try await balance(dbQueue, accountId: fromAccountId) == -30000)
        #expect(try await balance(dbQueue, accountId: toAccountId) == 30000)
    }

    @Test("setting a regular account's balance inserts an adjustment for exactly the gap")
    func setRegularBalanceInsertsAdjustment() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId, openingBalanceE4: 100000)

        _ = await outbox.submitSetAccountBalance(
            SetAccountBalancePayload(id: UUID(), accountId: accountId, newBalanceE4: 250000, expectedVersion: 1)
        )

        #expect(try await balance(dbQueue, accountId: accountId) == 250000)
    }

    /// Proves the unification, not just a rename of the old snapshot test:
    /// an investment-kind account's balance-set now goes through the exact
    /// same adjustment-transaction path a regular account's does — no
    /// `balance_snapshots` table exists anymore for it to write into
    /// instead.
    @Test("setting an investment account's balance also files an adjustment transaction, same as regular")
    func setInvestmentBalanceInsertsAdjustment() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId, kind: "investment", openingBalanceE4: 100000)

        _ = await outbox.submitSetAccountBalance(
            SetAccountBalancePayload(id: UUID(), accountId: accountId, newBalanceE4: 500000, expectedVersion: 1)
        )

        #expect(try await balance(dbQueue, accountId: accountId) == 500000)
        let transactionCount = try await dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transactions WHERE account_id = ?",
                              arguments: [accountId.uuidString])
        }
        #expect(transactionCount == 1)
    }

    @Test("B: archiving an account sets archived_at locally before any sync pull")
    func archiveAccountAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)

        _ = await outbox.submitArchiveAccount(
            ArchiveAccountPayload(id: accountId, expectedVersion: 1, archived: true)
        )

        let archivedAt = try await dbQueue.read { database in
            try String.fetchOne(database, sql: "SELECT archived_at FROM accounts WHERE id = ?",
                                 arguments: [accountId.uuidString])
        }
        #expect(archivedAt != nil)
    }

    @Test("a created account is queryable locally before any sync pull")
    func createAccountAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()

        _ = await outbox.submitCreateAccount(
            CreateAccountPayload(
                id: accountId, ownerId: ownerId, kind: .regular, name: "New Account",
                currency: "USD", openingBalanceE4: 10000, icon: "banknote", color: "#8E8E93"
            )
        )

        let account = try await dbQueue.read { database in
            try LocalTableQueries.account(database, id: accountId.uuidString)
        }
        #expect(account?.name == "New Account")
        #expect(try await balance(dbQueue, accountId: accountId) == 10000)
    }

    @Test("a capture on an already-mapped card resolves and writes locally, offline included")
    func captureResolvesAndAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let defaultCategoryId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedDefaultCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId)
        try await seedCardMapping(dbQueue, ownerId: ownerId, cardIdentifier: "card-1", accountId: accountId)

        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: 45000, occurredAt: Date(), externalId: "ext-1", notes: "Paid with card-1 at Blue Bottle"
        )

        let result = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)
        guard case .appliedLocally(let resolution) = result else {
            Issue.record("expected .appliedLocally, got \(result)")
            return
        }
        #expect(resolution.accountName == "Test")
        #expect(resolution.categoryName == "Other")
        #expect(resolution.categoryIsDefault == true)
        #expect(resolution.currency == "EUR")

        let row = try await dbQueue.read { database in
            try Row.fetchOne(
                database, sql: "SELECT status, source, amount_e4, notes FROM transactions WHERE id = ?",
                arguments: [payload.id.uuidString]
            )
        }
        #expect(row?["status"] == "pending")
        #expect(row?["source"] == "capture")
        #expect((row?["amount_e4"] as Int64?) == -45000)
        #expect(row?["notes"] == "Paid with card-1 at Blue Bottle")
    }

    @Test("a capture on an unmapped card still writes locally, with a null account and currency")
    func captureUnmappedStillAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let defaultCategoryId = UUID()
        try await seedDefaultCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId)

        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-unmapped", merchantRaw: "Blue Bottle",
            merchantNormalized: "BLUE BOTTLE", amountE4: 45000, occurredAt: Date(), externalId: "ext-2"
        )

        let result = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)
        guard case .appliedLocally(let resolution) = result else {
            Issue.record("expected .appliedLocally, got \(result)")
            return
        }
        #expect(resolution.accountName == nil)
        #expect(resolution.categoryName == "Other")
        #expect(resolution.categoryIsDefault == true)
        #expect(resolution.currency == nil)

        let row = try await dbQueue.read { database in
            try Row.fetchOne(
                database, sql: "SELECT account_id, currency, card_identifier, status FROM transactions WHERE id = ?",
                arguments: [payload.id.uuidString]
            )
        }
        #expect((row?["account_id"] as String?) == nil)
        #expect((row?["currency"] as String?) == nil)
        #expect(row?["card_identifier"] == "card-unmapped")
        #expect(row?["status"] == "pending")
    }

}

private enum StubError: Error { case alwaysFails }

private final class AlwaysFailingSender: OutboxSending, @unchecked Sendable {
    func createTransaction(_ payload: CreateTransactionPayload) async throws { throw StubError.alwaysFails }
    func createTransfer(_ payload: CreateTransferPayload) async throws { throw StubError.alwaysFails }
    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws {
        throw StubError.alwaysFails
    }
    func createAccount(_ payload: CreateAccountPayload) async throws { throw StubError.alwaysFails }
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool { throw StubError.alwaysFails }
    func createCategory(_ payload: CreateCategoryPayload) async throws { throw StubError.alwaysFails }
    func updateCategory(_ payload: UpdateCategoryPayload) async throws { throw StubError.alwaysFails }
    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws { throw StubError.alwaysFails }
    func unmapCard(_ payload: UnmapCardPayload) async throws { throw StubError.alwaysFails }
    func mapCard(_ payload: MapCardPayload) async throws { throw StubError.alwaysFails }
    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
}
