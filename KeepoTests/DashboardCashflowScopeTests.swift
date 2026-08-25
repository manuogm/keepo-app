import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The rule the Cashflow widget's "Transfers" row exists for: a transfer leg
/// counts as real cashflow **only when its counterparty account is outside
/// the scope being viewed**.
///
/// Worth a database test rather than a unit one because the rule is expressed
/// as SQL — a correlated `NOT EXISTS` against the same scope predicate the
/// leg itself is filtered by — and the thing that can go wrong is the
/// predicate, not the Swift around it.
@Suite("Cashflow transfers across a scope boundary")
struct DashboardCashflowScopeTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in try ScopeFixture.seed(database) }
        return dbQueue
    }

    private func totals(_ scope: PublicSchema.AccountScope) throws -> CashflowTotalsLocal {
        let dbQueue = try makeDatabase()
        let day = PostgresDate.dateOnly(from: ScopeFixture.day, calendar: utcCalendar) ?? Date()
        return try dbQueue.read { database in
            try LocalDashboardQueries.cashflow(
                database, LocalMoneyScope(scope: scope, baseCurrency: "EUR"), period: day ... day
            )
        }
    }

    @Test("At Total scope a transfer between two of your own accounts is not cashflow")
    func totalScopeIgnoresInternalTransfers() throws {
        let result = try totals(.total)
        // Salary only — the transfer's two legs cancel and neither shows.
        #expect(result.moneyInE4 == 2_000_000)
        #expect(result.moneyOutE4 == -500_000)
        #expect(result.byCategory.contains { $0.isTransfers } == false)
    }

    @Test("At Personal scope the leg arriving from a household account is real money in")
    func personalScopeCountsInboundLeg() throws {
        let result = try totals(.me)
        // Salary plus the 800,000 that arrived from the shared account.
        #expect(result.moneyInE4 == 2_800_000)
        #expect(result.moneyOutE4 == -500_000)
        let transfers = result.byCategory.filter(\.isTransfers)
        #expect(transfers.count == 1)
        #expect(transfers.first?.amountE4 == 800_000)
        #expect(transfers.first?.name == "Transfers")
    }

    @Test("At Household scope the same movement is the outflow it is from that side")
    func householdScopeCountsOutboundLeg() throws {
        let result = try totals(.household)
        // Nothing else happens on the shared account, so the transfer is the
        // whole of that scope's cashflow.
        #expect(result.moneyInE4 == 0)
        #expect(result.moneyOutE4 == -800_000)
        let transfers = result.byCategory.filter(\.isTransfers)
        #expect(transfers.count == 1)
        #expect(transfers.first?.amountE4 == -800_000)
        #expect(transfers.first?.kind == .expense)
    }

    /// The sentinel is what tells the widget it has no category to open in
    /// Transactions — a real UUID here would send it to a category that
    /// doesn't exist.
    @Test("The transfers roll-up carries a non-UUID id")
    func transfersIdIsNotAUUID() throws {
        let transfers = try totals(.me).byCategory.first { $0.isTransfers }
        #expect(transfers != nil)
        #expect(UUID(uuidString: transfers?.categoryId ?? "") == nil)
    }

    /// A category the user genuinely named "Transfers" must not be mistaken
    /// for the roll-up — the test is the id, never the name.
    @Test("isTransfers is decided by the sentinel id, not the name")
    func transfersIsDecidedById() {
        let impostor = CashflowCategoryLocal(
            categoryId: UUID().uuidString, name: "Transfers", icon: "arrow.left.arrow.right",
            color: "#8E8E93", kind: .expense, amountE4: -100
        )
        #expect(impostor.isTransfers == false)
    }
}

/// The sibling-caching path: one pass over a bucket's transactions answers
/// money in, money out and the net together, and all three have to come back
/// out of `DashboardMetricSeries.load` — the Cashflow chart draws them on one
/// axis, and a missing companion renders as a chart with its bars silently
/// absent.
@Suite("Cashflow series companions")
struct DashboardCashflowSeriesTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        try dbQueue.write { database in try ScopeFixture.seed(database) }
        return dbQueue
    }

    @Test("Loading the net series also files money in and money out")
    func netLoadPopulatesBothSides() async throws {
        let dbQueue = try makeDatabase()
        let july = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 1)) ?? Date()
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 31)) ?? Date()
        let window = SeriesWindow(granularity: .month, from: july, through: now)
        let request = MetricSeriesRequest(
            metric: .cashflowNet, granularity: .month, scope: .total,
            baseCurrency: "EUR", token: Int.random(in: 1 ... 1_000_000)
        )
        let net = try await DashboardMetricSeries.load(
            dbQueue: dbQueue, request: request, window: window, now: now
        )
        #expect(net.first?.amountE4 == 1_500_000)

        let moneyIn = try await DashboardMetricSeries.load(
            dbQueue: dbQueue, request: request.asking(.moneyIn), window: window, now: now
        )
        let moneyOut = try await DashboardMetricSeries.load(
            dbQueue: dbQueue, request: request.asking(.moneyOut), window: window, now: now
        )
        #expect(moneyIn.first?.amountE4 == 2_000_000)
        #expect(moneyOut.first?.amountE4 == -500_000)
    }

    @Test("Cashflow declares both flow sides as companions")
    func cashflowDeclaresCompanions() {
        #expect(DashboardWidgetKind.cashflow.companionMetrics == [.moneyIn, .moneyOut])
        #expect(DashboardWidgetKind.netWorth.companionMetrics.isEmpty)
    }
}
