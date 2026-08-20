import Foundation
import KeepoCore

/// One point on a widget's trend line. A named type rather than the
/// `(date: Date, value: Int64)` tuple the old Home passed around: a tuple of
/// those isn't `Equatable`, so nothing holding one could be diffed, and
/// `DashboardData` below has to be diffable for the dashboard to know when a
/// reload actually changed anything.
struct DashboardSeriesPoint: Equatable, Sendable {
    let date: Date
    let value: Int64
}

/// Everything the mounted widgets need, loaded together. One value, one
/// read, one `@State` — a widget never reaches for the database itself, so
/// adding a sixth widget can't quietly add a sixth round trip on every
/// refresh.
///
/// Every field is optional and means "this widget isn't mounted, or hasn't
/// loaded". A widget with no data renders its blank state; it never renders
/// a zero (money rule 5).
struct DashboardData: Equatable {
    var baseCurrency: CurrencyInfo?
    var netWorth: NetWorthMetrics?
    var upcomingBills: UpcomingBillsMetrics?
    var currencyExposure: CurrencyExposureMetrics?
    var cashflow: CashflowMetrics?
    var investingRatio: InvestingRatioMetrics?
}

/// One complete period's money in and out, and the period before it for the
/// trend badge.
struct CashflowMetrics: Equatable {
    let period: CashflowPeriod
    /// "July", "2025" — the tile always names the window, so a figure is
    /// never left to be guessed at.
    let periodLabel: String
    let totals: CashflowTotalsLocal
    let previousNetE4: Int64?

    var percentChange: Double? {
        DashboardTrend.percentChange(from: previousNetE4, to: totals.netE4)
    }

    /// How far each bar fills, 0-1, against whichever direction was larger.
    /// Scaling both against the same maximum is the point: two bars each
    /// filling their own width would make an income of 100 and an outflow of
    /// 10 look identical.
    func fill(of amountE4: Int64?) -> Double {
        guard let amountE4 else { return 0 }
        let largest = max(abs(totals.moneyInE4 ?? 0), abs(totals.moneyOutE4 ?? 0))
        guard largest > 0 else { return 0 }
        return min(Double(abs(amountE4)) / Double(largest), 1)
    }
}

/// How much of the user's net worth sits in accounts they marked as
/// investments.
struct InvestingRatioMetrics: Equatable {
    let investedE4: Int64?
    let netWorthE4: Int64?
    let previousInvestedE4: Int64?
    let previousNetWorthE4: Int64?
    /// Distinguishes "your investments are 0% of net worth" from "you have no
    /// investment accounts", which need different blank states.
    let hasInvestmentAccounts: Bool

    /// Invested over net worth — assets minus liabilities, per the widget's
    /// own definition.
    ///
    /// `nil` when net worth is zero or negative. A ratio against a negative
    /// denominator flips sign and means nothing; against zero it is
    /// undefined. Money rule 5's shape applies to ratios too — "—", never a
    /// number that looks computed. It can legitimately exceed 100% when
    /// leveraged, and is shown honestly rather than clamped.
    var ratio: Double? { Self.ratio(invested: investedE4, netWorth: netWorthE4) }

    var previousRatio: Double? { Self.ratio(invested: previousInvestedE4, netWorth: previousNetWorthE4) }

    /// The change in **percentage points**, not a relative percentage: going
    /// from 30% to 33% is "+3 pts", and calling that "+10%" would be true of
    /// the ratio and useless to the reader.
    var changeInPoints: Double? {
        guard let ratio, let previousRatio else { return nil }
        return (ratio - previousRatio) * 100
    }

    private static func ratio(invested: Int64?, netWorth: Int64?) -> Double? {
        guard let invested, let netWorth, netWorth > 0 else { return nil }
        return Double(invested) / Double(netWorth)
    }
}

/// One month-end reading of the investing ratio, for the expanded widget's
/// history.
struct InvestingRatioPoint: Equatable, Identifiable {
    let month: Date
    let ratio: Double

    var id: Date { month }
}

/// Every expense occurrence falling inside the widget's window, already
/// scope-filtered and converted.
struct UpcomingBillsMetrics: Equatable {
    let bills: [UpcomingBillLocal]
    let windowDays: Int

    /// Signed, like every amount it sums — negative, because these are
    /// outflows, and `MoneySignStyle.ledger` drops the minus at the display
    /// boundary where the label already says "due". `nil` if any single bill
    /// couldn't be converted: a total that quietly omits one line is worse
    /// than no total (money rule 5).
    var totalE4: Int64? {
        var total: Int64 = 0
        for bill in bills {
            guard let amount = bill.amountBaseE4 else { return nil }
            total += amount
        }
        return total
    }
}

/// What the user's money is held in, by currency.
struct CurrencyExposureMetrics: Equatable {
    /// `nil` means a balance or rate was unresolvable — deliberately distinct
    /// from an empty array, which means the user simply has no accounts yet.
    /// The two need different blank states: one is "we can't work this out
    /// right now", the other is "there is nothing to work out".
    let slices: [CurrencyExposureLocal]?

    /// The donut's slices. Only currencies the user is net *long* in: a share
    /// of a total is meaningless for a currency you are net short in, and a
    /// donut cannot draw a negative wedge. Net-short currencies are still
    /// listed in the expanded view, where they read as what they are.
    var positiveSlices: [CurrencyExposureLocal] {
        (slices ?? []).filter { $0.amountBaseE4 > 0 }
    }

    var positiveTotalE4: Int64 {
        positiveSlices.reduce(0) { $0 + $1.amountBaseE4 }
    }

    var largest: CurrencyExposureLocal? { positiveSlices.first }

    /// The headline share, 0–1. `nil` when there is nothing to take a share
    /// of, rather than a 0% that looks like a real answer.
    var largestShare: Double? {
        guard let largest, positiveTotalE4 > 0 else { return nil }
        return Double(largest.amountBaseE4) / Double(positiveTotalE4)
    }
}

/// The Net Worth widget's figures. `nil` on any of the three propagates a
/// missing FX rate all the way to "—" rather than collapsing to a number
/// that looks real.
struct NetWorthMetrics: Equatable {
    let current: Int64?
    let previousMonth: Int64?
    let series: [DashboardSeriesPoint]

    var percentChange: Double? {
        DashboardTrend.percentChange(from: previousMonth, to: current)
    }

    /// Whether there is a trajectory worth drawing at all — the widget draws
    /// no chart rather than a misleading one, per its own spec ("do not
    /// display a completely empty widget or a flat trend line").
    ///
    /// Three points, not two. Two points can only ever render as a single
    /// straight segment, which carries no more information than the trend
    /// badge already above it while looking exactly like a real chart. A
    /// series whose values never change is the literal flat line the spec
    /// rules out. Both are common early on, and both come up honestly: a day
    /// whose total can't be converted is dropped rather than zeroed, so a
    /// user whose FX history is younger than the window genuinely has only a
    /// few plottable days.
    var hasTrajectory: Bool {
        series.count >= 3 && Set(series.map(\.value)).count > 1
    }
}

// MARK: - Catalogue preview data

extension DashboardData {
    /// The figures the catalogue's previews render. Not test data and not
    /// `#if DEBUG` — the catalogue ships, and a preview has to show a widget
    /// carrying plausible numbers or it tells the user nothing about what
    /// they are choosing.
    ///
    /// Deliberately generic and obviously round: a preview that looked like
    /// the user's own money would be worse than one that clearly doesn't,
    /// because on an empty dashboard they could not tell the two apart.
    static let sample = DashboardData(
        baseCurrency: CurrencyInfo(code: "EUR", minorUnit: 2),
        netWorth: NetWorthMetrics(
            current: 481_200_000,
            previousMonth: 456_000_000,
            series: sampleSeries
        ),
        upcomingBills: UpcomingBillsMetrics(bills: sampleBills, windowDays: 14),
        currencyExposure: CurrencyExposureMetrics(slices: [
            CurrencyExposureLocal(currency: "EUR", amountBaseE4: 312_000_000),
            CurrencyExposureLocal(currency: "USD", amountBaseE4: 121_000_000),
            CurrencyExposureLocal(currency: "GBP", amountBaseE4: 48_200_000)
        ]),
        cashflow: CashflowMetrics(
            period: .month, periodLabel: "Last month",
            totals: CashflowTotalsLocal(
                moneyInE4: 38_400_000, moneyOutE4: -26_150_000, byCategory: sampleCashflowCategories
            ),
            previousNetE4: 10_800_000
        ),
        investingRatio: InvestingRatioMetrics(
            investedE4: 173_000_000, netWorthE4: 481_200_000,
            previousInvestedE4: 158_000_000, previousNetWorthE4: 456_000_000,
            hasInvestmentAccounts: true
        )
    )

    private static var sampleCashflowCategories: [CashflowCategoryLocal] {
        [
            category("Salary", "banknote.fill", "#34C759", .income, 38_400_000),
            category("Rent", "house.fill", "#007AFF", .expense, -12_000_000),
            category("Groceries", "cart.fill", "#FF9500", .expense, -6_400_000),
            category("Dining", "fork.knife", "#FF2D55", .expense, -4_250_000),
            category("Transport", "car.fill", "#5856D6", .expense, -3_500_000)
        ]
    }

    private static func category(
        _ name: String, _ icon: String, _ color: String,
        _ kind: PublicSchema.CategoryKind, _ amountE4: Int64
    ) -> CashflowCategoryLocal {
        CashflowCategoryLocal(
            categoryId: name, name: name, icon: icon, color: color, kind: kind, amountE4: amountE4
        )
    }

    private static var sampleBills: [UpcomingBillLocal] {
        let today = Date()
        return [
            bill(inDays: 2, "Rent", "house.fill", "#007AFF", "Current Account", -120_000_000, from: today),
            bill(inDays: 5, "Internet", "bolt.fill", "#FF9500", "Current Account", -4_500_000, from: today),
            bill(inDays: 9, "Gym", "figure.run", "#34C759", "Current Account", -3_900_000, from: today),
            bill(inDays: 12, "Streaming", "gamecontroller.fill", "#AF52DE", "Credit Card", -1_599_000, from: today)
        ]
    }

    // swiftlint:disable:next function_parameter_count
    private static func bill(
        inDays days: Int, _ name: String, _ icon: String, _ color: String, _ account: String,
        _ amountE4: Int64, from today: Date
    ) -> UpcomingBillLocal {
        UpcomingBillLocal(
            ruleId: name, dueOn: today.addingTimeInterval(Double(days) * 86_400),
            categoryName: name, categoryIcon: icon, categoryColor: color, accountName: account,
            amountBaseE4: amountE4, nativeAmountE4: amountE4, nativeCurrency: "EUR"
        )
    }

    /// Twelve weeks climbing with a dip in the middle — a shape, rather than
    /// a straight line, so the preview shows what the chart actually does.
    private static var sampleSeries: [DashboardSeriesPoint] {
        let values: [Int64] = [
            412_000_000, 419_500_000, 427_000_000, 424_000_000, 433_500_000, 441_000_000,
            438_000_000, 449_000_000, 457_500_000, 462_000_000, 471_000_000, 481_200_000
        ]
        let start = Date().addingTimeInterval(-Double(values.count - 1) * 7 * 86_400)
        return values.enumerated().map {
            DashboardSeriesPoint(
                date: start.addingTimeInterval(Double($0.offset) * 7 * 86_400), value: $0.element
            )
        }
    }
}
