import KeepoCore
import SwiftUI

/// Pushed from the Dashboard's net-worth card — the same balance/series data
/// `HomeView` already loads, shown with full axes instead of the card's
/// compact axis-free chart.
struct NetWorthDetailView: View {
    let session: SessionStore

    @State private var netWorth: Int64?
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
                    VStack(alignment: .leading, spacing: 20) {
                        BalanceHeaderView(amount: netWorth, currency: baseCurrencyInfo)
                        NetWorthChartView(seriesPoints: seriesPoints, showAxes: true, height: 320)
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
        let moneyScope = LocalMoneyScope(scope: session.scope, baseCurrency: baseCurrency)
        let dbQueue = session.dbQueue

        do {
            let (netWorthValue, seriesResult, currencies) = try await dbQueue.read { database in
                (
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: todayString, now: today),
                    try LocalMoneyConversion.netWorthSeries(
                        database, moneyScope, from: fromString, through: todayString, now: today
                    ),
                    try LocalTableQueries.currencies(database)
                )
            }
            netWorth = netWorthValue
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
