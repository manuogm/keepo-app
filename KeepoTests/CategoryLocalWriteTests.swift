import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// B: `CategoryLocalWrite` is the local echo `CategoryFormView` applies
/// after `deleteWithReassign` succeeds online — reassigns local
/// transactions off the deleted category, then soft-deletes it, mirroring
/// the server's own two-statement effect exactly.
@Suite("Category local write-through")
struct CategoryLocalWriteTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    // swiftlint:disable:next function_parameter_count
    private func seed(
        _ database: Database, ownerId: UUID, categoryId: UUID, otherId: UUID, accountId: UUID, transactionId: UUID
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, 'expense', 'Gift', 0, 'gift', '#000', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [categoryId.uuidString, ownerId.uuidString]
        )
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, 'expense', 'Other', 1, 'tag.fill', '#8E8E93', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [otherId.uuidString, ownerId.uuidString]
        )
        try database.execute(
            sql: """
            INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, 'ledger', 'checking', 'Checking', 'EUR', 0, '2026-01-01', 1, 1, 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [accountId.uuidString, ownerId.uuidString, ownerId.uuidString]
        )
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                occurred_at, source, status, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, ?, -10000, 'EUR', '2026-06-15T12:00:00.000000+00:00', 'manual', 'confirmed', 1,
                '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1)
            """,
            arguments: [
                transactionId.uuidString, ownerId.uuidString, ownerId.uuidString, accountId.uuidString,
                categoryId.uuidString
            ]
        )
    }

    @Test("deleting a category reassigns its transactions to the owner's default and soft-deletes it")
    func deleteReassignsAndSoftDeletes() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let otherId = UUID()
        let accountId = UUID()
        let transactionId = UUID()

        try await dbQueue.write { database in
            try seed(
                database, ownerId: ownerId, categoryId: categoryId, otherId: otherId, accountId: accountId,
                transactionId: transactionId
            )
        }

        try await dbQueue.write { database in
            try CategoryLocalWrite.deleteAndReassignToOther(
                categoryId: categoryId, kind: .expense, ownerId: ownerId, in: database
            )
        }

        let (reassignedTo, categoryDeletedAt) = try await dbQueue.read { database in
            (
                try String.fetchOne(
                    database, sql: "SELECT category_id FROM transactions WHERE id = ?",
                    arguments: [transactionId.uuidString]
                ),
                try String.fetchOne(
                    database, sql: "SELECT deleted_at FROM categories WHERE id = ?",
                    arguments: [categoryId.uuidString]
                )
            )
        }

        #expect(reassignedTo?.lowercased() == otherId.uuidString.lowercased())
        #expect(categoryDeletedAt != nil)
    }
}
