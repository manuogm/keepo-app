import Charts
import KeepoCore
import SwiftUI

/// Reached from Home's toolbar, not a tab — the same "not every feature is
/// a top-level tab" precedent Household/Sync Ritual/Recurring already
/// established. Trailing 90-day window, matching Home's own trajectory
/// (`rangeDays`) — no date-range picker, same reasoning: bucket
/// granularity and range are derived, never a user control
/// (app-architecture.md §5).
struct InsightsView: View {
    let session: SessionStore

    @State private var scope: PublicSchema.AccountScope = .total
    @State private var categorySpending: [CategorySpendingLocal] = []
    @State private var seriesPoints: [IncomeExpensePointLocal] = []
    @State private var savingsRate: Decimal?
    @State private var investmentAccounts: [LocalAccountRow] = []
    @State private var unrealizedGains: [UUID: Int64?] = [:]
    @State private var fiMetrics: FIMetricsLocal?
    @State private var isEditingFISettings = false
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
                    VStack(alignment: .leading, spacing: 24) {
                        Picker("Scope", selection: $scope) {
                            Text("Total").tag(PublicSchema.AccountScope.total)
                            Text("Me").tag(PublicSchema.AccountScope.me)
                            Text("Household").tag(PublicSchema.AccountScope.household)
                        }
                        .pickerStyle(.segmented)

                        savingsRateSection
                        incomeExpenseSection
                        categorySpendingSection

                        if !investmentAccounts.isEmpty {
                            unrealizedGainSection
                        }

                        financialIndependenceSection

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
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingFISettings) {
            FISettingsView(session: session) {
                Task { await loadFIMetrics() }
            }
        }
        .task(id: InsightsLoadKey(token: session.refresh.token, scope: scope)) { await load() }
    }

    /// FI number, % progress, years-to-FI, and Coast FI, from one visible,
    /// editable assumption set — never a hidden constant (spec).
    private var financialIndependenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Financial Independence").font(.headline).foregroundStyle(Color.primary)
                Spacer()
                Button("Assumptions") { isEditingFISettings = true }
                    .font(.caption)
            }
            if let fiMetrics {
                fiMetricRow("FI number", value: fiCurrencyText(fiMetrics.fiNumberE4))
                fiMetricRow("Progress", value: fiPercentText(fiMetrics.percentProgress))
                fiMetricRow("Years to FI", value: fiYearsText(fiMetrics.yearsToFi.map { Decimal($0) }))
                fiMetricRow("Coast FI number", value: fiCurrencyText(fiMetrics.coastFiNumberE4))
            } else {
                Text("—").foregroundStyle(Color.secondary)
            }
        }
    }

    private func fiMetricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(Color.primary)
        }
    }

    private func fiCurrencyText(_ amountE4: Int64?) -> String {
        guard let amountE4 else { return "—" }
        let currency = CurrencyInfo(code: session.profile?.baseCurrency ?? "USD", minorUnit: 0)
        return MoneyFormatter.format(amountE4, currency: currency)
    }

    private func fiPercentText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func fiYearsText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private var savingsRateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Savings rate").font(.headline).foregroundStyle(Color.primary)
            Text(savingsRateText)
                .font(.largeTitle).fontWeight(.bold)
                .foregroundStyle(Color.primary)
            Text("Excludes transfers and investment valuation changes.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var savingsRateText: String {
        guard let savingsRate else { return "—" }
        return savingsRate.formatted(.percent.precision(.fractionLength(0)))
    }

    private var incomeExpenseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Income & Expense").font(.headline).foregroundStyle(Color.primary)
            if seriesPoints.isEmpty {
                Text("Nothing in this window yet.")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
            } else {
                Chart(seriesPoints, id: \.bucketStart) { point in
                    if let income = point.incomeE4 {
                        BarMark(
                            x: .value("Period", point.bucketStart), y: .value("Income", Double(income) / 10_000)
                        )
                        .foregroundStyle(Color.primary)
                        .position(by: .value("Kind", "Income"))
                    }
                    if let expense = point.expenseE4 {
                        BarMark(
                            x: .value("Period", point.bucketStart), y: .value("Expense", Double(expense) / 10_000)
                        )
                        .foregroundStyle(Color.primary)
                        .position(by: .value("Kind", "Expense"))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 200)
            }
        }
    }

    private var categorySpendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by Category").font(.headline).foregroundStyle(Color.primary)
            if categorySpending.isEmpty {
                Text("No expenses in this window yet.")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
            } else {
                // Category bars carry name + value as text (app-architecture.md
                // §5) — color alone is never the only identity channel, which
                // is also why every bar shares one color here rather than an
                // unvalidated per-category palette.
                Chart(categorySpending, id: \.categoryId) { entry in
                    BarMark(
                        x: .value("Amount", Double(entry.totalE4 ?? 0) / 10_000),
                        y: .value("Category", entry.categoryName)
                    )
                    .foregroundStyle(Color.primary)
                    .annotation(position: .trailing) {
                        Text(categoryLabel(entry))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: CGFloat(categorySpending.count * 44))
            }
        }
    }

    private func categoryLabel(_ entry: CategorySpendingLocal) -> String {
        guard let total = entry.totalE4 else { return "—" }
        let currency = CurrencyInfo(code: entry.currency, minorUnit: 2)
        return MoneyFormatter.format(total, currency: currency)
    }

    private var unrealizedGainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unrealized Gain").font(.headline).foregroundStyle(Color.primary)
            ForEach(investmentAccounts) { account in
                HStack {
                    Text(account.name).foregroundStyle(Color.primary)
                    Spacer()
                    Text(unrealizedGainText(for: account))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func unrealizedGainText(for account: LocalAccountRow) -> String {
        guard let gain = unrealizedGains[account.id], let gain else { return "—" }
        return MoneyFormatter.format(gain, currency: account.currencyInfo)
    }

    private func load() async {
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let today = Date()
        let from = utcCalendar.date(byAdding: .day, value: -(rangeDays - 1), to: today) ?? today
        let fromString = PostgresDate.dateOnlyString(from, calendar: utcCalendar)
        let todayString = PostgresDate.dateOnlyString(today, calendar: utcCalendar)
        let granularity = DateBucketing.granularity(from: from, through: today) == .monthly ? "monthly" : "weekly"
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        let dbQueue = session.dbQueue

        do {
            let loaded: LoadedInsightsState = try await dbQueue.read { database in
                let accounts = try LocalAccountRow.fetchAll(
                    database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency
                )
                let investments = accounts.filter { $0.kind == .valuation && $0.archivedAt == nil }
                var gains: [UUID: Int64?] = [:]
                for account in investments {
                    gains[account.id] = try LocalMoneyQueries.unrealizedGain(
                        database, accountId: account.id.uuidString
                    )
                }
                return LoadedInsightsState(
                    categorySpending: try LocalMoneyConversion.spendingByCategory(
                        database, moneyScope, from: fromString, through: todayString
                    ),
                    seriesPoints: try LocalMoneyConversion.incomeExpenseSeries(
                        database, moneyScope, from: fromString, through: todayString, granularity: granularity
                    ),
                    savingsRate: try LocalMoneyConversion.savingsRate(
                        database, moneyScope, from: fromString, through: todayString
                    ),
                    investmentAccounts: investments, unrealizedGains: gains,
                    fiMetrics: try LocalMoneyConversion.fiMetrics(
                        database, ownerId: ownerId.uuidString, moneyScope, today: today
                    )
                )
            }
            categorySpending = loaded.categorySpending
            seriesPoints = loaded.seriesPoints
            savingsRate = loaded.savingsRate
            investmentAccounts = loaded.investmentAccounts
            unrealizedGains = loaded.unrealizedGains
            fiMetrics = loaded.fiMetrics
        } catch {
            errorMessage = UserFacingError.describe(error)
        }

        isLoading = false
    }

    private func loadFIMetrics() async {
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else { return }
        let moneyScope = LocalMoneyScope(scope: scope, baseCurrency: baseCurrency)
        fiMetrics = try? await session.dbQueue.read { database in
            try LocalMoneyConversion.fiMetrics(database, ownerId: ownerId.uuidString, moneyScope, today: Date())
        }
    }
}

private struct InsightsLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}

private struct LoadedInsightsState {
    let categorySpending: [CategorySpendingLocal]
    let seriesPoints: [IncomeExpensePointLocal]
    let savingsRate: Decimal?
    let investmentAccounts: [LocalAccountRow]
    let unrealizedGains: [UUID: Int64?]
    let fiMetrics: FIMetricsLocal
}
