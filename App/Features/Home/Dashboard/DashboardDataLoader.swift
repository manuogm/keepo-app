import Foundation
import GRDB
import KeepoCore

/// The dashboard's single read. Every mounted widget's figures are computed
/// inside one `dbQueue.read`, off the main actor, and handed back as one
/// value — the alternative (each widget loading itself) means N concurrent
/// reads and N sets of the same currency/account lookups on every scope
/// change, which is precisely how this screen would come to feel laggy.
///
/// `kinds` is the mounted set: a widget the user has removed costs nothing,
/// so the dashboard's load time scales with what is actually on screen
/// rather than with everything the catalogue offers.
enum DashboardDataLoader {
    /// How far back the collapsed trend lines look. Long enough to have a
    /// shape, short enough that the per-day recomputation stays cheap; the
    /// expanded Net Worth widget asks for its own range separately, only
    /// once it is actually expanded.
    static let trendRangeDays = 90

    /// The Upcoming Bills window — "the next two weeks", per its own spec.
    static let billsWindowDays = 14

    static func load(
        dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope, baseCurrency: String,
        kinds: Set<DashboardWidgetKind>, now: Date = Date()
    ) async throws -> DashboardData {
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        return try await dbQueue.read { database in
            var data = DashboardData()
            let currencies = try LocalTableQueries.currencies(database)
            if let row = currencies.first(where: { $0.code == baseCurrency }) {
                data.baseCurrency = CurrencyInfo(code: row.code, minorUnit: Int(row.minorUnit))
            }
            if kinds.contains(.netWorth) {
                data.netWorth = try netWorthMetrics(database, moneyScope, now: now)
            }
            if kinds.contains(.upcomingBills) {
                data.upcomingBills = try billsMetrics(database, moneyScope, now: now)
            }
            if kinds.contains(.cashflow) {
                data.cashflow = try cashflowMetrics(database, moneyScope, period: .month, now: now)
            }
            if kinds.contains(.investingRatio) {
                data.investingRatio = try investingRatioMetrics(database, moneyScope, now: now)
            }
            if kinds.contains(.currencyExposure) {
                data.currencyExposure = CurrencyExposureMetrics(
                    slices: try LocalDashboardQueries.currencyExposure(database, moneyScope, now: now)
                )
            }
            return data
        }
    }

    private static func netWorthMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> NetWorthMetrics {
        let today = PostgresDate.dateOnlyString(now, calendar: utcCalendar)
        let monthAgo = utcCalendar.date(byAdding: .month, value: -1, to: now) ?? now
        let from = utcCalendar.date(byAdding: .day, value: -(trendRangeDays - 1), to: now) ?? now

        return NetWorthMetrics(
            current: try LocalMoneyConversion.netWorth(database, moneyScope, asOf: today, now: now),
            previousMonth: try LocalMoneyConversion.netWorth(
                database, moneyScope, asOf: PostgresDate.dateOnlyString(monthAgo, calendar: utcCalendar), now: now
            ),
            series: try series(database, moneyScope, from: from, through: now)
        )
    }

    private static func billsMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> UpcomingBillsMetrics {
        // The window opens *today*, not at this instant: a bill due today is
        // still due today at 11pm. Both bounds are calendar days in UTC, the
        // same zone every other date comparison in this app works in.
        let start = utcCalendar.startOfDay(for: now)
        let end = utcCalendar.date(byAdding: .day, value: billsWindowDays, to: start) ?? start
        return UpcomingBillsMetrics(
            bills: try LocalDashboardQueries.upcomingBills(database, moneyScope, window: start ... end, now: now),
            windowDays: billsWindowDays
        )
    }

    /// One period's figures plus the period before it. Used both inline
    /// above (for the widget's default window) and on demand below when the
    /// user switches Month/Year — one implementation, so the two windows
    /// cannot disagree about what "money in" means.
    static func cashflowMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, period: CashflowPeriod, now: Date
    ) throws -> CashflowMetrics {
        let bounds = period.bounds(now: now, calendar: utcCalendar)
        let previous = period.previousBounds(now: now, calendar: utcCalendar)
        return CashflowMetrics(
            period: period,
            periodLabel: period.label(now: now, calendar: utcCalendar),
            totals: try LocalDashboardQueries.cashflow(database, moneyScope, period: bounds),
            previousNetE4: try LocalDashboardQueries.cashflow(database, moneyScope, period: previous).netE4
        )
    }

    /// The Cashflow widget's Month/Year switch — its own read, so a window
    /// the user never opens is never scanned.
    static func cashflow(
        dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope, baseCurrency: String,
        period: CashflowPeriod, now: Date = Date()
    ) async throws -> CashflowMetrics {
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        return try await dbQueue.read { database in
            try cashflowMetrics(database, moneyScope, period: period, now: now)
        }
    }

    private static func investingRatioMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> InvestingRatioMetrics {
        let today = PostgresDate.dateOnlyString(now, calendar: utcCalendar)
        let monthAgo = utcCalendar.date(byAdding: .month, value: -1, to: now) ?? now
        let monthAgoString = PostgresDate.dateOnlyString(monthAgo, calendar: utcCalendar)
        return InvestingRatioMetrics(
            investedE4: try LocalDashboardQueries.investedTotal(database, moneyScope, asOf: today, now: now),
            netWorthE4: try LocalMoneyConversion.netWorth(database, moneyScope, asOf: today, now: now),
            previousInvestedE4: try LocalDashboardQueries.investedTotal(
                database, moneyScope, asOf: monthAgoString, now: now
            ),
            previousNetWorthE4: try LocalMoneyConversion.netWorth(
                database, moneyScope, asOf: monthAgoString, now: now
            ),
            hasInvestmentAccounts: try LocalDashboardQueries.hasInvestmentAccounts(
                database, scope: moneyScope.scope
            )
        )
    }

    /// The expanded Investing Ratio widget's history — one reading per
    /// month-end. Lazy, and deliberately so: this recomputes every account's
    /// balance once per month in the window, which is the most expensive
    /// thing on the dashboard and is only worth paying for when the widget
    /// is actually open.
    static func investingRatioHistory(
        dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope, baseCurrency: String,
        months: Int = 12, now: Date = Date()
    ) async throws -> [InvestingRatioPoint] {
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        return try await dbQueue.read { database in
            var points: [InvestingRatioPoint] = []
            for step in stride(from: months, through: 1, by: -1) {
                guard let monthStart = utcCalendar.date(byAdding: .month, value: -(step - 1), to: monthStart(now)),
                      let asOf = monthEnd(monthStart, now: now)
                else { continue }
                let asOfString = PostgresDate.dateOnlyString(asOf, calendar: utcCalendar)
                guard let invested = try LocalDashboardQueries.investedTotal(
                    database, moneyScope, asOf: asOfString, now: now
                ), let netWorth = try LocalMoneyConversion.netWorth(
                    database, moneyScope, asOf: asOfString, now: now
                ), netWorth > 0 else { continue }
                points.append(
                    InvestingRatioPoint(month: monthStart, ratio: Double(invested) / Double(netWorth))
                )
            }
            return points
        }
    }

    private static func monthStart(_ date: Date) -> Date {
        utcCalendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// The last day of `monthStart`'s month, or today when that month is the
    /// current one — a reading dated in the future would just repeat today's
    /// number under next month's label.
    private static func monthEnd(_ monthStart: Date, now: Date) -> Date? {
        guard let nextMonth = utcCalendar.date(byAdding: .month, value: 1, to: monthStart),
              let lastDay = utcCalendar.date(byAdding: .day, value: -1, to: nextMonth)
        else { return nil }
        return min(lastDay, now)
    }

    /// The expanded Currency Exposure widget's own trend load — lazy for the
    /// same reason the net-worth range is: a currency the user never selects
    /// is never walked day by day.
    static func fxTrend(
        dbQueue: DatabaseQueue, currency: String, baseCurrency: String, from: Date, through: Date
    ) async throws -> [DashboardSeriesPoint] {
        try await dbQueue.read { database in
            let points = try LocalDashboardQueries.fxTrend(
                database, currency: currency, baseCurrency: baseCurrency, from: from, through: through
            )
            let granularity = DateBucketing.granularity(from: from, through: through)
            return DateBucketing.bucket(points, granularity: granularity)
                .map { DashboardSeriesPoint(date: $0.date, value: $0.value) }
        }
    }

    /// The expanded Net Worth widget's own range load — deliberately its own
    /// call rather than part of `load` above, so a range the user never
    /// opens is never computed. Same bucketing rule as everywhere else:
    /// granularity is derived from the span, never a user control
    /// (app-architecture.md §5).
    static func netWorthSeries(
        dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope, baseCurrency: String,
        from: Date, through: Date
    ) async throws -> [DashboardSeriesPoint] {
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        return try await dbQueue.read { database in
            try series(database, moneyScope, from: from, through: through)
        }
    }

    private static func series(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: Date, through: Date
    ) throws -> [DashboardSeriesPoint] {
        let points = try LocalMoneyConversion.netWorthSeries(
            database, moneyScope,
            from: PostgresDate.dateOnlyString(from, calendar: utcCalendar),
            through: PostgresDate.dateOnlyString(through, calendar: utcCalendar),
            now: through
        )
        // A day whose total can't be resolved is dropped, not zeroed — a
        // missing FX rate must never draw as a dip to the axis (money rule 5).
        let parsed: [(date: Date, value: Int64)] = points.compactMap { point in
            guard let date = PostgresDate.dateOnly(from: point.asOf, calendar: utcCalendar),
                  let total = point.totalE4
            else { return nil }
            return (date: date, value: total)
        }
        let granularity = DateBucketing.granularity(from: from, through: through)
        return DateBucketing.bucket(parsed, granularity: granularity)
            .map { DashboardSeriesPoint(date: $0.date, value: $0.value) }
    }
}
