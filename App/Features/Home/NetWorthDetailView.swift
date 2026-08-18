import KeepoCore
import SwiftUI

/// Pushed from the Dashboard's net-worth card — the same balance/series data
/// `HomeView` already loads, shown with full axes instead of the card's
/// compact axis-free chart.
struct NetWorthDetailView: View {
    let session: SessionStore

    @State private var netWorth: Int64?
    @State private var previousMonthNetWorth: Int64?
    @State private var seriesPoints: [(date: Date, value: Int64)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let rangeDays = 90

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        BalanceHeaderView(amount: netWorth, currency: baseCurrencyInfo)
                        TrendBadge(percentChange: monthOverMonthChange, color: trendColor)
                        NetWorthChartView(
                            seriesPoints: seriesPoints, showAxes: true, height: 320, trendColor: trendColor
                        )
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: NetWorthLoadKey(token: session.refresh.token, scope: session.scope)) { await load() }
    }

    /// nil when either side can't be computed (money rule 5), or when there
    /// was nothing a month ago to compare against — mirrors HomeView's card.
    private var monthOverMonthChange: Double? {
        guard let netWorth, let previousMonthNetWorth, previousMonthNetWorth != 0 else { return nil }
        return Double(netWorth - previousMonthNetWorth) / Double(abs(previousMonthNetWorth)) * 100
    }

    private var trendColor: Color {
        guard let monthOverMonthChange else { return .secondary }
        return monthOverMonthChange >= 0 ? .green : .red
    }

    private func load() async {
        errorMessage = nil
        guard let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }

        let today = Date()
        let todayString = PostgresDate.dateOnlyString(today, calendar: utcCalendar)
        let fromDate = utcCalendar.date(byAdding: .day, value: -(rangeDays - 1), to: today) ?? today
        let fromString = PostgresDate.dateOnlyString(fromDate, calendar: utcCalendar)
        let oneMonthAgo = utcCalendar.date(byAdding: .month, value: -1, to: today) ?? today
        let oneMonthAgoString = PostgresDate.dateOnlyString(oneMonthAgo, calendar: utcCalendar)
        let moneyScope = LocalMoneyScope(scope: session.scope, baseCurrency: baseCurrency)
        let dbQueue = session.dbQueue

        do {
            let (netWorthValue, previousMonthValue, seriesResult, currencies) = try await dbQueue.read { database in
                (
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: todayString, now: today),
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: oneMonthAgoString, now: today),
                    try LocalMoneyConversion.netWorthSeries(
                        database, moneyScope, from: fromString, through: todayString, now: today
                    ),
                    try LocalTableQueries.currencies(database)
                )
            }
            netWorth = netWorthValue
            previousMonthNetWorth = previousMonthValue
            if let row = currencies.first(where: { $0.code == baseCurrency }) {
                baseCurrencyInfo = CurrencyInfo(code: row.code, minorUnit: Int(row.minorUnit))
            }

            let parsed: [(date: Date, value: Int64)] = seriesResult.compactMap { point in
                guard
                    let date = PostgresDate.dateOnly(from: point.asOf, calendar: utcCalendar), let total = point.totalE4
                else { return nil }
                return (date: date, value: total)
            }
            let granularity = DateBucketing.granularity(from: fromDate, through: today)
            seriesPoints = DateBucketing.bucket(parsed, granularity: granularity)
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}

private struct NetWorthLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
