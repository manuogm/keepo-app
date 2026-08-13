import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `LocalAccountRow.fetchAll` backs `AccountsListView` (Phase L6) — the
/// three things worth pinning: an account shared into the viewer's
/// household shows up even though `owner_id` isn't theirs, `is_shared`
/// reflects that, and a missing FX rate renders as `nil` (money rule 5),
/// never a silently-wrong `0`.
@Suite("LocalAccountRow.fetchAll")
struct LocalAccountRowTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func insertAccount(
        _ database: Database, id: String, ownerId: String, currency: String, openingBalanceE4: Int64
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, 'ledger', 'checking', 'Test', ?, ?, '2026-01-01', 1, 1, 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [id, ownerId, ownerId, currency, openingBalanceE4]
        )
    }

    @Test("an account shared into the viewer's household is visible and marked shared")
    func sharedAccountVisible() async throws {
        let dbQueue = try makeDatabase()
        let viewerId = UUID().uuidString
        let partnerId = UUID().uuidString
        let householdId = UUID().uuidString
        let sharedAccountId = UUID().uuidString

        try await dbQueue.write { database in
            try insertAccount(
                database, id: sharedAccountId, ownerId: partnerId, currency: "EUR", openingBalanceE4: 500000
            )
            try database.execute(
                sql: """
                INSERT INTO households (id, created_at, sync_seq) VALUES (?, '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [householdId]
            )
            try database.execute(
                sql: """
                INSERT INTO household_members (household_id, user_id, joined_at, sync_seq)
                VALUES (?, ?, '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [householdId, viewerId]
            )
            try database.execute(
                sql: """
                INSERT INTO household_accounts (household_id, account_id, shared_at, sync_seq)
                VALUES (?, ?, '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [householdId, sharedAccountId]
            )
        }

        let rows = try await dbQueue.read { database in
            try LocalAccountRow.fetchAll(database, ownerId: viewerId, baseCurrency: "EUR")
        }

        #expect(rows.count == 1)
        #expect(rows.first?.isShared == true)
        #expect(rows.first?.balanceE4 == 500000)
    }

    @Test("a missing FX rate renders the base-currency balance as nil, not zero")
    func missingRateRendersNil() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let accountId = UUID().uuidString
        try await dbQueue.write { database in
            try insertAccount(database, id: accountId, ownerId: ownerId, currency: "GBP", openingBalanceE4: 100000)
        }

        let rows = try await dbQueue.read { database in
            try LocalAccountRow.fetchAll(database, ownerId: ownerId, baseCurrency: "EUR")
        }

        #expect(rows.first?.balanceE4 == 100000)
        #expect(rows.first?.balanceBaseE4 == nil)
    }

    @Test("a private (unshared) account owned by someone else never appears")
    func unrelatedAccountInvisible() async throws {
        let dbQueue = try makeDatabase()
        let viewerId = UUID().uuidString
        let strangerId = UUID().uuidString
        try await dbQueue.write { database in
            try insertAccount(
                database, id: UUID().uuidString, ownerId: strangerId, currency: "EUR", openingBalanceE4: 0
            )
        }

        let rows = try await dbQueue.read { database in
            try LocalAccountRow.fetchAll(database, ownerId: viewerId, baseCurrency: "EUR")
        }

        #expect(rows.isEmpty)
    }
}
