import Foundation
import KeepoCore

/// The figures the widget catalogue's previews render — split from
/// `DashboardData` for file length, and because none of it is part of the
/// dashboard's real data path.
extension DashboardData {
    /// The figures the catalogue's previews render. Not test data and not
    /// `#if DEBUG` — the catalogue ships, and a preview has to show a widget
    /// carrying plausible numbers or it tells the user nothing about what
    /// they are choosing.
    ///
    /// Deliberately generic and obviously round: a preview that looked like
    /// the user's own money would be worse than one that clearly doesn't,
    /// because on an empty dashboard they could not tell the two apart.
    static let sample = DashboardData(
        baseCurrency: CurrencyInfo(code: "EUR", minorUnit: 2),
        netWorth: NetWorthMetrics(
            current: 481_200_000,
            previousMonth: 456_000_000,
            series: sampleSeries
        ),
        upcomingBills: UpcomingTransactionsMetrics(items: sampleUpcoming, windowDays: 14),
        currencyExposure: CurrencyExposureMetrics(slices: sampleCurrencies),
        cashflow: CashflowMetrics(
            periodLabel: "Last month",
            totals: CashflowTotalsLocal(
                moneyInE4: 38_400_000, moneyOutE4: -26_150_000, byCategory: sampleCashflowCategories
            ),
            previousNetE4: 10_800_000
        ),
        investingRatio: InvestingRatioMetrics(
            investedE4: 173_000_000, netWorthE4: 481_200_000,
            previousInvestedE4: 158_000_000, previousNetWorthE4: 456_000_000,
            hasInvestmentAccounts: true
        ),
        capabilities: DashboardCapabilities(
            hasInvestmentAccounts: true, foreignCurrencies: ["USD", "GBP"]
        )
    )

    /// Twelve months of a charted metric, for the catalogue.
    ///
    /// A charting widget's figures come from the database through
    /// `DashboardMetricSeries`, and the catalogue has no database access by
    /// design — so its entries need their series from somewhere, and this is
    /// it. Same rule as the rest of `sample`: obviously round, obviously not
    /// the user's own money, because on an empty dashboard they could not
    /// tell the two apart.
    static func sampleSeries(for metric: MetricKind) -> [MetricPoint] {
        let months = monthBuckets(count: 12)
        switch metric {
        case .fxRate:
            let rates = [
                0.9105, 0.9142, 0.9088, 0.9203, 0.9271, 0.9188,
                0.9244, 0.9310, 0.9287, 0.9352, 0.9401, 0.9376
            ]
            return zip(months, rates).map { MetricPoint(bucket: $0, value: $1) }
        case .investingRatio:
            let invested: [Int64] = [
                121_000_000, 128_500_000, 133_000_000, 131_500_000, 140_000_000, 146_500_000,
                144_000_000, 153_000_000, 159_500_000, 163_000_000, 169_000_000, 173_000_000
            ]
            let netWorth: [Int64] = [
                412_000_000, 419_500_000, 427_000_000, 424_000_000, 433_500_000, 441_000_000,
                438_000_000, 449_000_000, 457_500_000, 462_000_000, 471_000_000, 481_200_000
            ]
            return (0 ..< months.count).map { index in
                MetricPoint(
                    bucket: months[index],
                    value: Double(invested[index]) / Double(netWorth[index]),
                    amountE4: invested[index], denominatorE4: netWorth[index]
                )
            }
        case .netWorth, .invested, .cashflowNet, .moneyIn, .moneyOut:
            let values: [Int64] = [
                412_000_000, 419_500_000, 427_000_000, 424_000_000, 433_500_000, 441_000_000,
                438_000_000, 449_000_000, 457_500_000, 462_000_000, 471_000_000, 481_200_000
            ]
            return zip(months, values).map { MetricPoint(bucket: $0, amountE4: $1) }
        }
    }

    private static func monthBuckets(count: Int) -> [Date] {
        let thisMonth = MetricGranularity.month.bucketStart(for: Date(), calendar: utcCalendar)
        return (0 ..< count).compactMap {
            utcCalendar.date(byAdding: .month, value: -(count - 1 - $0), to: thisMonth)
        }
    }

    /// One sample account, before it knows which currency it belongs to.
    private struct SampleAccount {
        let name: String
        let icon: String
        let color: String
        let amountE4: Int64
    }

    private static var sampleCurrencies: [CurrencyExposureLocal] {
        [
            currency("EUR", 312_000_000, [
                SampleAccount(name: "Current Account", icon: "banknote.fill", color: "#007AFF", amountE4: 84_000_000),
                SampleAccount(
                    name: "Savings", icon: "building.columns.fill", color: "#34C759", amountE4: 240_000_000
                ),
                SampleAccount(name: "Credit Card", icon: "creditcard.fill", color: "#FF2D55", amountE4: -12_000_000)
            ]),
            currency("USD", 121_000_000, [
                SampleAccount(
                    name: "Brokerage", icon: "chart.line.uptrend.xyaxis", color: "#5856D6", amountE4: 121_000_000
                )
            ]),
            currency("GBP", 48_200_000, [
                SampleAccount(name: "Travel Account", icon: "airplane", color: "#FF9500", amountE4: 48_200_000)
            ])
        ]
    }

    private static func currency(
        _ code: String, _ totalE4: Int64, _ accounts: [SampleAccount]
    ) -> CurrencyExposureLocal {
        CurrencyExposureLocal(
            currency: code, amountBaseE4: totalE4,
            accounts: accounts.map {
                CurrencyAccountLocal(
                    accountId: "\(code)-\($0.name)", name: $0.name, icon: $0.icon, color: $0.color,
                    currencyInfo: CurrencyInfo(code: code, minorUnit: 2),
                    amountBaseE4: $0.amountE4, nativeAmountE4: $0.amountE4
                )
            }
        )
    }

    private static var sampleCashflowCategories: [CashflowCategoryLocal] {
        [
            category("Salary", "banknote.fill", "#34C759", .income, 38_400_000),
            category("Rent", "house.fill", "#007AFF", .expense, -12_000_000),
            category("Groceries", "cart.fill", "#FF9500", .expense, -6_400_000),
            category("Dining", "fork.knife", "#FF2D55", .expense, -4_250_000),
            category("Transport", "car.fill", "#5856D6", .expense, -3_500_000)
        ]
    }

    private static func category(
        _ name: String, _ icon: String, _ color: String,
        _ kind: PublicSchema.CategoryKind, _ amountE4: Int64
    ) -> CashflowCategoryLocal {
        CashflowCategoryLocal(
            categoryId: name, name: name, icon: icon, color: color, kind: kind, amountE4: amountE4
        )
    }

    /// A fortnight with money moving both ways — a preview showing only
    /// outflows would promise a narrower widget than the one being added.
    private static var sampleUpcoming: [UpcomingTransactionLocal] {
        let today = utcCalendar.startOfDay(for: Date())
        return [
            upcoming(inDays: 2, "Rent", "house.fill", "#007AFF", "Current Account", -120_000_000, from: today),
            upcoming(inDays: 5, "Internet", "bolt.fill", "#FF9500", "Current Account", -4_500_000, from: today),
            upcoming(inDays: 6, "Salary", "banknote.fill", "#34C759", "Current Account", 384_000_000, from: today),
            upcoming(inDays: 9, "Gym", "figure.run", "#34C759", "Current Account", -3_900_000, from: today),
            upcoming(inDays: 12, "Streaming", "gamecontroller.fill", "#AF52DE", "Credit Card", -1_599_000, from: today)
        ]
    }

    // swiftlint:disable:next function_parameter_count
    private static func upcoming(
        inDays days: Int, _ name: String, _ icon: String, _ color: String, _ account: String,
        _ amountE4: Int64, from today: Date
    ) -> UpcomingTransactionLocal {
        UpcomingTransactionLocal(
            ruleId: name, dueOn: utcCalendar.date(byAdding: .day, value: days, to: today) ?? today,
            categoryName: name, categoryIcon: icon, categoryColor: color, accountName: account,
            amountBaseE4: amountE4, nativeAmountE4: amountE4, nativeCurrency: "EUR"
        )
    }

    /// Twelve weeks climbing with a dip in the middle — a shape, rather than
    /// a straight line, so the preview shows what the chart actually does.
    private static var sampleSeries: [DashboardSeriesPoint] {
        let values: [Int64] = [
            412_000_000, 419_500_000, 427_000_000, 424_000_000, 433_500_000, 441_000_000,
            438_000_000, 449_000_000, 457_500_000, 462_000_000, 471_000_000, 481_200_000
        ]
        let start = Date().addingTimeInterval(-Double(values.count - 1) * 7 * 86_400)
        return values.enumerated().map {
            DashboardSeriesPoint(
                date: start.addingTimeInterval(Double($0.offset) * 7 * 86_400), value: $0.element
            )
        }
    }
}
