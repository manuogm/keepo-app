import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The referee for a partner on a share that began on a date: the phone's one
/// balance formula, over what the server sends that partner, lands on the
/// owner's true balance.
///
/// Pinned to `supabase/tests/52_a_partner_is_handed_what_they_can_see.sql`,
/// which asserts the same shape against Postgres: an account opening at
/// 1,000,000 with 100,000 spent before the start date and 200,000 after. The
/// partner is sent an opening of 900,000 (`account_opening_as_seen`) and only
/// the later row; `account_balance_on` is 700,000.
@Suite("A partner on a share from a date — the referee")
struct LimitedPartnerRefereeTests {
    private static let owner = "11111111-1111-1111-1111-111111111111"
    private static let partner = "22222222-2222-2222-2222-222222222222"
    private static let household = "52000000-0000-0000-0000-000000000001"
    private static let account = "a5200000-0000-0000-0000-000000000001"
    private static let before = "d5200000-0000-0000-0000-000000000001"
    private static let after = "d5200000-0000-0000-0000-000000000002"
    private static let tag = "e5200000-0000-0000-0000-000000000001"
    private static let today = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 13)) ?? Date()

    private struct Entry {
        let id: String
        let amount: Int64
        let occurredAt: String
    }

    private static let stamp = "2026-01-01T00:00:00.000000+00:00"

    private func makeDatabase(viewer: String, opening: Int64, entries: [Entry]) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            try seedHousehold(database, opening: opening)
            try seedEntries(database, entries)
            try SyncApply.purgeHistoryBeforeShares(viewerId: viewer, in: database)
        }
        return dbQueue
    }

    private func seedHousehold(_ database: Database, opening: Int64) throws {
        try database.execute(
            sql: "INSERT INTO households (id, created_at, sync_seq) VALUES (?, ?, 1)",
            arguments: [Self.household, Self.stamp]
        )
        for member in [Self.owner, Self.partner] {
            try database.execute(
                sql: """
                INSERT INTO household_members (household_id, user_id, joined_at, sync_seq) VALUES (?, ?, ?, 1)
                """,
                arguments: [Self.household, member, Self.stamp]
            )
        }
        try database.execute(
            sql: """
            INSERT INTO accounts (
                id, owner_id, created_by, kind, name, currency, opening_balance_e4, opening_balance_at,
                include_in_total, icon, color, version, created_at, updated_at, sync_seq
            ) VALUES (?, ?, ?, 'regular', 'Joint', 'EUR', ?, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
            """,
            arguments: [Self.account, Self.owner, Self.owner, opening, Self.stamp, Self.stamp]
        )
        // Through the sync whitelist, as a pull would write it.
        try SyncApply.upsertRow(
            [
                "household_id": .string(Self.household), "account_id": .string(Self.account),
                "shared_at": .string("2026-08-01T00:00:00+00:00"), "sync_seq": .integer(1),
                "history_from": .string("2026-08-01T00:00:00+00:00")
            ],
            table: "household_accounts", in: database
        )
    }

    /// The entries, and a tag on the earlier one — a link the purge must
    /// take with its row.
    private func seedEntries(_ database: Database, _ entries: [Entry]) throws {
        for entry in entries {
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, source, status,
                    version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, 'EUR', ?, 'manual', 'confirmed', 1, ?, ?, 1)
                """,
                arguments: [
                    entry.id, Self.owner, Self.owner, Self.account, entry.amount, entry.occurredAt,
                    Self.stamp, Self.stamp
                ]
            )
        }
        try database.execute(
            sql: """
            INSERT INTO tags (id, owner_id, name, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, 'Trip', 1, ?, ?, 1)
            """,
            arguments: [Self.tag, Self.owner, Self.stamp, Self.stamp]
        )
        try database.execute(
            sql: """
            INSERT INTO transaction_tags (transaction_id, tag_id, owner_id, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, ?, 1)
            """,
            arguments: [Self.before, Self.tag, Self.owner, Self.stamp, Self.stamp]
        )
    }

    private func balance(_ dbQueue: DatabaseQueue) throws -> Int64? {
        try dbQueue.read { database in
            try LocalMoneyQueries.accountBalance(
                database, accountId: Self.account, asOf: "2026-08-13", now: Self.today
            )
        }
    }

    /// Mixed precisions and offsets on purpose: the purge compares moments,
    /// not strings.
    private var bothEntries: [Entry] {
        [
            Entry(id: Self.before, amount: -100_000, occurredAt: "2026-07-01T09:00:00.000000+00:00"),
            Entry(id: Self.after, amount: -200_000, occurredAt: "2026-08-10T09:00:00+00:00")
        ]
    }

    @Test("the start date survives the sync whitelist")
    func historyFromIsKept() throws {
        let dbQueue = try makeDatabase(viewer: Self.owner, opening: 1_000_000, entries: [])
        let historyFrom = try dbQueue.read { database in
            try String.fetchOne(database, sql: "SELECT history_from FROM household_accounts")
        }
        #expect(historyFrom == "2026-08-01T00:00:00+00:00")
    }

    @Test("the partner's phone, holding a row from before the start, drops it and lands on the true balance")
    func partnerLandsOnTheTrueBalance() throws {
        let dbQueue = try makeDatabase(viewer: Self.partner, opening: 900_000, entries: bothEntries)
        #expect(try balance(dbQueue) == 700_000)
        let left = try dbQueue.read { database in
            (
                try String.fetchAll(database, sql: "SELECT id FROM transactions"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transaction_tags") ?? -1
            )
        }
        #expect(left.0 == [Self.after])
        #expect(left.1 == 0)
    }

    @Test("the owner's phone keeps its whole history")
    func ownerKeepsEverything() throws {
        let dbQueue = try makeDatabase(viewer: Self.owner, opening: 1_000_000, entries: bothEntries)
        #expect(try balance(dbQueue) == 700_000)
        let count = try dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transactions")
        }
        #expect(count == 2)
    }
}
