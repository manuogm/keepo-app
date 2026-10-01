import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// A partner writing on the owner's shared account: the phone's own copy of
/// the row belongs to the account's owner and records the partner as its
/// author, the same as the server's (20261015100000). Before the fix the
/// app sent the partner as the owner, and the server refused every such row.
@Suite("A partner's writes on the owner's account")
@MainActor
struct PartnerWritesTests {
    private let owner = UUID()
    private let partner = UUID()
    private let account = UUID()
    private let category = UUID()
    private static let stamp = "2026-01-01T00:00:00.000000+00:00"

    private func makeDatabase() throws -> DatabaseQueue {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Joint', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [account.uuidString, owner.uuidString, owner.uuidString, Self.stamp, Self.stamp]
            )
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Other', 1, 'cart', '#000', 1, ?, ?, 1)
                """,
                arguments: [category.uuidString, partner.uuidString, Self.stamp, Self.stamp]
            )
        }
        return dbQueue
    }

    private func ownerAndAuthor(_ dbQueue: DatabaseQueue, table: String) throws -> [String] {
        try dbQueue.read { database in
            let row = try Row.fetchOne(database, sql: "SELECT owner_id, created_by FROM \(table)")
            return [row?["owner_id"] ?? "", row?["created_by"] ?? ""]
        }
    }

    @Test("a transaction the partner enters is the owner's, and says who entered it")
    func transaction() async throws {
        let dbQueue = try makeDatabase()
        let outbox = Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender())
        _ = await outbox.submitCreateTransaction(
            CreateTransactionPayload(
                id: UUID(), ownerId: owner, createdBy: partner, accountId: account, categoryId: category,
                amountE4: -1000, currency: "EUR", occurredAt: Date()
            )
        )
        #expect(try ownerAndAuthor(dbQueue, table: "transactions") == [owner.uuidString, partner.uuidString])
    }

    @Test("an item queued before authors existed is still its owner's own")
    func olderQueuedItem() throws {
        let json = """
        {"id":"\(UUID().uuidString)","ownerId":"\(owner.uuidString)","accountId":"\(account.uuidString)",
         "categoryId":"\(category.uuidString)","amountE4":-1000,"currency":"EUR","occurredAt":0}
        """
        let payload = try JSONDecoder().decode(CreateTransactionPayload.self, from: Data(json.utf8))
        #expect(payload.createdBy == nil)
    }

    @Test("a recurring rule the partner makes is the owner's, the way the server derives it")
    func recurringRule() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { database in
            try RecurringRuleLocalWrite.insert(
                id: UUID(), createdBy: partner, accountId: account, target: .category(category),
                amountE4: -1000, currency: "EUR", frequency: .monthly, nextDueAt: Date(), notes: nil, title: nil,
                in: database
            )
        }
        #expect(try ownerAndAuthor(dbQueue, table: "recurring_rules") == [owner.uuidString, partner.uuidString])
    }
}
