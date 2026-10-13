import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// What the Sync Conflict sheet compares, and what the inbox row says.
/// Reproduced on 2026-10-13: an account conflict compared the saved account
/// with itself ("nothing looks different"), a category change never showed,
/// and every row read "Sync conflict — transactions / your version 1 vs. the
/// saved version 2".
@Suite("Conflict comparison")
struct ConflictComparisonTests {
    private let ownerId = UUID().uuidString.lowercased()
    private let checking = UUID().uuidString.lowercased()
    private let savings = UUID().uuidString.lowercased()
    private let groceries = UUID().uuidString.lowercased()
    private let dining = UUID().uuidString.lowercased()
    private let transactionId = UUID().uuidString.lowercased()

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
            for (id, name) in [(checking, "Checking"), (savings, "Savings")] {
                try database.execute(
                    sql: """
                    INSERT INTO accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4,
                        opening_balance_at, include_in_total, icon, color, version, created_at, updated_at, sync_seq)
                    VALUES (?, ?, ?, 'regular', ?, 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 2,
                        '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                    """,
                    arguments: [id, ownerId, ownerId, name]
                )
            }
            for (id, name) in [(groceries, "Groceries"), (dining, "Dining")] {
                try database.execute(
                    sql: """
                    INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                        created_at, updated_at, sync_seq)
                    VALUES (?, ?, 'expense', ?, 0, 'cart', '#000', 1,
                        '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                    """,
                    arguments: [id, ownerId, name]
                )
            }
            try database.execute(
                sql: """
                INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                    occurred_at, merchant_raw, source, status, version, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, ?, -500000, 'EUR', '2026-06-15T12:00:00.000000+00:00', 'Mercadona', 'manual',
                    'confirmed', 2, '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1)
                """,
                arguments: [transactionId, ownerId, ownerId, checking, groceries]
            )
        }
        return dbQueue
    }

    private func insertConflict(
        _ database: Database, table: String, rowId: String, attempted: String?
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        try database.execute(
            sql: """
            INSERT INTO sync_conflicts (id, table_name, row_id, owner_id, client_version, server_version,
                attempted_payload, created_at, sync_seq)
            VALUES (?, ?, ?, ?, 1, 2, ?, '2026-06-15T12:00:00.000000+00:00', 1)
            """,
            arguments: [id, table, rowId, ownerId, attempted]
        )
        return id
    }

    @Test("a ledger edit's own version carries its category, account and amount, by name")
    func transactionEditIsComparedByName() async throws {
        let dbQueue = try makeDatabase()
        let attempted = """
            {"rpc": "update_transaction", "account_id": "\(savings)", "category_id": "\(dining)",
             "amount_e4": -450000, "currency": "EUR", "occurred_at": "2026-06-15T12:00:00+00:00",
             "merchant_raw": "Mercadona", "notes": null, "title": null,
             "original_amount_e4": null, "original_currency": null}
            """
        let comparison = try await dbQueue.write { database in
            let id = try insertConflict(database, table: "transactions", rowId: transactionId, attempted: attempted)
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }

        let result = try #require(comparison)
        guard case .transaction(let mine)? = result.mine?.tile else { Issue.record("no device version"); return }
        #expect(mine.row.categoryName == "Dining")
        #expect(mine.row.accountName == "Savings")
        #expect(mine.row.amountE4 == -450_000)
        #expect(mine.row.amountBaseE4 == -450_000, "converted exactly as a saved row would be")
        #expect(Set(result.fields.map(\.label)) == ["Amount", "Category", "Account"])
        #expect(Set(result.fields.map(\.placement)) == [
            .transaction(.amount), .transaction(.category), .transaction(.account)
        ], "each is struck and replaced on the tile, never listed again")
        let category = try #require(result.fields.first { $0.label == "Category" })
        #expect(category.saved == "Groceries")
        #expect(category.mine == "Dining")
        #expect(result.hasChoice)
    }

    @Test("a swipe-confirm differs from a pending capture by its status")
    func confirmIsComparedByStatus() async throws {
        let dbQueue = try makeDatabase()
        let comparison = try await dbQueue.write { database in
            try database.execute(sql: "UPDATE transactions SET status = 'pending', source = 'capture'")
            let id = try insertConflict(
                database, table: "transactions", rowId: transactionId,
                attempted: #"{"rpc": "confirm_capture_transaction"}"#
            )
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }
        let field = try #require(comparison?.fields.first)
        #expect(comparison?.fields.count == 1)
        #expect(field.label == "Status")
        #expect(field.placement == .transaction(.status), "the tile's Pending badge, struck, then Confirmed")
        #expect(field.saved == "Pending")
        #expect(field.mine == "Confirmed")
    }

    @Test("an account conflict compares the write it kept, not the saved account with itself")
    func accountRenameIsCompared() async throws {
        let dbQueue = try makeDatabase()
        let comparison = try await dbQueue.write { database in
            let id = try insertConflict(
                database, table: "accounts", rowId: checking,
                attempted: """
                    {"rpc": "update_account", "name": "Everyday", "include_in_total": true,
                     "icon": "banknote", "color": "#8E8E93"}
                    """
            )
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }
        let result = try #require(comparison)
        #expect(result.detail.attemptedAccountWrite?.rpc == "update_account")
        #expect(result.detail.attemptedWrite == nil)
        #expect(result.fields.map(\.label) == ["Name"])
        #expect(result.fields.first?.placement == .account(.name))
        #expect(result.fields.first?.saved == "Checking")
        #expect(result.fields.first?.mine == "Everyday")
        guard case .account(let mine)? = result.mine?.tile, case .account(let saved)? = result.saved?.tile else {
            Issue.record("no account tiles"); return
        }
        #expect(mine.row.name == "Everyday")
        #expect(saved.row.name == "Checking")
    }

    @Test("a note gets a line of its own; a date is each card's own, never struck")
    func noteIsALineAndDateIsEachCards() async throws {
        let dbQueue = try makeDatabase()
        let attempted = """
            {"rpc": "update_transaction", "account_id": "\(checking)", "category_id": "\(groceries)",
             "amount_e4": -500000, "currency": "EUR", "occurred_at": "2026-06-14T12:00:00+00:00",
             "merchant_raw": "Mercadona", "notes": "receipt in the drawer", "title": null,
             "original_amount_e4": null, "original_currency": null}
            """
        let comparison = try await dbQueue.write { database in
            let id = try insertConflict(database, table: "transactions", rowId: transactionId, attempted: attempted)
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }
        let fields = try #require(comparison?.fields)
        #expect(fields.map(\.label) == ["Date", "Note"])
        #expect(fields.map(\.placement) == [.date, .line])
        #expect(comparison?.requestedDate != comparison?.savedDate)
        #expect(fields.last?.mine == "receipt in the drawer")
        #expect(fields.last?.saved == "", "no saved note: nothing to strike")
    }

    @Test("a delete is a choice with no field to show it")
    func deleteIsAChoice() async throws {
        let dbQueue = try makeDatabase()
        let comparison = try await dbQueue.write { database in
            let id = try insertConflict(
                database, table: "transactions", rowId: transactionId, attempted: #"{"rpc": "delete_transaction"}"#
            )
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }
        #expect(comparison?.mine?.isDeleted == true)
        #expect(comparison?.fields.isEmpty == true)
        #expect(comparison?.hasChoice == true)
    }

    @Test("a conflict that kept no record of the change offers nothing to choose")
    func noRecordIsNoChoice() async throws {
        let dbQueue = try makeDatabase()
        let comparison = try await dbQueue.write { database in
            let id = try insertConflict(database, table: "accounts", rowId: checking, attempted: nil)
            return try ConflictComparison.load(database, conflictId: id, ownerId: ownerId, baseCurrency: "EUR")
        }
        #expect(comparison?.mine == nil)
        #expect(comparison?.hasChoice == false)
    }

    @Test("the inbox row names the thing and says what to do, with no version numbers")
    func inboxRowIsPlainEnglish() async throws {
        let dbQueue = try makeDatabase()
        let rows = try await dbQueue.write { database in
            _ = try insertConflict(database, table: "transactions", rowId: transactionId, attempted: nil)
            _ = try insertConflict(database, table: "accounts", rowId: checking, attempted: nil)
            return try LocalMoneyQueries.needsReview(database, ownerId: ownerId)
        }
        #expect(Set(rows.map(\.title)) == ["Sync Conflict"])
        #expect(Set(rows.map(\.subtitle)) == [
            "Mercadona · Choose which version to keep", "Checking · Choose which version to keep"
        ])
    }
}
