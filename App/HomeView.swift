import Charts
import KeepoCore
import SwiftUI

/// Dashboard — hero net-worth balance + 90-day trajectory for the scope the
/// user selected via the PrivacyToggleButton's long-press context menu.
/// Scope lives in SessionStore so it persists across tab switches and drives
/// every financial screen from the same source of truth.
struct HomeView: View {
    let session: SessionStore

    @State private var netWorth: Decimal?
    @State private var seriesPoints: [(date: Date, value: Decimal)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Non-nil means the hero figure/trajectory are the last successful
    /// fetch's cached copy, not a live read — Phase 11's "as of HH:mm"
    /// marker for the Home summary specifically.
    @State private var summaryAsOf: Date?

    private let rangeDays = 90

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let summaryAsOf {
                            Text("Showing data as of \(summaryAsOf.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }

                        BalanceHeaderView(amount: netWorth, currency: baseCurrencyInfo)

                        // A gap in the line (a day this scope has no rows
                        // for, or an unresolvable rate) is left as a gap,
                        // never filled with zero — money rule 5 governs
                        // this chart, not the bar-chart "fill gaps with
                        // real zeroes" rule from app-architecture.md §5.
                        if seriesPoints.isEmpty {
                            Text("No trajectory yet for this scope.")
                                .font(.callout)
                                .foregroundStyle(Color.secondary)
                        } else {
                            Chart(seriesPoints, id: \.date) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Net worth", point.value))
                            }
                            .foregroundStyle(Color.primary)
                            .chartYAxis {
                                AxisMarks(position: .leading)
                            }
                            .frame(height: 220)
                        }

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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PrivacyToggleButton(session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    InsightsView(session: session)
                } label: {
                    Image(systemName: "chart.bar")
                }
            }
        }
        .task { restoreSummaryCache() }
        .task(id: HomeLoadKey(token: session.refresh.token, scope: session.scope)) { await load() }
    }

    private func load() async {
        errorMessage = nil
        guard let userId = session.profile?.id else {
            isLoading = false
            return
        }

        let today = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(rangeDays - 1), to: today) ?? today

        if let baseCurrency = session.profile?.baseCurrency {
            let currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []
            if let row = currencies.first(where: { $0.code == baseCurrency }) {
                baseCurrencyInfo = CurrencyInfo(code: row.code, minorUnit: Int(row.minorUnit))
            }
        }

        // Best-effort — no pg_cron exists yet (Phase 13), so the client
        // warms its own window. A failure here shouldn't block reading
        // whatever the account already has materialized.
        try? await HouseholdRepository.refreshNetWorthDaily(
            client: session.client, userId: userId, from: from, through: today
        )

        do {
            async let netWorthResult = HouseholdRepository.netWorth(client: session.client, scope: session.scope)
            async let seriesResult = HouseholdRepository.netWorthSeries(
                client: session.client, scope: session.scope, from: from, through: today
            )
            netWorth = try await netWorthResult
            let points = try await seriesResult

            let parsed: [(date: Date, value: Decimal)] = points.compactMap { point in
                guard let date = PostgresDate.dateOnly(from: point.asOf), let total = point.total else { return nil }
                return (date: date, value: total)
            }
            let granularity = DateBucketing.granularity(from: from, through: today)
            seriesPoints = DateBucketing.bucket(parsed, granularity: granularity)
            summaryAsOf = nil
            saveSummaryCache()
        } catch {
            if !restoreSummaryCache() {
                errorMessage = UserFacingError.describe(error)
            }
        }
        isLoading = false
    }

    private var summaryCacheKey: String { "home_summary_\(session.scope.rawValue)" }

    private func saveSummaryCache() {
        let payload = HomeSummaryCache(
            netWorth: netWorth,
            seriesPoints: seriesPoints.map { HomeSummaryCache.Point(date: $0.date, value: $0.value) },
            baseCurrencyCode: baseCurrencyInfo?.code,
            baseCurrencyMinorUnit: baseCurrencyInfo?.minorUnit
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        session.payloadCache.save(key: summaryCacheKey, data: data)
    }

    /// Returns whether a cached summary existed to restore — the caller
    /// uses this to decide whether a live-fetch failure should still show
    /// an error (no cache to fall back on) or can stay silent behind the
    /// "as of" marker instead.
    @discardableResult
    private func restoreSummaryCache() -> Bool {
        guard
            let (data, fetchedAt) = session.payloadCache.load(key: summaryCacheKey),
            let payload = try? JSONDecoder().decode(HomeSummaryCache.self, from: data)
        else { return false }
        netWorth = payload.netWorth
        seriesPoints = payload.seriesPoints.map { (date: $0.date, value: $0.value) }
        if let code = payload.baseCurrencyCode, let minorUnit = payload.baseCurrencyMinorUnit {
            baseCurrencyInfo = CurrencyInfo(code: code, minorUnit: minorUnit)
        }
        summaryAsOf = fetchedAt
        isLoading = false
        return true
    }
}

/// The Home summary's own cache payload — net worth + trajectory + the
/// base currency needed to render them, for exactly one scope (part of the
/// cache key, not this struct — Total/Me/Household are cached separately).
private struct HomeSummaryCache: Codable {
    let netWorth: Decimal?
    let seriesPoints: [Point]
    let baseCurrencyCode: String?
    let baseCurrencyMinorUnit: Int?

    struct Point: Codable {
        let date: Date
        let value: Decimal
    }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token and the
/// scope so either changing triggers exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
