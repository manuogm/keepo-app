import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The derivations behind Currency Exposure and the Upcoming widget — the
/// rules that decide whether a share, a total, or a count is honest enough to
/// draw.
@Suite("Widget metrics")
struct DashboardWidgetMetricsTests {
    // MARK: - Currency exposure

    private func account(_ name: String, _ amountE4: Int64, currency: String = "EUR") -> CurrencyAccountLocal {
        CurrencyAccountLocal(
            accountId: name, name: name, icon: "banknote", color: "#8E8E93",
            currencyInfo: CurrencyInfo(code: currency, minorUnit: 2),
            amountBaseE4: amountE4, nativeAmountE4: amountE4
        )
    }

    private func slice(_ code: String, _ accounts: [CurrencyAccountLocal]) -> CurrencyExposureLocal {
        CurrencyExposureLocal(
            currency: code, amountBaseE4: accounts.reduce(0) { $0 + $1.amountBaseE4 }, accounts: accounts
        )
    }

    /// A currency's shares are read against what is actually *held*, not
    /// against the net. €1,000 of savings offset by a −€900 card is a €100
    /// net, and calling the savings account "1,000% of EUR" would be
    /// arithmetically true and useless.
    @Test("An account's share is taken against the positive accounts, not the net")
    func accountShareUsesPositiveTotal() {
        let eur = slice("EUR", [account("Savings", 10_000_000), account("Card", -9_000_000)])
        #expect(eur.amountBaseE4 == 1_000_000)
        #expect(eur.positiveTotalE4 == 10_000_000)
        #expect(eur.positiveAccounts.count == 1)
    }

    @Test("A net-short currency has no share, rather than a negative one")
    func netShortCurrencyHasNoShare() {
        let metrics = CurrencyExposureMetrics(slices: [
            slice("EUR", [account("Savings", 10_000_000)]),
            slice("USD", [account("Card", -2_000_000, currency: "USD")])
        ])
        #expect(metrics.positiveSlices.count == 1)
        #expect(metrics.netShortSlices.map(\.currency) == ["USD"])
        #expect(metrics.share(of: metrics.netShortSlices.first) == nil)
        #expect(metrics.largestShare == 1)
    }

    /// Money rule 5's shape applied to a ratio — nothing to take a share of
    /// is "—", never 0%.
    @Test("No positive holdings leaves every share uncomputable")
    func noHoldingsLeavesShareNil() {
        let metrics = CurrencyExposureMetrics(slices: [slice("EUR", [account("Card", -500)])])
        #expect(metrics.largestShare == nil)
        #expect(metrics.largest == nil)
    }

    @Test("An unresolvable exposure is nil throughout, not an empty breakdown")
    func unresolvableExposureIsNil() {
        let metrics = CurrencyExposureMetrics(slices: nil)
        #expect(metrics.positiveSlices.isEmpty)
        #expect(metrics.largestShare == nil)
    }

    // MARK: - Upcoming transactions

    private func upcoming(_ amountE4: Int64?, inDays days: Int, native: Int64) -> UpcomingTransactionLocal {
        let today = utcCalendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        return UpcomingTransactionLocal(
            ruleId: "\(days)", dueOn: utcCalendar.date(byAdding: .day, value: days, to: today) ?? today,
            categoryName: "X", categoryIcon: "cart", categoryColor: "#FF0000", accountName: "A",
            amountBaseE4: amountE4, nativeAmountE4: native, nativeCurrency: "EUR"
        )
    }

    private var referenceToday: Date {
        utcCalendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The headline is a **net**, which is the whole reason the widget stopped
    /// being expense-only: a fortnight holding a salary can be positive, and
    /// the old version could not say so.
    @Test("The window's total is the net of both directions")
    func totalIsSigned() {
        let metrics = UpcomingTransactionsMetrics(
            items: [upcoming(-1_200_000, inDays: 2, native: -1_200_000),
                    upcoming(3_840_000, inDays: 6, native: 3_840_000)],
            windowDays: 14
        )
        #expect(metrics.totalE4 == 2_640_000)
        #expect(metrics.inboundCount == 1)
        #expect(metrics.outboundCount == 1)
    }

    /// Money rule 5 — one unconvertible line makes the total unknowable, not
    /// smaller. A total that quietly omits a row is worse than no total.
    @Test("One unresolvable item leaves the whole total uncomputable")
    func oneMissingRateLeavesTotalNil() {
        let metrics = UpcomingTransactionsMetrics(
            items: [upcoming(-1_200_000, inDays: 2, native: -1_200_000),
                    upcoming(nil, inDays: 6, native: 3_840_000)],
            windowDays: 14
        )
        #expect(metrics.totalE4 == nil)
        // Direction still reads off the native amount, so the counts survive
        // a missing rate.
        #expect(metrics.inboundCount == 1)
    }

    @Test("The carousel covers every day of the window, including empty ones")
    func daysCoverTheWholeWindow() {
        let metrics = UpcomingTransactionsMetrics(
            items: [upcoming(-100, inDays: 3, native: -100)], windowDays: 14
        )
        let days = metrics.days(from: referenceToday, calendar: utcCalendar)
        #expect(days.count == 14)
        #expect(days.first == referenceToday)
        #expect(metrics.items(on: days[3], calendar: utcCalendar).count == 1)
        #expect(metrics.items(on: days[4], calendar: utcCalendar).isEmpty)
    }

    /// Every occurrence has a circle to land on. The window used to run one
    /// day past the fourteen the carousel draws, so a bill on the last day
    /// had nowhere to appear.
    @Test("The last day of the window is inside the carousel")
    func lastDayIsCovered() {
        let metrics = UpcomingTransactionsMetrics(
            items: [upcoming(-100, inDays: 13, native: -100)], windowDays: 14
        )
        let days = metrics.days(from: referenceToday, calendar: utcCalendar)
        #expect(metrics.items(on: days[13], calendar: utcCalendar).count == 1)
    }

    // MARK: - Series requests

    /// How one read files the siblings it computed along the way. Everything
    /// but the metric has to survive, or the cache would answer a different
    /// scope's question.
    @Test("Asking a request for another metric changes only the metric")
    func askingChangesOnlyTheMetric() {
        let request = MetricSeriesRequest(
            metric: .cashflowNet, granularity: .month, scope: .me,
            baseCurrency: "EUR", quoteCurrency: "USD", token: 7
        )
        let sibling = request.asking(.moneyIn)
        #expect(sibling.metric == .moneyIn)
        #expect(sibling.granularity == request.granularity)
        #expect(sibling.scope == request.scope)
        #expect(sibling.baseCurrency == request.baseCurrency)
        #expect(sibling.quoteCurrency == request.quoteCurrency)
        #expect(sibling.token == request.token)
        #expect(sibling != request)
    }
}
