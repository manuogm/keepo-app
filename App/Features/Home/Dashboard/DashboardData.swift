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
    var upcomingBills: UpcomingTransactionsMetrics?
    var currencyExposure: CurrencyExposureMetrics?
    var cashflow: CashflowMetrics?
    var investingRatio: InvestingRatioMetrics?
    /// What the user's accounts make possible, regardless of which widgets
    /// are mounted. Always loaded — unlike every field above, which is
    /// skipped when its widget isn't on the dashboard — because the
    /// catalogue has to say why a widget can't be added *before* it is
    /// added.
    var capabilities: DashboardCapabilities?
}

/// The two facts the catalogue needs about a user's accounts to know which
/// widgets have anything to say to them.
///
/// Both are cheap: one `COUNT` and one `DISTINCT` over `accounts`, no
/// balances and no FX. That is what makes it reasonable to load them on
/// every refresh rather than only when the catalogue opens.
struct DashboardCapabilities: Equatable {
    let hasInvestmentAccounts: Bool
    /// Currencies the user holds an account in, other than their base one —
    /// which is exactly what the FX widget can quote. Empty means that
    /// widget has nothing to price.
    let foreignCurrencies: [String]

    /// Why each widget can't be added, or nothing if it can. Absent from
    /// the dictionary means available; `alreadyPlaced` is folded in by the
    /// caller, which is the only one that knows the arrangement.
    func unavailability(for kind: DashboardWidgetKind) -> String? {
        switch kind {
        case .investingRatio:
            return hasInvestmentAccounts ? nil : "Mark an account as an investment to use this."
        case .fxRate:
            return foreignCurrencies.isEmpty ? "Add an account in another currency to use this." : nil
        case .netWorth, .currencyExposure, .upcomingBills, .cashflow:
            return nil
        }
    }
}

/// One complete period's money in and out, and the period before it for the
/// trend badge.
struct CashflowMetrics: Equatable {
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
    /// How many accounts the user has marked as investments. The collapsed
    /// tile names it under the figure — a ratio is a share of something, and
    /// "48% across 3 accounts" is a different picture from "48%" in one.
    let investmentAccountCount: Int

    /// Distinguishes "your investments are 0% of net worth" from "you have no
    /// investment accounts", which need different blank states.
    var hasInvestmentAccounts: Bool { investmentAccountCount > 0 }

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

/// Every recurring occurrence falling inside the widget's window, already
/// scope-filtered and converted — money going out and money coming in.
struct UpcomingTransactionsMetrics: Equatable {
    let items: [UpcomingTransactionLocal]
    let windowDays: Int

    /// The **net** of the window: what the fortnight is actually going to do
    /// to the balance. Signed, like every amount it sums — a fortnight with a
    /// salary in it can legitimately be positive. `nil` if any single item
    /// couldn't be converted: a total that quietly omits one line is worse
    /// than no total (money rule 5).
    var totalE4: Int64? {
        var total: Int64 = 0
        for item in items {
            guard let amount = item.amountBaseE4 else { return nil }
            total += amount
        }
        return total
    }

    var inboundCount: Int { items.count { $0.isInbound } }
    var outboundCount: Int { items.count { !$0.isInbound } }

    /// The window's days in order, starting today — every one of them, not
    /// just the ones with something on them. The carousel is a **calendar**:
    /// a fortnight with two payments in it should read as mostly empty, which
    /// it can't if the empty days aren't drawn.
    func days(from today: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: today)
        return (0 ..< windowDays).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func items(on day: Date, calendar: Calendar) -> [UpcomingTransactionLocal] {
        items.filter { calendar.isDate($0.dueOn, inSameDayAs: day) }
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

    /// Currencies the user owes more of than they hold — a card with no
    /// assets behind it in that currency. They get their own section in the
    /// expanded widget, below a divider, with the amount and no share: a
    /// share of a positive total is undefined for a negative position, and
    /// showing "−4%" would invite reading it as a small slice rather than as
    /// a debt.
    var netShortSlices: [CurrencyExposureLocal] {
        (slices ?? []).filter { $0.amountBaseE4 <= 0 }
    }

    var largest: CurrencyExposureLocal? { positiveSlices.first }

    /// The headline share, 0–1. `nil` when there is nothing to take a share
    /// of, rather than a 0% that looks like a real answer.
    var largestShare: Double? { share(of: largest) }

    /// One currency's share of everything held, 0–1. `nil` for a net-short
    /// currency and when there is no positive total — money rule 5's shape
    /// applied to a ratio.
    func share(of slice: CurrencyExposureLocal?) -> Double? {
        guard let slice, slice.amountBaseE4 > 0, positiveTotalE4 > 0 else { return nil }
        return Double(slice.amountBaseE4) / Double(positiveTotalE4)
    }

    /// Several currencies' share, taken together — what the collapsed tile's
    /// "REST" roll-up stands for once there are more of them than the row can
    /// name. Net-short currencies are excluded for the same reason they are
    /// excluded from `share(of:)`: they are not part of what is held.
    func share(ofCombined slices: [CurrencyExposureLocal]) -> Double? {
        guard positiveTotalE4 > 0 else { return nil }
        let held = slices.filter { $0.amountBaseE4 > 0 }.reduce(0) { $0 + $1.amountBaseE4 }
        guard held > 0 else { return nil }
        return Double(held) / Double(positiveTotalE4)
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
