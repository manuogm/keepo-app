import KeepoCore
import SwiftUI

/// Dashboard — hero net-worth card for the scope the user selected via
/// `ScopeSwitcherButton`, plus a bell that opens the Needs Review inbox as a
/// floating notifications panel. Scope lives in SessionStore so it persists
/// across tab switches and drives every financial screen from the same
/// source of truth.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries, so there is nothing left
/// for an overlay to add: one number, one source.
struct HomeView: View {
    let session: SessionStore

    @State private var netWorth: Int64?
    @State private var seriesPoints: [(date: Date, value: Int64)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsReviewCount = 0
    @State private var showNotifications = false

    private let rangeDays = 90

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        netWorthCard

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
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ScopeSwitcherButton(session: session)
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Dashboard", session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNotifications = true
                } label: {
                    Image(systemName: "bell")
                }
                .overlay(alignment: .topTrailing) {
                    if needsReviewCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
                }
            }
        }
        .sheet(isPresented: $showNotifications) {
            NavigationStack {
                NeedsReviewView(session: session)
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: HomeLoadKey(token: session.refresh.token, scope: session.scope)) { await load() }
    }

    private var netWorthCard: some View {
        NavigationLink {
            NetWorthDetailView(session: session)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Net Worth")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                BalanceHeaderView(amount: netWorth, currency: baseCurrencyInfo)
                NetWorthChartView(seriesPoints: seriesPoints, showAxes: false, height: 120)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
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
            let (netWorthValue, seriesResult, currencies, reviewRows) = try await dbQueue.read { database in
                (
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: todayString, now: today),
                    try LocalMoneyConversion.netWorthSeries(
                        database, moneyScope, from: fromString, through: todayString, now: today
                    ),
                    try LocalTableQueries.currencies(database),
                    try LocalMoneyQueries.needsReview(database)
                )
            }
            netWorth = netWorthValue
            if let row = currencies.first(where: { $0.code == baseCurrency }) {
                baseCurrencyInfo = CurrencyInfo(code: row.code, minorUnit: Int(row.minorUnit))
            }
            needsReviewCount = reviewRows.filter { $0.kind != "reconciliation_gap" }.count

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

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token and the
/// scope so either changing triggers exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
