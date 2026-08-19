import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `Outbox.submitConfirmCaptureTransaction`'s local write-through — split
/// into its own file following the same precedent as
/// `ReviewCaptureLocalWriteTests.swift` and `CardMappingLocalWriteTests.swift`.
@Suite("Confirm-capture local write-through")
@MainActor
struct ConfirmCaptureLocalWriteTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    private func seedAccount(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Test', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedCategory(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Test', 0, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedPendingCapture(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, accountId: UUID?, categoryId: UUID
    ) async throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
                    merchant_raw, merchant_normalized, source, status, external_id, version,
                    created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, -1200, 'EUR', ?, 'Corner Cafe', 'CORNER CAFE', 'capture', 'pending',
                    'ext-1', 1, ?, ?, 0)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, accountId?.uuidString,
                    categoryId.uuidString, now, now, now
                ]
            )
        }
    }

    /// Mirrors pgTAP's "a plain swipe-confirm re-teaches merchant_category_map"
    /// case (12_capture.sql) — same upsert `review_capture_transaction`
    /// already does, just on the no-edit confirm path (C-01).
    @Test("confirming a resolved capture flips status and re-teaches the merchant mapping")
    func confirmCaptureTransactionAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId
        )

        let result = await outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: transactionId, expectedVersion: 1)
        )
        #expect(await result.value == .queued)

        let status = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT status FROM transactions WHERE id = ?", arguments: [transactionId.uuidString]
            )
        }
        #expect(status == "confirmed")

        let mappedCategory = try await dbQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT category_id FROM merchant_category_map WHERE owner_id = ? AND merchant_pattern = ?",
                arguments: [ownerId.uuidString, "CORNER CAFE"]
            )
        }
        #expect(mappedCategory == categoryId.uuidString)
    }

    /// C-05's client-side guard, mirroring the server's own `account_id IS
    /// NOT NULL` check in `confirm_capture_transaction` — an unresolved
    /// capture must not reach "confirmed" in either mirror.
    @Test("confirming an unresolved capture (no account) is a no-op locally")
    func confirmCaptureTransactionRefusesUnresolvedCapture() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: nil, categoryId: categoryId
        )

        _ = await outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: transactionId, expectedVersion: 1)
        )

        let status = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT status FROM transactions WHERE id = ?", arguments: [transactionId.uuidString]
            )
        }
        #expect(status == "pending")
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
