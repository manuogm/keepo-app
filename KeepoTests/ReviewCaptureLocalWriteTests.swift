import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `Outbox.submitReviewCaptureTransaction`'s local write-through — split
/// out of `OutboxLocalWriteTests.swift` purely to keep that file under the
/// project's type-body-length lint threshold, same precedent as
/// `CardMappingLocalWriteTests.swift`.
@Suite("Review-capture local write-through")
@MainActor
struct ReviewCaptureLocalWriteTests {
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
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, accountId: UUID, categoryId: UUID
    ) async throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
                    merchant_raw, merchant_normalized, source, status, external_id, version,
                    created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, -45000, 'EUR', ?, 'Blue Bottle', 'BLUE BOTTLE', 'capture', 'pending',
                    'ext-1', 1, ?, ?, 0)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, accountId.uuidString,
                    categoryId.uuidString, now, now, now
                ]
            )
        }
    }

    /// The single-write replacement for what used to be
    /// `submitUpdateTransaction` + `submitConfirmCaptureTransaction` as two
    /// separate writes (migration 20260825100000,
    /// `ReviewCaptureTransactionPayload`'s own header). Proves the edit,
    /// the status flip, and the merchant re-teach all land in the one
    /// optimistic local write-through, not three separately-timed steps
    /// that could observe an in-between state.
    @Test("reviewing a capture applies the edit and confirms it in one local write, re-teaching the merchant mapping")
    func reviewCaptureTransactionAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let originalCategoryId = UUID()
        let newCategoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: originalCategoryId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: newCategoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: originalCategoryId
        )

        let payload = ReviewCaptureTransactionPayload(
            id: transactionId, expectedVersion: 1, accountId: accountId, categoryId: newCategoryId,
            amountE4: -52500, currency: "EUR", occurredAt: Date(), merchantRaw: "Blue Bottle Coffee Co."
        )
        let result = await outbox.submitReviewCaptureTransaction(payload)
        #expect(await result.value == .queued)

        let row = try await dbQueue.read { database in
            try Row.fetchOne(
                database,
                sql: """
                SELECT status, category_id, amount_e4, merchant_raw, version FROM transactions WHERE id = ?
                """,
                arguments: [transactionId.uuidString]
            )
        }
        #expect(row?["status"] == "confirmed")
        #expect(row?["category_id"] == newCategoryId.uuidString)
        #expect((row?["amount_e4"] as Int64?) == -52500)
        #expect(row?["merchant_raw"] == "Blue Bottle Coffee Co.")
        #expect((row?["version"] as Int?) == 2)

        let mappedCategory = try await dbQueue.read { database in
            try String.fetchOne(
                database,
                sql: """
                SELECT category_id FROM merchant_category_map WHERE owner_id = ? AND merchant_pattern = ?
                """,
                arguments: [ownerId.uuidString, "BLUE BOTTLE"]
            )
        }
        #expect(mappedCategory == newCategoryId.uuidString)
    }
}
