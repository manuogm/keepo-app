import Charts
import KeepoCore
import SwiftUI

/// The first screen whose entire purpose is a large balance — the
/// app-switcher privacy curtain (RootView) exists because of this screen.
/// Trailing 90-day trajectory, bucketed per app-architecture.md §5 (weekly
/// ≤ 90 days, monthly beyond — always weekly here, since the range itself
/// is fixed at 90 days for v1; a date-range picker is a later phase).
struct HomeView: View {
    let session: SessionStore

    @State private var scope: PublicSchema.AccountScope = .total
    @State private var netWorth: Decimal?
    @State private var seriesPoints: [(date: Date, value: Decimal)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var hasStaleFeedingAccount = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let rangeDays = 90

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("Scope", selection: $scope) {
                            Text("Total").tag(PublicSchema.AccountScope.total)
                            Text("Me").tag(PublicSchema.AccountScope.me)
                            Text("Household").tag(PublicSchema.AccountScope.household)
                        }
                        .pickerStyle(.segmented)

                        if hasStaleFeedingAccount {
                            staleBanner
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
                                .foregroundStyle(Color("TextSecondary"))
                        } else {
                            Chart(seriesPoints, id: \.date) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Net worth", point.value))
                            }
                            .foregroundStyle(Color("BrandPrimary"))
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
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SyncRitualView(session: session)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
        }
        .task(id: HomeLoadKey(token: session.refresh.token, scope: scope)) { await load() }
    }

    /// Factual, not alarmist — names what's stale rather than just showing
    /// amber. "Feeding" means include_in_total: an archived or excluded
    /// account going stale is invisible here on purpose, same reasoning as
    /// net worth itself only summing accounts the user asked to count.
    private var staleBanner: some View {
        NavigationLink {
            SyncRitualView(session: session)
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("A balance feeding this total needs verifying.")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .foregroundStyle(Color("BrandSecondary"))
        }
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

        let syncStatus = (try? await ReconciliationRepository.fetchSyncStatus(client: session.client)) ?? []
        hasStaleFeedingAccount = syncStatus.contains {
            $0.archivedAt == nil && ($0.includeInTotal ?? false) && ($0.isStale ?? false)
        }

        do {
            async let netWorthResult = HouseholdRepository.netWorth(client: session.client, scope: scope)
            async let seriesResult = HouseholdRepository.netWorthSeries(
                client: session.client, scope: scope, from: from, through: today
            )
            netWorth = try await netWorthResult
            let points = try await seriesResult

            let parsed: [(date: Date, value: Decimal)] = points.compactMap { point in
                guard let date = PostgresDate.dateOnly(from: point.asOf), let total = point.total else { return nil }
                return (date: date, value: total)
            }
            let granularity = DateBucketing.granularity(from: from, through: today)
            seriesPoints = DateBucketing.bucket(parsed, granularity: granularity)
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token and the
/// scope picker together so either changing triggers exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
