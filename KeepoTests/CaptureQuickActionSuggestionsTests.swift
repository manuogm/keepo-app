import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The ranking/duplicate reads behind the capture notification's
/// quick-action buttons — same GRDB in-memory fixture pattern as
/// `ReviewCaptureLocalWriteTests`.
@Suite("Capture quick-action suggestions")
struct CaptureQuickActionSuggestionsTests {
    private func makeDatabase() throws -> DatabaseQueue {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func seedAccount(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, name: String = "Test", kind: String = "regular"
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, ?, 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString, kind, name]
            )
        }
    }

    private func seedCardMapping(
        _ dbQueue: DatabaseQueue, ownerId: UUID, cardIdentifier: String, accountId: UUID
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (
                    id, owner_id, card_identifier, account_id, source, created_at, updated_at, sync_seq
                ) VALUES (
                    ?, ?, ?, ?, 'manual', '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1
                )
                """,
                arguments: [UUID().uuidString, ownerId.uuidString, cardIdentifier, accountId.uuidString]
            )
        }
    }

    private func seedCategory(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, name: String = "Test") async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', ?, 0, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, name]
            )
        }
    }

    @discardableResult
    private func seedTransaction(
        _ dbQueue: DatabaseQueue, ownerId: UUID, accountId: UUID?, merchantNormalized: String, cardIdentifier: String?,
        categoryId: UUID? = nil, amountE4: Int64 = -1000, occurredAt: Date = Date()
    ) async throws -> UUID {
        let id = UUID()
        let now = PostgresDate.sqliteTimestampBoundaryString(occurredAt)
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
                    merchant_normalized, card_identifier, source, status, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, ?, 'EUR', ?, ?, ?, 'capture', 'confirmed', 1, ?, ?, 0)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, accountId?.uuidString,
                    categoryId?.uuidString, amountE4, now, merchantNormalized, cardIdentifier, now, now
                ]
            )
        }
        return id
    }

    @Test("top categories for merchant — ranked by frequency, excluded id dropped")
    func topCategoriesForMerchantRanksByFrequency() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let groceries = UUID()
        let dining = UUID()
        let transport = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: groceries, ownerId: ownerId, name: "Groceries")
        try await seedCategory(dbQueue, id: dining, ownerId: ownerId, name: "Dining")
        try await seedCategory(dbQueue, id: transport, ownerId: ownerId, name: "Transport")
        // Groceries used twice, dining once, transport once (for a different merchant).
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "TRADER JOES",
            cardIdentifier: "c1", categoryId: groceries
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "TRADER JOES",
            cardIdentifier: "c1", categoryId: groceries
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "TRADER JOES",
            cardIdentifier: "c1", categoryId: dining
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "UBER",
            cardIdentifier: "c1", categoryId: transport
        )

        let results = try await dbQueue.read { database in
            try CaptureQuickActionSuggestions.topCategoriesForMerchant(
                database, ownerId: ownerId.uuidString, merchantNormalized: "TRADER JOES", excluding: nil, limit: 3
            )
        }
        #expect(results.map(\.name) == ["Groceries", "Dining"])

        let excludingGroceries = try await dbQueue.read { database in
            try CaptureQuickActionSuggestions.topCategoriesForMerchant(
                database, ownerId: ownerId.uuidString, merchantNormalized: "TRADER JOES",
                excluding: groceries.uuidString, limit: 3
            )
        }
        #expect(excludingGroceries.map(\.name) == ["Dining"])
    }

    @Test("top categories for account — falls back to the account's own history")
    func topCategoriesForAccountRanksByFrequency() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let otherAccountId = UUID()
        let coffee = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: otherAccountId, ownerId: ownerId)
        try await seedCategory(dbQueue, id: coffee, ownerId: ownerId, name: "Coffee")
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "BLUE BOTTLE",
            cardIdentifier: "c1", categoryId: coffee
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: otherAccountId, merchantNormalized: "BLUE BOTTLE",
            cardIdentifier: "c2", categoryId: coffee
        )

        let results = try await dbQueue.read { database in
            try CaptureQuickActionSuggestions.topCategoriesForAccount(
                database, ownerId: ownerId.uuidString, accountId: accountId.uuidString, excluding: nil, limit: 3
            )
        }
        #expect(results.map(\.name) == ["Coffee"])
    }

    @Test("top unmapped accounts — excludes accounts with a live card mapping, ranks the rest by usage")
    func topUnmappedAccountsExcludesMapped() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let mapped = UUID()
        let unmappedBusy = UUID()
        let unmappedQuiet = UUID()
        let investment = UUID()
        try await seedAccount(dbQueue, id: mapped, ownerId: ownerId, name: "Mapped")
        try await seedAccount(dbQueue, id: unmappedBusy, ownerId: ownerId, name: "Busy")
        try await seedAccount(dbQueue, id: unmappedQuiet, ownerId: ownerId, name: "Quiet")
        try await seedAccount(dbQueue, id: investment, ownerId: ownerId, name: "Brokerage", kind: "investment")
        try await seedCardMapping(dbQueue, ownerId: ownerId, cardIdentifier: "mapped-card", accountId: mapped)
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: unmappedBusy, merchantNormalized: "M", cardIdentifier: nil
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: unmappedBusy, merchantNormalized: "M", cardIdentifier: nil
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: unmappedQuiet, merchantNormalized: "M", cardIdentifier: nil
        )
        try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: investment, merchantNormalized: "M", cardIdentifier: nil
        )

        let results = try await dbQueue.read { database in
            try CaptureQuickActionSuggestions.topUnmappedAccounts(database, ownerId: ownerId.uuidString, limit: 3)
        }
        #expect(results.map(\.name) == ["Busy", "Quiet"])
    }

    @Test("possible duplicate — same card, merchant, and amount within the time window")
    func hasPossibleDuplicateWithinWindow() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        let baseTime = Date()
        let firstId = try await seedTransaction(
            dbQueue, ownerId: ownerId, accountId: accountId, merchantNormalized: "COSTCO", cardIdentifier: "card-1",
            amountE4: -50000, occurredAt: baseTime
        )
        let newId = UUID()

        func isDuplicate(amountE4: Int64, occurredAt: Date, excluding: UUID) async throws -> Bool {
            try await dbQueue.read { database in
                try CaptureQuickActionSuggestions.hasPossibleDuplicate(
                    database, ownerId: ownerId.uuidString,
                    candidate: .init(
                        cardIdentifier: "card-1", merchantNormalized: "COSTCO", amountE4: amountE4,
                        occurredAt: occurredAt
                    ),
                    excluding: excluding.uuidString
                )
            }
        }

        let withinWindow = try await isDuplicate(
            amountE4: -50000, occurredAt: baseTime.addingTimeInterval(10 * 60), excluding: newId
        )
        #expect(withinWindow)
        let outsideWindow = try await isDuplicate(
            amountE4: -50000, occurredAt: baseTime.addingTimeInterval(30 * 60), excluding: newId
        )
        #expect(!outsideWindow)
        let differentAmount = try await isDuplicate(
            amountE4: -1234, occurredAt: baseTime.addingTimeInterval(60), excluding: newId
        )
        #expect(!differentAmount)
        // Excluding the row's own id (a re-run of the same write) never
        // flags itself as its own duplicate.
        #expect(try await !isDuplicate(amountE4: -50000, occurredAt: baseTime, excluding: firstId))
    }
}
