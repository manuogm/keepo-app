import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The L4 referee (`keepo-local-first-plan.md`): one fixture, asserted
/// against real Postgres output captured once via `docker exec ... psql`
/// against the local dev stack (two ledger currencies with a resolvable
/// rate, one with none, a JPY account, and a valuation account with an
/// unrealized gain) — see `version-logs/phase-L4-log.md` for the exact
/// command and the full captured output this file's expectations are
/// pinned to. This is NOT a live cross-process comparison: the iOS test
/// target has no Postgres wire-protocol driver, so "the referee" here means
/// asserting the SQLite port reproduces numbers Postgres actually produced,
/// not asking Postgres live at every run. Regenerate the pinned values (by
/// rerunning the capture) if the ported SQL ever changes on either side.
@Suite("L4 referee — SQLite vs. pinned Postgres output")
struct LocalMoneyRefereeTests {
    /// `2026-08-13`, midnight UTC — the wall-clock date `current_date`
    /// resolved to when the Postgres capture was taken (confirmed via
    /// `select current_date` in the same session), and every explicit date
    /// argument passed to the captured RPCs below.
    private static let today = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 13)) ?? Date()

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in try RefereeFixture.seed(database) }
        return dbQueue
    }

    // MARK: - account_balance_on / unrealized_gain

    @Test("account_balance_on matches Postgres for all five accounts")
    func accountBalanceMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let expected: [String: Int64] = [
            RefereeFixture.eurBrokerage: 60_000_000, RefereeFixture.eurChecking: 50_380_000,
            RefereeFixture.gbpCash: 1_800_000, RefereeFixture.jpyWallet: 70_000_000,
            RefereeFixture.usdSavings: 4_700_000
        ]
        try dbQueue.read { database in
            for (accountId, expectedBalance) in expected {
                let balance = try LocalMoneyQueries.accountBalance(
                    database, accountId: accountId, asOf: "2026-08-13", now: Self.today
                )
                #expect(balance == expectedBalance, "account \(accountId)")
            }
        }
    }

    // MARK: - net_worth(scope) — the money-rule-5 propagation case

    @Test("net_worth propagates a missing GBP rate to nil for 'me'/'total'; 'household' is a clean 0")
    func netWorthMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.read { database in
            let meScope = LocalMoneyScope(scope: .me, baseCurrency: "EUR")
            let householdScope = LocalMoneyScope(scope: .household, baseCurrency: "EUR")
            let totalScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
            let meWorth = try LocalMoneyConversion.netWorth(database, meScope, asOf: "2026-08-13", now: Self.today)
            let householdWorth = try LocalMoneyConversion.netWorth(
                database, householdScope, asOf: "2026-08-13", now: Self.today
            )
            let totalWorth = try LocalMoneyConversion.netWorth(
                database, totalScope, asOf: "2026-08-13", now: Self.today
            )
            #expect(meWorth == nil)
            #expect(householdWorth == 0)
            #expect(totalWorth == nil)
        }
    }

    // MARK: - budget_progress

    @Test("budget_progress: budgeted converts cleanly (EUR-to-EUR), spent is nil (GBP in period)")
    func budgetProgressMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let periodMonth = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 1)) ?? Self.today
        let rows = try dbQueue.read { database in
            try LocalMoneyConversion.budgetProgress(
                database, ownerId: RefereeFixture.ownerId, baseCurrency: "EUR", periodMonth: periodMonth
            )
        }
        #expect(rows.count == 1)
        #expect(rows.first?.budgetedE4 == 1_000_000)
        #expect(rows.first?.spentE4 == nil)
    }
}
