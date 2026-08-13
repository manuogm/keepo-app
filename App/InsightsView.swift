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
    @State private var categorySpending: [CategorySpending] = []
    @State private var seriesPoints: [IncomeExpensePoint] = []
    @State private var savingsRate: Decimal?
    @State private var investmentAccounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var unrealizedGains: [UUID: Int64?] = [:]
    @State private var fiMetrics: FIMetrics?
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
                fiMetricRow("Years to FI", value: fiYearsText(fiMetrics.yearsToFi))
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

    private func categoryLabel(_ entry: CategorySpending) -> String {
        guard let total = entry.totalE4 else { return "—" }
        let currency = CurrencyInfo(code: entry.currency, minorUnit: 2)
        return MoneyFormatter.format(total, currency: currency)
    }

    private var unrealizedGainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unrealized Gain").font(.headline).foregroundStyle(Color.primary)
            ForEach(investmentAccounts, id: \.accountId) { account in
                HStack {
                    Text(account.name ?? "—").foregroundStyle(Color.primary)
                    Spacer()
                    Text(unrealizedGainText(for: account))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func unrealizedGainText(for account: PublicSchema.AccountsWithBalancesSelect) -> String {
        guard let accountId = account.accountId, let gain = unrealizedGains[accountId], let gain else { return "—" }
        let currency = CurrencyInfo(code: account.currency ?? "EUR", minorUnit: Int(account.minorUnit ?? 2))
        return MoneyFormatter.format(gain, currency: currency)
    }

    private func load() async {
        let today = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(rangeDays - 1), to: today) ?? today
        let granularity = DateBucketing.granularity(from: from, through: today)

        async let categoryResult = InsightsRepository.spendingByCategory(
            client: session.client, scope: scope, from: from, through: today
        )
        async let seriesResult = InsightsRepository.incomeExpenseSeries(
            client: session.client, scope: scope, from: from, through: today, granularity: granularity
        )
        async let rateResult = InsightsRepository.savingsRate(
            client: session.client, scope: scope, from: from, through: today
        )
        async let accountsResult = AccountRepository.fetchAllWithBalances(client: session.client)

        categorySpending = (try? await categoryResult) ?? []
        seriesPoints = (try? await seriesResult) ?? []
        savingsRate = try? await rateResult
        let accounts = (try? await accountsResult) ?? []
        investmentAccounts = accounts.filter { $0.kind == .valuation && $0.archivedAt == nil }

        for account in investmentAccounts {
            guard let accountId = account.accountId else { continue }
            unrealizedGains[accountId] = try? await InsightsRepository.unrealizedGain(
                client: session.client, accountId: accountId
            )
        }

        await loadFIMetrics()

        isLoading = false
    }

    private func loadFIMetrics() async {
        fiMetrics = try? await FIRepository.fetchMetrics(client: session.client, scope: scope)
    }
}

private struct InsightsLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
