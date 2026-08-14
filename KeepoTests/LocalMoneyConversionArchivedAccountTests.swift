import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// Regression coverage for the archived-account exclusion added in
/// `20260820100000_archived_account_net_worth_exclusion.sql` and its
/// `LocalMoneyConversion`/`LocalTransactionRow` mirrors — an archived
/// account's balance must stop counting toward net worth, and its
/// transactions must stop appearing in the main list, without either being
/// deleted or losing their link to the account.
@Suite("Archived accounts drop out of net worth and the transaction list")
@MainActor
struct LocalMoneyConversionArchivedAccountTests {
    private func makeDatabase() throws -> DatabaseQueue {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func seedAccount(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, openingBalanceE4: Int64, archived: Bool
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, archived_at, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'ledger', 'checking', 'Test', 'EUR', ?, '2026-01-01', 1, 'banknote', '#8E8E93', ?, 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, openingBalanceE4,
                    archived ? "2026-06-01T00:00:00.000000+00:00" : nil
                ]
            )
        }
    }

    private func seedTransaction(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, accountId: UUID, categoryId: UUID
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                    occurred_at, source, status, version, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, ?, -50000, 'EUR', '2026-07-01T00:00:00.000000+00:00', 'manual', 'confirmed', 1,
                    '2026-07-01T00:00:00.000000+00:00', '2026-07-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, accountId.uuidString, categoryId.uuidString
                ]
            )
        }
    }

    private func seedCurrency(_ dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { database in
            try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
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

    @Test("net worth counts only the active account, not the archived one")
    func netWorthExcludesArchivedAccount() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let activeId = UUID()
        let archivedId = UUID()
        try await seedAccount(dbQueue, id: activeId, ownerId: ownerId, openingBalanceE4: 100_0000, archived: false)
        try await seedAccount(dbQueue, id: archivedId, ownerId: ownerId, openingBalanceE4: 500_0000, archived: true)

        let scope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let netWorth = try await dbQueue.read { database in
            try LocalMoneyConversion.netWorth(database, scope, asOf: "2026-08-13", now: Date())
        }

        #expect(netWorth == 100_0000)
    }

    @Test("the main transaction list drops rows whose account is archived")
    func transactionListExcludesArchivedAccountRows() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let activeId = UUID()
        let archivedId = UUID()
        let categoryId = UUID()
        try await seedCurrency(dbQueue)
        try await seedCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: activeId, ownerId: ownerId, openingBalanceE4: 100_0000, archived: false)
        try await seedAccount(dbQueue, id: archivedId, ownerId: ownerId, openingBalanceE4: 500_0000, archived: true)
        try await seedTransaction(dbQueue, id: UUID(), ownerId: ownerId, accountId: activeId, categoryId: categoryId)
        try await seedTransaction(dbQueue, id: UUID(), ownerId: ownerId, accountId: archivedId, categoryId: categoryId)

        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), baseCurrency: "EUR", ownerId: ownerId.uuidString
            )
        }

        #expect(rows.count == 1)
        #expect(rows.first?.accountId == activeId)

        let stillLinked = try await dbQueue.read { database in
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM transactions WHERE account_id = ?",
                arguments: [archivedId.uuidString]
            )
        }
        #expect(stillLinked == 1)
    }
}
