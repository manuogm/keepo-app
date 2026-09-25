import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// A transfer's destination is prefilled only when there is exactly one
/// answer it could have. The rule is three lines, and every one of them is
/// a case that has to hold — it fills nothing on a busy ledger, fills the
/// obvious thing on a two-account one, and never offers an archived
/// account the picker itself would not list.
/// `@MainActor` because `TransactionFormView` is: a `View` carries that
/// isolation, statics included, and calling one from Swift Testing's own
/// (non-main) context does not fail the test — it **crashes** it, with a
/// message naming the `#expect` macro rather than the isolation.
@MainActor
@Suite("Sole transfer destination")
struct SoleTransferDestinationTests {
    private let ownerId = UUID().uuidString

    private func accounts(_ specs: [(id: String, archived: Bool)]) throws -> [LocalAccountRow] {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            for spec in specs {
                try database.execute(
                    sql: """
                    INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                        opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                        archived_at, created_at, updated_at, sync_seq)
                    VALUES (?, ?, ?, 'regular', 'Account', 'USD', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                        ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                    """,
                    arguments: [
                        spec.id, ownerId, ownerId,
                        spec.archived ? "2026-02-01T00:00:00.000000+00:00" : nil
                    ]
                )
            }
        }
        return try dbQueue.read { database in
            try LocalAccountRow.fetchAll(database, ownerId: ownerId, baseCurrency: "USD")
        }
    }

    @Test("Two accounts: the other one is the answer")
    func twoAccountsPrefill() throws {
        let source = UUID()
        let other = UUID()
        let rows = try accounts([(source.uuidString, false), (other.uuidString, false)])

        #expect(TransactionFormView.soleDestination(among: rows, excluding: source) == other)
    }

    /// Three accounts is a real choice, and guessing at one would be a
    /// wrong answer the user has to notice before they can correct it.
    @Test("Three accounts: nothing is prefilled")
    func threeAccountsPrefillNothing() throws {
        let source = UUID()
        let rows = try accounts([
            (source.uuidString, false), (UUID().uuidString, false), (UUID().uuidString, false)
        ])

        #expect(TransactionFormView.soleDestination(among: rows, excluding: source) == nil)
    }

    /// The picker filters archived accounts out of its own menu, so one
    /// prefilled here would show a destination the user cannot re-pick.
    @Test("An archived account is not a candidate, and can leave exactly one behind")
    func archivedAccountsAreNotCandidates() throws {
        let source = UUID()
        let live = UUID()
        let rows = try accounts([
            (source.uuidString, false), (live.uuidString, false), (UUID().uuidString, true)
        ])

        #expect(TransactionFormView.soleDestination(among: rows, excluding: source) == live)
    }

    /// One account is not a transfer at all; the field stays empty rather
    /// than pointing back at the source.
    @Test("A single account prefills nothing")
    func singleAccountPrefillsNothing() throws {
        let source = UUID()
        let rows = try accounts([(source.uuidString, false)])

        #expect(TransactionFormView.soleDestination(among: rows, excluding: source) == nil)
    }

    /// A private account and the partner's shared account are both on
    /// screen, but `check_transfer_integrity` refuses that pair at commit —
    /// so from the private source the only answer is the user's own other
    /// account, and from a shared source the partner's is a real second
    /// choice, so nothing is guessed.
    @Test("An account the source cannot pair with is neither offered nor prefilled")
    func unpairableAccountsAreNotCandidates() throws {
        let partner = UUID().uuidString
        let household = UUID().uuidString
        let privateSource = UUID()
        let myShared = UUID()
        let partnersShared = UUID()
        let stamp = "2026-01-01T00:00:00.000000+00:00"
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            for (id, owner) in [(privateSource.uuidString, ownerId), (myShared.uuidString, ownerId),
                                (partnersShared.uuidString, partner)] {
                try database.execute(
                    sql: """
                    INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                        opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                        created_at, updated_at, sync_seq)
                    VALUES (?, ?, ?, 'regular', 'Account', 'USD', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                        ?, ?, 1)
                    """,
                    arguments: [id, owner, owner, stamp, stamp]
                )
            }
            for user in [ownerId, partner] {
                try database.execute(
                    sql: """
                    INSERT INTO household_members (household_id, user_id, joined_at, sync_seq)
                    VALUES (?, ?, ?, 1)
                    """,
                    arguments: [household, user, stamp]
                )
            }
            for account in [myShared.uuidString, partnersShared.uuidString] {
                try database.execute(
                    sql: """
                    INSERT INTO household_accounts (household_id, account_id, shared_at, sync_seq)
                    VALUES (?, ?, ?, 1)
                    """,
                    arguments: [household, account, stamp]
                )
            }
        }
        let rows = try dbQueue.read { database in
            try LocalAccountRow.fetchAll(database, ownerId: ownerId, baseCurrency: "USD")
        }

        let fromPrivate = TransactionFormView.pairable(with: privateSource, among: rows).map(\.id)
        #expect(!fromPrivate.contains(partnersShared))
        #expect(TransactionFormView.soleDestination(among: rows, excluding: privateSource) == myShared)
        #expect(TransactionFormView.soleDestination(among: rows, excluding: myShared) == nil)
    }
}
