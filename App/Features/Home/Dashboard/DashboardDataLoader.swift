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
    /// How far back the collapsed Net Worth trajectory looks — **the same
    /// twelve buckets the expanded widget opens on**
    /// (`SeriesWidgetState.visibleBuckets`), so the tile's little line is a
    /// small copy of the chart it becomes rather than a different picture of
    /// the same money.
    ///
    /// It used to be 90 *days*, walked one day at a time. That made the two
    /// states visibly disagree — a jagged three-month line collapsed, a
    /// smooth twelve-month one expanded — and it recomputed every account's
    /// balance ninety times on every dashboard refresh. Twelve month-end
    /// readings are the same answer at the resolution the chart actually
    /// draws, and cost a seventh of the work.
    static let netWorthTrendMonths = 12

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
            // Always, not gated on `kinds`: the catalogue needs these to
            // explain why a widget the user does not yet have is disabled.
            data.capabilities = DashboardCapabilities(
                hasInvestmentAccounts: try LocalDashboardQueries.investmentAccountCount(
                    database, scope: moneyScope.scope
                ) > 0,
                foreignCurrencies: try LocalDashboardQueries.heldCurrencies(
                    database, scope: moneyScope.scope, excluding: baseCurrency
                )
            )
            if kinds.contains(.netWorth) {
                data.netWorth = try netWorthMetrics(database, moneyScope, now: now)
            }
            if kinds.contains(.upcomingBills) {
                data.upcomingBills = try upcomingMetrics(database, moneyScope, now: now)
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

    /// One set of month-end readings answers all three of the collapsed
    /// tile's questions.
    ///
    /// The figure, the badge and the trajectory used to be computed three
    /// different ways — today's balance, the balance on this day last month,
    /// and ninety daily points bucketed after the fact. So the collapsed
    /// badge compared *today against the same day last month* while the
    /// expanded one compared *this month-end against last month-end*, and
    /// the two states could disagree about which way net worth had gone.
    ///
    /// Now every one of them is a bucket out of this array, and the buckets
    /// are built by `MetricGranularity` from the same `evaluationDate` rule
    /// `DashboardMetricSeries` uses for the expanded chart — the current
    /// bucket clamped to today, so "this month" means "so far this month" in
    /// both places. The two states cannot drift, because there is one
    /// definition.
    private static func netWorthMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> NetWorthMetrics {
        let readings = try monthEndNetWorth(database, moneyScope, months: netWorthTrendMonths, now: now)
        return NetWorthMetrics(
            current: readings.last?.totalE4 ?? nil,
            previousMonth: readings.count >= 2 ? readings[readings.count - 2].totalE4 : nil,
            // A bucket whose total can't be resolved is dropped, never zeroed
            // — a missing FX rate must not draw as a dip to the axis (money
            // rule 5).
            series: readings.compactMap { reading in
                reading.totalE4.map { DashboardSeriesPoint(date: reading.bucket, value: $0) }
            }
        )
    }

    /// Net worth at the end of each of the last `months` months, newest last.
    /// The current month reads as of today rather than as of a date that
    /// hasn't happened.
    private static func monthEndNetWorth(
        _ database: Database, _ moneyScope: LocalMoneyScope, months: Int, now: Date
    ) throws -> [(bucket: Date, totalE4: Int64?)] {
        let start = utcCalendar.date(byAdding: .month, value: -(months - 1), to: now) ?? now
        let buckets = MetricGranularity.month.buckets(from: start, through: now, calendar: utcCalendar)
        return try buckets.map { bucket in
            let asOf = MetricGranularity.month.evaluationDate(forBucket: bucket, now: now, calendar: utcCalendar)
            return (
                bucket: bucket,
                totalE4: try LocalMoneyConversion.netWorth(
                    database, moneyScope, asOf: PostgresDate.dateOnlyString(asOf, calendar: utcCalendar), now: now
                )
            )
        }
    }

    private static func upcomingMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, now: Date
    ) throws -> UpcomingTransactionsMetrics {
        // The window opens *today*, not at this instant: a bill due today is
        // still due today at 11pm. Both bounds are calendar days in UTC, the
        // same zone every other date comparison in this app works in.
        //
        // `billsWindowDays - 1` because both bounds are inclusive: fourteen
        // days counting today is today plus thirteen. The old bound was one
        // day wider than the "next 14 days" the widget's title promises, and
        // the carousel — which draws exactly `windowDays` circles — would
        // have had an occurrence with no circle to land on.
        let start = utcCalendar.startOfDay(for: now)
        let end = utcCalendar.date(byAdding: .day, value: billsWindowDays - 1, to: start) ?? start
        return UpcomingTransactionsMetrics(
            items: try LocalDashboardQueries.upcomingTransactions(
                database, moneyScope, window: start ... end, now: now
            ),
            windowDays: billsWindowDays
        )
    }

    /// The last complete period's figures plus the period before it — what
    /// the collapsed Cashflow tile reads.
    ///
    /// Only ever the *default* window now. The Month/Year switch this used to
    /// serve on demand is gone: the expanded widget charts a scrollable
    /// series through `DashboardMetricSeries` and breaks down whichever
    /// bucket is highlighted, so there is no second preloaded window to
    /// choose between.
    static func cashflowMetrics(
        _ database: Database, _ moneyScope: LocalMoneyScope, period: CashflowPeriod, now: Date
    ) throws -> CashflowMetrics {
        let bounds = period.bounds(now: now, calendar: utcCalendar)
        let previous = period.previousBounds(now: now, calendar: utcCalendar)
        return CashflowMetrics(
            periodLabel: period.label(now: now, calendar: utcCalendar),
            totals: try LocalDashboardQueries.cashflow(database, moneyScope, period: bounds),
            previousNetE4: try LocalDashboardQueries.cashflow(database, moneyScope, period: previous).netE4
        )
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
            investmentAccountCount: try LocalDashboardQueries.investmentAccountCount(
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
}
