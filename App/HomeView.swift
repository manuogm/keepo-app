import Charts
import KeepoCore
import SwiftUI

/// Dashboard — hero net-worth balance + 90-day trajectory for the scope the
/// user selected via `ScopeSwitcherButton`. Scope lives in SessionStore so
/// it persists across tab switches and drives every financial screen from
/// the same source of truth.
struct HomeView: View {
    let session: SessionStore

    @State private var netWorth: Int64?
    @State private var seriesPoints: [(date: Date, value: Int64)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var fxRates: [String: Decimal] = [:]

    private let rangeDays = 90

    /// Net worth overlaid with whatever's still queued in the outbox — the
    /// hero figure moves the instant an offline edit changes a balance,
    /// not just once it syncs. Falls back to the plain `netWorth` (server
    /// or cache) if the accounts cache needed to know per-account scope
    /// membership (`is_shared`) isn't available. Only accounts already in
    /// base currency are guaranteed exact here; a cross-currency account
    /// needs `fxRates` to have that currency cached, same "—" fallback
    /// money rule 5 already governs everywhere else in this overlay.
    private var overlaidNetWorth: Int64? {
        guard let netWorth, let baseCurrencyInfo,
              let (data, _) = session.payloadCache.load(key: "accounts_with_balances"),
              let cachedAccounts = try? JSONDecoder().decode(
                [PublicSchema.AccountsWithBalancesSelect].self, from: data
              )
        else { return netWorth }

        let inScope = cachedAccounts.filter { account in
            switch session.scope {
            case .me: return account.isShared != true
            case .household: return account.isShared == true
            case .total: return true
            }
        }
        let cachedBalances = Dictionary(uniqueKeysWithValues: inScope.compactMap { account in
            account.accountId.flatMap { id in account.balanceE4.map { (id, $0) } }
        })
        let cachedTransactions = PendingOverlayAdapter.cachedTransactionLookup(session: session)
        let overlay = PendingOverlayAdapter.overlaidBalances(
            cached: cachedBalances, outbox: session.outbox, cachedTransactions: cachedTransactions
        )

        var total: Int64 = 0
        for account in inScope {
            guard let id = account.accountId, let currency = account.currency else { return netWorth }
            let balance = overlay[id] ?? account.balanceE4
            guard let balance else { return netWorth }
            guard let converted = LocalFxConvert.convert(
                balance, from: currency, to: baseCurrencyInfo.code, rates: fxRates
            ) else { return netWorth }
            total += converted
        }
        return total
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        BalanceHeaderView(amount: overlaidNetWorth, currency: baseCurrencyInfo)

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
                                // Charting is display-only — converting to
                                // Double here never feeds back into stored
                                // or compared money, so it doesn't touch
                                // money rule 3.
                                LineMark(
                                    x: .value("Date", point.date), y: .value("Net worth", Double(point.value) / 10_000)
                                )
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ScopeSwitcherButton(session: session)
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Dashboard", session: session)
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
        .task { fxRates = await FxRateCache.fetchLatestRates(session: session) }
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
            let currencies = await CurrencyCache.fetchAll(session: session)
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

            let parsed: [(date: Date, value: Int64)] = points.compactMap { point in
                guard let date = PostgresDate.dateOnly(from: point.asOf), let total = point.totalE4 else { return nil }
                return (date: date, value: total)
            }
            let granularity = DateBucketing.granularity(from: from, through: today)
            seriesPoints = DateBucketing.bucket(parsed, granularity: granularity)
            saveSummaryCache()
        } catch {
            // Offline is ambient state, surfaced by the persistent status
            // indicator elsewhere on screen — not a per-fetch red error.
            if !restoreSummaryCache() && !UserFacingError.isOffline(error) {
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
    /// an error (no cache to fall back on) or can stay silent instead.
    /// The offline indicator elsewhere on screen is what tells the user
    /// the data might be stale; this screen no longer repeats that itself.
    @discardableResult
    private func restoreSummaryCache() -> Bool {
        guard
            let (data, _) = session.payloadCache.load(key: summaryCacheKey),
            let payload = try? JSONDecoder().decode(HomeSummaryCache.self, from: data)
        else { return false }
        netWorth = payload.netWorth
        seriesPoints = payload.seriesPoints.map { (date: $0.date, value: $0.value) }
        if let code = payload.baseCurrencyCode, let minorUnit = payload.baseCurrencyMinorUnit {
            baseCurrencyInfo = CurrencyInfo(code: code, minorUnit: minorUnit)
        }
        isLoading = false
        return true
    }
}

/// The Home summary's own cache payload — net worth + trajectory + the
/// base currency needed to render them, for exactly one scope (part of the
/// cache key, not this struct — Total/Me/Household are cached separately).
private struct HomeSummaryCache: Codable {
    let netWorth: Int64?
    let seriesPoints: [Point]
    let baseCurrencyCode: String?
    let baseCurrencyMinorUnit: Int?

    struct Point: Codable {
        let date: Date
        let value: Int64
    }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token and the
/// scope so either changing triggers exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
