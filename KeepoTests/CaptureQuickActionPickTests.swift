import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The notification quick-action pick path end to end: tapping a suggested
/// account or category must edit the transaction, confirm it, and (for an
/// unmapped card) link the card — the three things device testing found
/// silently not happening.
@Suite("Capture quick-action picks")
@MainActor
struct CaptureQuickActionPickTests {
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
                VALUES (?, ?, ?, 'regular', 'Revolut', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedCategory(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, isDefault: Bool = false) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Groceries', ?, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, isDefault]
            )
        }
    }

    /// Mirrors exactly what `CaptureLocalWrite.resolveAndWrite` produces:
    /// `status = 'pending'`, a `card_identifier`, and — for the unmapped-card
    /// case — a null `account_id`/`currency`.
    private func seedPendingCapture(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, accountId: UUID?, categoryId: UUID
    ) async throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
                    merchant_raw, merchant_normalized, card_identifier, source, status, external_id, version,
                    created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, -45000, ?, ?, 'Blue Bottle', 'BLUE BOTTLE', 'card-1', 'capture',
                    'pending', 'ext-1', 1, ?, ?, 0)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, accountId?.uuidString,
                    categoryId.uuidString, accountId == nil ? nil : "EUR", now, now, now
                ]
            )
        }
    }

    private func transactionRow(_ dbQueue: DatabaseQueue, id: UUID) async throws -> Row? {
        try await dbQueue.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT account_id, category_id, currency, status FROM transactions WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    @Test("picking an account fills it in, confirms the row, and links the card")
    func accountPickApplies() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        // Unmapped card: no account, no currency yet.
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: nil, categoryId: categoryId
        )

        await CaptureQuickActionHandler.review(
            transactionId: transactionId, kind: "account", pickedId: accountId, outbox: outbox, dbQueue: dbQueue
        )

        let row = try await transactionRow(dbQueue, id: transactionId)
        #expect(row?["account_id"] == accountId.uuidString)
        #expect(row?["currency"] == "EUR")
        #expect(row?["status"] == "confirmed")

        let mappedAccount = try await dbQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT account_id FROM card_mappings WHERE owner_id = ? AND card_identifier = ?",
                arguments: [ownerId.uuidString, "card-1"]
            )
        }
        #expect(mappedAccount == accountId.uuidString)
    }

    /// Covers the layer above `review`: `handle` parsing a real notification
    /// `Request` (the `capture.pick.N` identifier plus the `pickKind`/
    /// `pickIds` that travelled in `userInfo`) and routing it. Uses slot 1,
    /// not 0, so an off-by-one in the index→id lookup can't pass.
    @Test("handle routes a pick action to the right suggested id")
    func handleRoutesPickAction() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let otherAccountId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: otherAccountId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: nil, categoryId: categoryId
        )

        let request = CaptureQuickActionHandler.Request(
            actionIdentifier: CaptureQuickActions.pickActionId(1),
            categoryIdentifier: "capture.\(transactionId.uuidString)",
            transactionId: transactionId, pickKind: "account",
            pickIds: [otherAccountId.uuidString, accountId.uuidString]
        )
        await CaptureQuickActionHandler.handle(request, outbox: outbox, dbQueue: dbQueue)

        let row = try await transactionRow(dbQueue, id: transactionId)
        #expect(row?["account_id"] == accountId.uuidString)
        #expect(row?["status"] == "confirmed")
    }

    @Test("picking a category applies it and confirms the row")
    func categoryPickApplies() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let defaultCategoryId = UUID()
        let pickedCategoryId = UUID()
        let transactionId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId, isDefault: true)
        try await seedCategory(dbQueue, id: pickedCategoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: defaultCategoryId
        )

        await CaptureQuickActionHandler.review(
            transactionId: transactionId, kind: "category", pickedId: pickedCategoryId, outbox: outbox,
            dbQueue: dbQueue
        )

        let row = try await transactionRow(dbQueue, id: transactionId)
        #expect(row?["category_id"] == pickedCategoryId.uuidString)
        #expect(row?["status"] == "confirmed")
    }
}
