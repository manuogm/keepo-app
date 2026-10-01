import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The fact behind the Categories tab's "See categories" prompt: shown to a
/// user who skipped onboarding's Categories step, gone for good the moment
/// they own a category of their own — including after they delete it.
@Suite("LocalTableQueries.ownsOnlyStarterCategories")
struct StarterCategoriesQueryTests {
    private let ownerId = UUID().uuidString

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func insertCategory(
        _ database: Database, name: String, kind: String, isDefault: Bool = false, deleted: Bool = false
    ) throws {
        let stamp = "2026-01-01T00:00:00.000000+00:00"
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                deleted_at, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, ?, 'cart', '#FF0000', 1, ?, ?, ?, 1)
            """,
            arguments: [UUID().uuidString, ownerId, kind, name, isDefault, deleted ? stamp : nil, stamp, stamp]
        )
    }

    private func seedOthers(_ database: Database) throws {
        try insertCategory(database, name: "Other", kind: "expense", isDefault: true)
        try insertCategory(database, name: "Other", kind: "income", isDefault: true)
    }

    private func query(_ dbQueue: DatabaseQueue) async throws -> Bool {
        try await dbQueue.read { database in
            try LocalTableQueries.ownsOnlyStarterCategories(database, ownerId: ownerId)
        }
    }

    @Test("Only the seeded Other rows: offered")
    func onlyDefaults() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { try seedOthers($0) }
        #expect(try await query(dbQueue))
    }

    /// A fresh install before the first pull lands has no rows at all, and
    /// must not flash the prompt for a user who may have twenty categories.
    @Test("No rows yet: not offered")
    func emptyTable() async throws {
        #expect(try await query(try makeDatabase()) == false)
    }

    @Test("A category of their own: not offered")
    func ownCategory() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { database in
            try seedOthers(database)
            try insertCategory(database, name: "Groceries", kind: "expense")
        }
        #expect(try await query(dbQueue) == false)
    }

    /// The rule the user stated: deleting everything is a choice, not a
    /// fresh start.
    @Test("Every own category deleted: still not offered")
    func deletedOwnCategory() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { database in
            try seedOthers(database)
            try insertCategory(database, name: "Groceries", kind: "expense", deleted: true)
        }
        #expect(try await query(dbQueue) == false)
    }
}
