import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The ranking behind both the transaction form's three suggested chips and
/// the capture notification's quick actions. One query, so these assertions
/// cover both — which is the reason it is one query.
@Suite("LocalCategoryRanking — most-used categories")
struct LocalCategoryRankingTests {
    private let ownerId = UUID().uuidString
    private let checking = UUID().uuidString
    private let savings = UUID().uuidString

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func insertCategory(_ database: Database, id: String, name: String, kind: String) throws {
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                deleted_at, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, 0, 'cart', '#FF0000', 1, NULL,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [id, ownerId, kind, name]
        )
    }

    /// `day` orders the rows against each other — the tie-break reads it.
    private func insertTransaction(
        _ database: Database, accountId: String, categoryId: String, day: Int, deleted: Bool = false
    ) throws {
        let occurredAt = String(format: "2026-03-%02dT12:00:00.000000+00:00", day)
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4,
                currency, occurred_at, source, status, version, deleted_at, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, ?, -1000, 'USD', ?, 'manual', 'confirmed', 1, ?, ?, ?, 1)
            """,
            arguments: [
                UUID().uuidString, ownerId, ownerId, accountId, categoryId, occurredAt,
                deleted ? occurredAt : nil, occurredAt, occurredAt
            ]
        )
    }

    /// The whole point: what this account is used for, most first.
    @Test("Ranks an account's categories by how often they are used")
    func ranksByUse() async throws {
        let dbQueue = try makeDatabase()
        let groceries = UUID().uuidString
        let fuel = UUID().uuidString
        let books = UUID().uuidString
        try await dbQueue.write { database in
            try insertCategory(database, id: groceries, name: "Groceries", kind: "expense")
            try insertCategory(database, id: fuel, name: "Fuel", kind: "expense")
            try insertCategory(database, id: books, name: "Books", kind: "expense")
            try insertTransaction(database, accountId: checking, categoryId: books, day: 1)
            for day in 2...4 { try insertTransaction(database, accountId: checking, categoryId: groceries, day: day) }
            for day in 5...6 { try insertTransaction(database, accountId: checking, categoryId: fuel, day: day) }
        }

        let ranked = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(database, ownerId: ownerId, accountId: checking, limit: 3)
        }

        #expect(ranked.map(\.name) == ["Groceries", "Fuel", "Books"])
    }

    /// A form that suggested an income category for an expense would be
    /// offering a save the database's own `sign_matches_category_kind`
    /// rejects.
    @Test("The kind filter never crosses expense and income")
    func filtersByKind() async throws {
        let dbQueue = try makeDatabase()
        let salary = UUID().uuidString
        let groceries = UUID().uuidString
        try await dbQueue.write { database in
            try insertCategory(database, id: salary, name: "Salary", kind: "income")
            try insertCategory(database, id: groceries, name: "Groceries", kind: "expense")
            for day in 1...5 { try insertTransaction(database, accountId: checking, categoryId: salary, day: day) }
            try insertTransaction(database, accountId: checking, categoryId: groceries, day: 6)
        }

        let expenses = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(
                database, ownerId: ownerId, accountId: checking, categoryKind: "expense", limit: 3
            )
        }

        #expect(expenses.map(\.name) == ["Groceries"])
    }

    /// The account filter is what makes a suggestion about *this* card
    /// rather than about the ledger as a whole; dropping it is the
    /// deliberate second pass for an account with no history yet.
    @Test("An account sees its own habits, and the whole ledger only when asked")
    func filtersByAccount() async throws {
        let dbQueue = try makeDatabase()
        let groceries = UUID().uuidString
        let rent = UUID().uuidString
        try await dbQueue.write { database in
            try insertCategory(database, id: groceries, name: "Groceries", kind: "expense")
            try insertCategory(database, id: rent, name: "Rent", kind: "expense")
            try insertTransaction(database, accountId: checking, categoryId: groceries, day: 1)
            for day in 2...4 { try insertTransaction(database, accountId: savings, categoryId: rent, day: day) }
        }

        let forChecking = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(database, ownerId: ownerId, accountId: checking, limit: 3)
        }
        let everywhere = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(database, ownerId: ownerId, limit: 3)
        }

        #expect(forChecking.map(\.name) == ["Groceries"])
        #expect(everywhere.map(\.name) == ["Rent", "Groceries"])
    }

    /// Equal counts used to come back in whatever order SQLite felt like,
    /// which is not something chips under a finger are allowed to do.
    @Test("Equal use is broken by which was used most recently")
    func tieBreaksByRecency() async throws {
        let dbQueue = try makeDatabase()
        let older = UUID().uuidString
        let newer = UUID().uuidString
        try await dbQueue.write { database in
            try insertCategory(database, id: older, name: "Older", kind: "expense")
            try insertCategory(database, id: newer, name: "Newer", kind: "expense")
            try insertTransaction(database, accountId: checking, categoryId: older, day: 1)
            try insertTransaction(database, accountId: checking, categoryId: newer, day: 2)
        }

        let ranked = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(database, ownerId: ownerId, accountId: checking, limit: 3)
        }

        #expect(ranked.map(\.name) == ["Newer", "Older"])
    }

    /// A deleted transaction is not a habit, and `excluding` is what keeps
    /// a capture notification from offering the button beside it twice.
    @Test("Tombstones and the excluded category stay out")
    func skipsDeletedAndExcluded() async throws {
        let dbQueue = try makeDatabase()
        let groceries = UUID().uuidString
        let fuel = UUID().uuidString
        try await dbQueue.write { database in
            try insertCategory(database, id: groceries, name: "Groceries", kind: "expense")
            try insertCategory(database, id: fuel, name: "Fuel", kind: "expense")
            for day in 1...3 {
                try insertTransaction(database, accountId: checking, categoryId: groceries, day: day, deleted: true)
            }
            try insertTransaction(database, accountId: checking, categoryId: fuel, day: 4)
        }

        let ranked = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(database, ownerId: ownerId, accountId: checking, limit: 3)
        }
        let excluded = try await dbQueue.read { database in
            try LocalCategoryRanking.mostUsed(
                database, ownerId: ownerId, accountId: checking, excluding: fuel, limit: 3
            )
        }

        #expect(ranked.map(\.name) == ["Fuel"])
        #expect(excluded.isEmpty)
    }
}
