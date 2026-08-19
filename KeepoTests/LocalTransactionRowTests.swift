import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `LocalTransactionRow` builds `PublicSchema.TransactionsWithDetailsSelect`
/// off the local mirror via a JSON round-trip (Phase L6, since that type has
/// no public initializer reachable from the App target) — worth pinning
/// that the round-trip itself is lossless for every field type it carries
/// (UUID, enum, optional String, Int64, Bool), and that `kind`/
/// `amount_base_e4`/`has_missing_rate` are derived correctly.
@Suite("LocalTransactionRow")
struct LocalTransactionRowTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func seed(
        _ database: Database, ownerId: String, seedCurrency: Bool = true
    ) throws -> (accountId: String, categoryId: String) {
        let accountId = UUID().uuidString
        let categoryId = UUID().uuidString
        try database.execute(
            sql: """
            INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, 'regular', 'Checking', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [accountId, ownerId, ownerId]
        )
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, 'expense', 'Groceries', 0, 'cart', '#000', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [categoryId, ownerId]
        )
        if seedCurrency {
            try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
        }
        return (accountId, categoryId)
    }

    // swiftlint:disable:next function_parameter_count
    private func insertTransaction(
        _ database: Database, id: String, ownerId: String, accountId: String, categoryId: String?, amountE4: Int64
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                occurred_at, source, status, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, ?, ?, 'EUR', '2026-06-15T12:00:00.000000+00:00', 'manual', 'confirmed', 1,
                '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1)
            """,
            arguments: [id, ownerId, ownerId, accountId, categoryId, amountE4]
        )
    }

    @Test("an expense transaction round-trips with the correct kind and same-currency conversion")
    func expenseRoundTrips() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let transactionId = UUID().uuidString
        let (accountId, categoryId) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        try await dbQueue.write { database in
            try insertTransaction(
                database, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: -50000
            )
        }

        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), baseCurrency: "EUR", ownerId: ownerId
            )
        }

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == "expense")
        #expect(row.accountName == "Checking")
        #expect(row.categoryName == "Groceries")
        #expect(row.amountE4 == -50000)
        #expect(row.amountBaseE4 == -50000)
        #expect(row.hasMissingRate == false)
        #expect(row.transactionId?.uuidString.lowercased() == transactionId.lowercased())
    }

    @Test("a transfer leg's kind is 'transfer', overriding the amount sign")
    func transferKindOverridesSign() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let transactionId = UUID().uuidString
        let groupId = UUID().uuidString
        let (accountId, _) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                    occurred_at, transfer_group_id, source, status, version, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, NULL, 10000, 'EUR', '2026-06-15T12:00:00.000000+00:00', ?, 'manual', 'confirmed',
                    1, '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1)
                """,
                arguments: [transactionId, ownerId, ownerId, accountId, groupId]
            )
        }

        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), baseCurrency: "EUR", ownerId: ownerId
            )
        }

        #expect(rows.first?.kind == "transfer")
    }

    @Test("a missing FX rate renders amount_base_e4 as nil and has_missing_rate as true")
    func missingRatePropagates() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let transactionId = UUID().uuidString
        let (accountId, categoryId) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        try await dbQueue.write { database in
            try insertTransaction(
                database, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: -50000
            )
        }

        // Base currency GBP has no fx_rates row and isn't the seeded EUR.
        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), baseCurrency: "GBP", ownerId: ownerId
            )
        }

        #expect(rows.first?.amountBaseE4 == nil)
        #expect(rows.first?.hasMissingRate == true)
    }

    @Test("fetchOne finds a transaction by id and returns nil for an unknown id")
    func fetchOneById() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let transactionId = UUID().uuidString
        let (accountId, categoryId) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        try await dbQueue.write { database in
            try insertTransaction(
                database, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: 20000
            )
        }

        let found = try await dbQueue.read { database in
            try LocalTransactionRow.fetchOne(database, id: transactionId, baseCurrency: "EUR", ownerId: ownerId)
        }
        let missing = try await dbQueue.read { database in
            try LocalTransactionRow.fetchOne(database, id: UUID().uuidString, baseCurrency: "EUR", ownerId: ownerId)
        }

        #expect(found?.kind == "income")
        #expect(missing == nil)
    }

    @Test("a transaction whose account belongs to a different owner is excluded, not just its account")
    func excludesTransactionsForAnotherOwnersAccount() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let staleOwnerId = UUID().uuidString
        let transactionId = UUID().uuidString
        let staleTransactionId = UUID().uuidString
        let (accountId, categoryId) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        let (staleAccountId, staleCategoryId) = try await dbQueue.write { database in
            try seed(database, ownerId: staleOwnerId, seedCurrency: false)
        }
        try await dbQueue.write { database in
            try insertTransaction(
                database, id: transactionId, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                amountE4: -50000
            )
            try insertTransaction(
                database, id: staleTransactionId, ownerId: staleOwnerId, accountId: staleAccountId,
                categoryId: staleCategoryId, amountE4: -10000
            )
        }

        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), baseCurrency: "EUR", ownerId: ownerId
            )
        }
        let fetchedStale = try await dbQueue.read { database in
            try LocalTransactionRow.fetchOne(
                database, id: staleTransactionId, baseCurrency: "EUR", ownerId: ownerId
            )
        }

        #expect(rows.count == 1)
        #expect(rows.first?.transactionId?.uuidString.lowercased() == transactionId.lowercased())
        #expect(fetchedStale == nil)
    }

    @Test("fetchByTransferGroup returns both legs of a transfer")
    func fetchByTransferGroupReturnsBothLegs() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let groupId = UUID().uuidString
        let (fromAccountId, _) = try await dbQueue.write { database in try seed(database, ownerId: ownerId) }
        let toAccountId = UUID().uuidString
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Savings', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [toAccountId, ownerId, ownerId]
            )
            for (id, accountId, amount) in [
                (UUID().uuidString, fromAccountId, Int64(-40000)), (UUID().uuidString, toAccountId, Int64(40000))
            ] {
                try database.execute(
                    sql: """
                    INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                        occurred_at, transfer_group_id, source, status, version, created_at, updated_at, sync_seq)
                    VALUES (?, ?, ?, ?, NULL, ?, 'EUR', '2026-06-15T12:00:00.000000+00:00', ?, 'manual', 'confirmed',
                        1, '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1)
                    """,
                    arguments: [id, ownerId, ownerId, accountId, amount, groupId]
                )
            }
        }

        let legs = try await dbQueue.read { database in
            try LocalTransactionRow.fetchByTransferGroup(
                database, transferGroupId: groupId, baseCurrency: "EUR", ownerId: ownerId
            )
        }

        #expect(legs.count == 2)
        #expect(legs.allSatisfy { $0.kind == "transfer" })
        #expect(Set(legs.map { $0.amountE4 }) == [-40000, 40000])
    }
}
