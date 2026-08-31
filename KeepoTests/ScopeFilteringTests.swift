import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The redesign put the scope on every main screen's banner, which made two
/// things load-bearing that had not been before: the Transactions list has
/// to honour the scope it is displaying (it did not — the old scope button
/// sat in its toolbar and filtered nothing), and each screen has to know
/// when the chosen scope is empty so it can say why.
@Suite("Scope filtering")
struct ScopeFilteringTests {
    private static let ownerId = "77777777-7777-7777-7777-777777777777"
    private static let householdId = "88888888-8888-8888-8888-888888888888"
    private static let privateAccount = "99999999-0000-0000-0000-000000000001"
    private static let sharedAccount = "99999999-0000-0000-0000-000000000002"
    private static let privateTransaction = "aaaaaaaa-0000-0000-0000-000000000001"
    private static let sharedTransaction = "aaaaaaaa-0000-0000-0000-000000000002"
    private static let epoch = "2026-01-01T00:00:00.000000+00:00"
    private static let occurredAt = "2026-06-15T12:00:00.000000+00:00"

    /// One account kept private, one shared into a household the user
    /// belongs to, and one transaction on each — the smallest world in which
    /// `me` and `household` can disagree.
    private func makeDatabase(shareAccount: Bool = true, withHousehold: Bool = true) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in
            try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
            try seedAccounts(database)
            if withHousehold { try seedHousehold(database, sharing: shareAccount) }
            try seedTransactions(database)
        }
        return dbQueue
    }

    private func seedAccounts(_ database: Database) throws {
        for id in [Self.privateAccount, Self.sharedAccount] {
            try database.execute(
                sql: """
                INSERT INTO accounts (
                    id, owner_id, created_by, kind, name, currency, opening_balance_e4, opening_balance_at,
                    include_in_total, icon, color, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, 'regular', ?, 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [id, Self.ownerId, Self.ownerId, id, Self.epoch, Self.epoch]
            )
        }
    }

    private func seedHousehold(_ database: Database, sharing: Bool) throws {
        try database.execute(
            sql: "INSERT INTO households (id, created_at, sync_seq) VALUES (?, ?, 1)",
            arguments: [Self.householdId, Self.epoch]
        )
        try database.execute(
            sql: "INSERT INTO household_members (household_id, user_id, joined_at, sync_seq) VALUES (?, ?, ?, 1)",
            arguments: [Self.householdId, Self.ownerId, Self.epoch]
        )
        guard sharing else { return }
        try database.execute(
            sql: "INSERT INTO household_accounts (household_id, account_id, shared_at, sync_seq) VALUES (?, ?, ?, 1)",
            arguments: [Self.householdId, Self.sharedAccount, Self.epoch]
        )
    }

    private func seedTransactions(_ database: Database) throws {
        for (id, account) in [
            (Self.privateTransaction, Self.privateAccount), (Self.sharedTransaction, Self.sharedAccount)
        ] {
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, source, status,
                    version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, -50000, 'EUR', ?, 'manual', 'confirmed', 1, ?, ?, 1)
                """,
                arguments: [id, Self.ownerId, Self.ownerId, account, Self.occurredAt, Self.epoch, Self.epoch]
            )
        }
    }

    private func accountIds(
        _ dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope
    ) async throws -> Set<String> {
        let rows = try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(), scope: scope, baseCurrency: "EUR", ownerId: Self.ownerId
            )
        }
        return Set(rows.compactMap { $0.accountId?.uuidString.lowercased() })
    }

    @Test("total sees both accounts' transactions")
    func totalSeesEverything() async throws {
        let dbQueue = try makeDatabase()
        #expect(try await accountIds(dbQueue, scope: .total) == [Self.privateAccount, Self.sharedAccount])
    }

    @Test("private excludes transactions on a shared account")
    func privateExcludesShared() async throws {
        let dbQueue = try makeDatabase()
        #expect(try await accountIds(dbQueue, scope: .me) == [Self.privateAccount])
    }

    @Test("household excludes transactions on an unshared account")
    func householdExcludesPrivate() async throws {
        let dbQueue = try makeDatabase()
        #expect(try await accountIds(dbQueue, scope: .household) == [Self.sharedAccount])
    }

    @Test("scope availability counts what is visible and what of it is shared")
    func availabilityCounts() async throws {
        let dbQueue = try makeDatabase()
        let availability = try await dbQueue.read { database in
            try LocalTableQueries.scopeAvailability(database, ownerId: Self.ownerId)
        }
        #expect(availability.visibleCount == 2)
        #expect(availability.sharedCount == 1)
    }

    @Test("an archived account counts towards no scope at all")
    func archivedAccountIsNotAvailable() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { database in
            try database.execute(
                sql: "UPDATE accounts SET archived_at = ? WHERE id = ?",
                arguments: [Self.epoch, Self.privateAccount]
            )
        }
        let availability = try await dbQueue.read { database in
            try LocalTableQueries.scopeAvailability(database, ownerId: Self.ownerId)
        }
        #expect(availability.visibleCount == 1)
        #expect(availability.sharedCount == 1)
    }

    @Test("no household means no shared account is visible either")
    func withoutHouseholdNothingIsShared() async throws {
        let dbQueue = try makeDatabase(shareAccount: false, withHousehold: false)
        let availability = try await dbQueue.read { database in
            try LocalTableQueries.scopeAvailability(database, ownerId: Self.ownerId)
        }
        #expect(availability.visibleCount == 2)
        #expect(availability.sharedCount == 0)
    }
}

/// The blank-state decision table, pinned as the pure function it is.
@Suite("Scope emptiness")
struct ScopeEmptinessTests {
    private func resolve(
        _ scope: PublicSchema.AccountScope,
        anyAccount: Bool = true,
        privateAccount: Bool = true,
        sharedAccount: Bool = true,
        household: Bool = true
    ) -> ScopeEmptiness? {
        ScopeEmptiness.resolve(
            scope: scope, hasAnyAccount: anyAccount, hasPrivateAccount: privateAccount,
            hasSharedAccount: sharedAccount, hasHousehold: household
        )
    }

    @Test("a fully stocked user sees no blank state in any scope")
    func nothingIsEmpty() {
        for scope in PublicSchema.AccountScope.carousel {
            #expect(resolve(scope) == nil)
        }
    }

    @Test("no accounts outranks every scope-specific case")
    func noAccountsWins() {
        for scope in PublicSchema.AccountScope.carousel {
            #expect(
                resolve(
                    scope, anyAccount: false, privateAccount: false, sharedAccount: false, household: false
                ) == .noAccounts
            )
        }
    }

    @Test("household scope without a household offers the creation route")
    func householdMissing() {
        #expect(resolve(.household, sharedAccount: false, household: false) == .noHousehold)
    }

    @Test("private scope with every account shared is a dead end, not a task")
    func everythingShared() {
        #expect(resolve(.me, privateAccount: false) == .noPrivateAccounts)
        // Total still renders — it can see the shared accounts.
        #expect(resolve(.total, privateAccount: false) == nil)
    }

    @Test("a household with nothing shared into it says so")
    func nothingShared() {
        #expect(resolve(.household, sharedAccount: false) == .noSharedAccounts)
    }
}
