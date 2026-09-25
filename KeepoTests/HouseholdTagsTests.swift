import Foundation
import GRDB
import KeepoCore
import Supabase
import Testing
@testable import Keepo

/// The tags the Household summary counts as shared: the second half of the
/// server's `can_read_tag`, read from the phone's own mirror.
///
/// Before this, the card counted every tag the phone held, so each phone
/// counted its owner's private tags and the two disagreed.
@Suite("The tags a household shares")
struct HouseholdTagsTests {
    private static let owner = "11111111-1111-1111-1111-111111111111"
    private static let partner = "22222222-2222-2222-2222-222222222222"
    private static let household = "e7000000-0000-0000-0000-000000000001"
    private static let shared = "a7000000-0000-0000-0000-000000000001"
    private static let unshared = "a7000000-0000-0000-0000-000000000002"
    private static let stamp = "2026-01-01T00:00:00.000000+00:00"
    /// The share starts here. The earlier row is half an hour before it; the
    /// later one is the same moment in another offset, so the start itself
    /// counts and the query compares moments, not strings.
    private static let start = "2026-08-01T00:00:00+00:00"
    private static let before = "2026-07-31T23:30:00.000000+00:00"
    private static let after = "2026-08-01T02:00:00+02:00"

    private enum Tag: String, CaseIterable {
        case afterStart = "After"
        case beforeStart = "Before"
        case unsharedAccount = "Private account"
        case unused = "Unused"
        case removedLink = "Removed"
    }

    private func makeDatabase(historyFrom: String?) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            try seedHousehold(database, historyFrom: historyFrom)
            try seedTags(database)
        }
        return dbQueue
    }

    private func seedHousehold(_ database: Database, historyFrom: String?) throws {
        try database.execute(
            sql: "INSERT INTO households (id, created_at, sync_seq) VALUES (?, ?, 1)",
            arguments: [Self.household, Self.stamp]
        )
        for member in [Self.owner, Self.partner] {
            try database.execute(
                sql: "INSERT INTO household_members (household_id, user_id, joined_at, sync_seq) VALUES (?, ?, ?, 1)",
                arguments: [Self.household, member, Self.stamp]
            )
        }
        for account in [Self.shared, Self.unshared] {
            try database.execute(
                sql: """
                INSERT INTO accounts (
                    id, owner_id, created_by, kind, name, currency, opening_balance_e4, opening_balance_at,
                    include_in_total, icon, color, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, 'regular', 'Account', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [account, Self.owner, Self.owner, Self.stamp, Self.stamp]
            )
        }
        var share: JSONObject = [
            "household_id": .string(Self.household), "account_id": .string(Self.shared),
            "shared_at": .string(Self.start), "sync_seq": .integer(1)
        ]
        if let historyFrom { share["history_from"] = .string(historyFrom) }
        try SyncApply.upsertRow(share, table: "household_accounts", in: database)
    }

    /// One owner's tag per case, each on its own transaction (or none).
    private func seedTags(_ database: Database) throws {
        for (index, tag) in Tag.allCases.enumerated() {
            let tagId = "e7100000-0000-0000-0000-00000000000\(index)"
            try database.execute(
                sql: """
                INSERT INTO tags (id, owner_id, name, version, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 1, ?, ?, 1)
                """,
                arguments: [tagId, Self.owner, tag.rawValue, Self.stamp, Self.stamp]
            )
            let placement: (account: String, occurredAt: String)?
            switch tag {
            case .afterStart, .removedLink: placement = (Self.shared, Self.after)
            case .beforeStart: placement = (Self.shared, Self.before)
            case .unsharedAccount: placement = (Self.unshared, Self.after)
            case .unused: placement = nil
            }
            guard let placement else { continue }
            let transactionId = "d7100000-0000-0000-0000-00000000000\(index)"
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, source, status,
                    version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, -1000, 'EUR', ?, 'manual', 'confirmed', 1, ?, ?, 1)
                """,
                arguments: [
                    transactionId, Self.owner, Self.owner, placement.account, placement.occurredAt,
                    Self.stamp, Self.stamp
                ]
            )
            try database.execute(
                sql: """
                INSERT INTO transaction_tags (
                    transaction_id, tag_id, owner_id, created_at, updated_at, deleted_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                """,
                arguments: [
                    transactionId, tagId, Self.owner, Self.stamp, Self.stamp,
                    tag == .removedLink ? Self.stamp : nil
                ]
            )
        }
    }

    private func sharedTagNames(_ dbQueue: DatabaseQueue, viewer: String) throws -> [String] {
        try dbQueue.read { database in
            try LocalTableQueries.householdTags(database, viewerId: viewer).map(\.name)
        }
    }

    @Test("on a share from a date, only a tag used on the shared account from that date is shared")
    func shareFromADate() throws {
        let dbQueue = try makeDatabase(historyFrom: Self.start)
        #expect(try sharedTagNames(dbQueue, viewer: Self.owner) == [Tag.afterStart.rawValue])
    }

    @Test("the partner's phone, after the purge, counts the same set as the owner's")
    func bothPhonesAgree() throws {
        let dbQueue = try makeDatabase(historyFrom: Self.start)
        try dbQueue.write { database in
            try SyncApply.purgeHistoryBeforeShares(viewerId: Self.partner, in: database)
        }
        #expect(try sharedTagNames(dbQueue, viewer: Self.partner) == [Tag.afterStart.rawValue])
    }

    @Test("with the full history shared, a tag from before the share date counts too")
    func fullHistory() throws {
        let dbQueue = try makeDatabase(historyFrom: nil)
        #expect(
            try sharedTagNames(dbQueue, viewer: Self.owner) == [Tag.afterStart.rawValue, Tag.beforeStart.rawValue]
        )
    }

    @Test("once the account stops being shared, none of its tags are")
    func endedShare() throws {
        let dbQueue = try makeDatabase(historyFrom: nil)
        try dbQueue.write { database in
            try database.execute(sql: "UPDATE household_accounts SET deleted_at = ?", arguments: [Self.stamp])
        }
        #expect(try sharedTagNames(dbQueue, viewer: Self.owner).isEmpty)
    }
}
