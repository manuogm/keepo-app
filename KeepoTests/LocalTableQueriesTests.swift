import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `LocalTableQueries` (Phase L6) decodes generated `PublicSchema.*Select`
/// structs straight off local GRDB rows via `FetchableRecord`'s default
/// `Decodable` path — this is the first place that conversion is exercised,
/// so it's worth pinning: a `UUID` TEXT column, a `String`-raw-value enum
/// TEXT column, and a `Bool` INTEGER column all have to decode correctly, or
/// every screen built on top of this silently gets nothing back.
@Suite("LocalTableQueries — FetchableRecord decoding")
struct LocalTableQueriesTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    @Test("categories decode with correct UUID, enum, and bool columns, excluding tombstones")
    func categoriesDecode() async throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID().uuidString
        let liveId = UUID().uuidString
        let deletedId = UUID().uuidString
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    deleted_at, created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Groceries', 0, 'cart', '#FF0000', 1, NULL,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [liveId, ownerId]
            )
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    deleted_at, created_at, updated_at, sync_seq)
                VALUES (?, ?, 'income', 'Gone', 0, 'trash', '#000000', 1,
                    '2026-01-02T00:00:00.000000+00:00',
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 2)
                """,
                arguments: [deletedId, ownerId]
            )
        }

        let categories = try await dbQueue.read { database in try LocalTableQueries.categories(database) }

        #expect(categories.count == 1)
        #expect(categories.first?.id.uuidString.lowercased() == liveId.lowercased())
        #expect(categories.first?.kind == .expense)
        #expect(categories.first?.isDefault == false)
        #expect(categories.first?.name == "Groceries")
    }

    @Test("a single account fetch by id decodes AccountsSelect correctly")
    func accountDecodes() async throws {
        let dbQueue = try makeDatabase()
        let accountId = UUID().uuidString
        let ownerId = UUID().uuidString
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color,
                    version, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'ledger', 'checking', 'Checking', 'EUR', 1000000, '2026-01-01', 1, 'banknote',
                    '#8E8E93', 1, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [accountId, ownerId, ownerId]
            )
        }

        let account = try await dbQueue.read { database in try LocalTableQueries.account(database, id: accountId) }

        #expect(account?.name == "Checking")
        #expect(account?.kind == .ledger)
        #expect(account?.subtype == .checking)
        #expect(account?.currency == "EUR")
        #expect(account?.includeInTotal == true)
    }

    @Test("a local profile fetch decodes ProfilesSelect, and is nil for an unknown or deleted id")
    func profileDecodes() async throws {
        let dbQueue = try makeDatabase()
        let userId = UUID().uuidString
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO profiles (id, base_currency, onboarded_at, created_at, updated_at, sync_epoch, sync_seq)
                VALUES (?, 'EUR', '2026-01-01T00:00:00.000000+00:00',
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1, 1)
                """,
                arguments: [userId]
            )
        }

        let profile = try await dbQueue.read { database in try LocalTableQueries.profile(database, id: userId) }
        let missing = try await dbQueue.read { database in
            try LocalTableQueries.profile(database, id: UUID().uuidString)
        }

        #expect(profile?.baseCurrency == "EUR")
        #expect(profile?.onboardedAt != nil)
        #expect(missing == nil)
    }

    @Test("no household row when the user isn't a member of any household")
    func myHouseholdNilWhenUnaffiliated() async throws {
        let dbQueue = try makeDatabase()
        let household = try await dbQueue.read { database in
            try LocalTableQueries.myHousehold(database, userId: UUID().uuidString)
        }
        #expect(household == nil)
    }
}
