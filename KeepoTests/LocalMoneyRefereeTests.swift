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

    @Test("unrealized_gain matches Postgres — snapshot minus every transfer ever, no date bound")
    func unrealizedGainMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let gain = try dbQueue.read { database in
            try LocalMoneyQueries.unrealizedGain(database, accountId: RefereeFixture.eurBrokerage)
        }
        #expect(gain == 40_000_000)
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

    // MARK: - spending_by_category

    @Test("spending_by_category: one GBP row poisons the whole Groceries total to nil")
    func spendingByCategoryMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let moneyScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let results = try dbQueue.read { database in
            try LocalMoneyConversion.spendingByCategory(database, moneyScope, from: "2026-07-01", through: "2026-08-13")
        }
        #expect(results.count == 1)
        #expect(results.first?.categoryId == RefereeFixture.groceries)
        #expect(results.first?.totalE4 == nil)
    }

    // MARK: - income_expense_series

    @Test("income_expense_series weekly matches Postgres's 4 buckets exactly, including the GBP-poisoned week")
    func incomeExpenseSeriesWeeklyMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let moneyScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let points = try dbQueue.read { database in
            try LocalMoneyConversion.incomeExpenseSeries(
                database, moneyScope, from: "2026-07-01", through: "2026-08-13", granularity: "weekly"
            )
        }
        let byBucket = Dictionary(uniqueKeysWithValues: points.map { ($0.bucketStart, $0) })
        #expect(points.count == 4)
        #expect(byBucket["2026-06-29"]?.incomeE4 == 0)
        #expect(byBucket["2026-06-29"]?.expenseE4 == 500_000)
        #expect(byBucket["2026-07-06"]?.incomeE4 == 20_000_000)
        #expect(byBucket["2026-07-06"]?.expenseE4 == nil)
        #expect(byBucket["2026-07-27"]?.incomeE4 == 0)
        #expect(byBucket["2026-07-27"]?.expenseE4 == 120_000)
        #expect(byBucket["2026-08-03"]?.incomeE4 == 21_000_000)
        #expect(byBucket["2026-08-03"]?.expenseE4 == 0)
    }

    @Test("income_expense_series monthly matches Postgres's 2 buckets exactly")
    func incomeExpenseSeriesMonthlyMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let moneyScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let points = try dbQueue.read { database in
            try LocalMoneyConversion.incomeExpenseSeries(
                database, moneyScope, from: "2026-07-01", through: "2026-08-13", granularity: "monthly"
            )
        }
        let byBucket = Dictionary(uniqueKeysWithValues: points.map { ($0.bucketStart, $0) })
        #expect(points.count == 2)
        #expect(byBucket["2026-07-01"]?.incomeE4 == 20_000_000)
        #expect(byBucket["2026-07-01"]?.expenseE4 == nil)
        #expect(byBucket["2026-08-01"]?.incomeE4 == 21_000_000)
        #expect(byBucket["2026-08-01"]?.expenseE4 == 120_000)
    }

    // MARK: - savings_rate

    @Test("savings_rate is nil — the same GBP-poisoned expense side")
    func savingsRateMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let moneyScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let rate = try dbQueue.read { database in
            try LocalMoneyConversion.savingsRate(database, moneyScope, from: "2026-07-01", through: "2026-08-13")
        }
        #expect(rate == nil)
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

    // MARK: - fi_metrics

    @Test("fi_metrics: every field nil once the trailing-365-day window includes the GBP transaction")
    func fiMetricsMatchesPostgres() throws {
        let dbQueue = try makeDatabase()
        let moneyScope = LocalMoneyScope(scope: .total, baseCurrency: "EUR")
        let metrics = try dbQueue.read { database in
            try LocalMoneyConversion.fiMetrics(database, ownerId: RefereeFixture.ownerId, moneyScope, today: Self.today)
        }
        #expect(metrics.annualSpendE4 == nil)
        #expect(metrics.fiNumberE4 == nil)
        #expect(metrics.currentNetWorthE4 == nil)
        #expect(metrics.percentProgress == nil)
        #expect(metrics.annualSavingsE4 == nil)
        #expect(metrics.yearsToFi == nil)
        #expect(metrics.coastFiNumberE4 == nil)
    }
}
