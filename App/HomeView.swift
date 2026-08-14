import KeepoCore
import SwiftUI

/// Home — hero net-worth card for the scope the user selected via the
/// top-left "more options" button, plus a bell that opens the Needs Review
/// inbox as a floating notifications panel. Scope lives in SessionStore so
/// it persists across tab switches and drives every financial screen from
/// the same source of truth.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries, so there is nothing left
/// for an overlay to add: one number, one source.
struct HomeView: View {
    let session: SessionStore

    @State private var netWorth: Int64?
    @State private var previousMonthNetWorth: Int64?
    @State private var seriesPoints: [(date: Date, value: Int64)] = []
    @State private var baseCurrencyInfo: CurrencyInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsReviewCount = 0
    @State private var showNotifications = false
    @State private var showScopeMenu = false

    private let rangeDays = 90

    private var isOverlayPresented: Bool { showNotifications || showScopeMenu }

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

            // Both top-bar buttons present via `.popover` rather than a
            // system `.sheet`, so neither gets the automatic background dim
            // a sheet would apply — this overlay adds that dimming back
            // manually.
            //
            // Hit-testable (only while shown) and wired to close both
            // popovers itself: an outside tap dismisses a `.popover` via a
            // system animation whose completion — not its start — is what
            // flips `isPresented`, so a curtain merely watching that binding
            // sits fully opaque for the whole dismiss animation and then
            // disappears abruptly right at the end. Setting the state here,
            // at the moment of the tap, puts the curtain back in the same
            // fast path as the "pick an option" dismiss, which already set
            // state directly and always looked instant.
            Color.black.opacity(isOverlayPresented ? 0.25 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(isOverlayPresented)
                .onTapGesture {
                    showScopeMenu = false
                    showNotifications = false
                }
        }
        .animation(.easeInOut(duration: 0.15), value: isOverlayPresented)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showScopeMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                // Same anchored-popover pattern as the bell button below —
                // grows from the button itself instead of rising as a sheet.
                .popover(isPresented: $showScopeMenu) {
                    scopeMenuContent
                        .frame(width: 220)
                        .presentationCompactAdaptation(.popover)
                }
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Home", session: session)
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
                // A popover (rather than a sheet) grows from the bell button
                // itself instead of rising from the bottom of the screen —
                // presentationCompactAdaptation(.popover) keeps that anchored
                // presentation on iPhone too, which would otherwise force it
                // to a full-screen cover in a compact-width size class.
                .popover(isPresented: $showNotifications) {
                    NavigationStack {
                        NeedsReviewView(session: session)
                    }
                    .frame(width: 340, height: 480)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .task(id: HomeLoadKey(token: session.refresh.token, scope: session.scope)) { await load() }
    }

    /// Rows keep their identity icon (globe/person/person.2) even when
    /// selected — the checkmark is appended at the trailing edge instead of
    /// replacing it, so which option is which stays visible at a glance.
    private var scopeMenuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeRow(.total, label: "Total Net Worth", icon: "globe")
            Divider()
            scopeRow(.me, label: "Personal", icon: "person.fill")
            Divider()
            scopeRow(.household, label: "Household", icon: "person.2.fill")
        }
        .padding(.vertical, 4)
    }

    private func scopeRow(_ scope: PublicSchema.AccountScope, label: String, icon: String) -> some View {
        Button {
            session.scope = scope
            showScopeMenu = false
        } label: {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(label)
                Spacer()
                if session.scope == scope {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
    }

    private var netWorthCard: some View {
        NavigationLink {
            NetWorthDetailView(session: session)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Net Worth")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                BalanceHeaderView(amount: netWorth, currency: baseCurrencyInfo)
                TrendBadge(percentChange: monthOverMonthChange, color: trendColor)
                NetWorthChartView(seriesPoints: seriesPoints, showAxes: false, height: 70, trendColor: trendColor)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// nil when either side can't be computed (money rule 5 — a missing FX
    /// rate propagates to "—", never a partial/misleading percentage), or
    /// when there was nothing a month ago to compare against.
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
            let loaded = try await dbQueue.read { database in
                (
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: todayString, now: today),
                    try LocalMoneyConversion.netWorth(database, moneyScope, asOf: oneMonthAgoString, now: today),
                    try LocalMoneyConversion.netWorthSeries(
                        database, moneyScope, from: fromString, through: todayString, now: today
                    ),
                    try LocalTableQueries.currencies(database),
                    try LocalMoneyQueries.needsReview(database)
                )
            }
            let (netWorthValue, previousMonthValue, seriesResult, currencies, reviewRows) = loaded
            netWorth = netWorthValue
            previousMonthNetWorth = previousMonthValue
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
