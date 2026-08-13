import Foundation
import GRDB
import KeepoCore

/// `budget_progress`/`fi_metrics` — split into their own file purely to
/// stay under this project's `file_length`/`type_body_length` lint limits;
/// see `LocalMoneyConversion.swift`'s header for the shared design.
extension LocalMoneyConversion {
    // MARK: - budget_progress

    static func budgetProgress(
        _ database: Database, ownerId: String, baseCurrency: String, periodMonth: Date
    ) throws -> [BudgetProgressLocal] {
        guard let monthStartDate = utcCalendar.dateInterval(of: .month, for: periodMonth)?.start,
              let monthEndDate = utcCalendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStartDate)
        else { return [] }
        let monthStart = PostgresDate.dateOnlyString(monthStartDate, calendar: utcCalendar)
        let monthEnd = PostgresDate.dateOnlyString(monthEndDate, calendar: utcCalendar)
        let today = PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)

        let names = try LocalMoneyQueries.categoryNames(database)
        let budgets = try Row.fetchAll(
            database,
            sql: """
            SELECT id, category_id, amount_e4, currency FROM budgets
            WHERE owner_id = ? AND period_month = ? AND deleted_at IS NULL ORDER BY category_id
            """,
            arguments: [ownerId, monthStart]
        )

        return try budgets.map { row in
            try budgetProgressRow(
                database, row: row, ownerId: ownerId, baseCurrency: baseCurrency, monthStart: monthStart,
                monthEnd: monthEnd, today: today, names: names
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func budgetProgressRow(
        _ database: Database, row: Row, ownerId: String, baseCurrency: String, monthStart: String, monthEnd: String,
        today: String, names: [String: String]
    ) throws -> BudgetProgressLocal {
        let budgetId: String = row["id"]
        let categoryId: String? = row["category_id"]
        let amountE4: Int64 = row["amount_e4"]
        let currency: String = row["currency"]
        let budgeted = try convert(database, amountE4: amountE4, from: currency, toCurrency: baseCurrency, date: today)

        let spentRows = try Row.fetchAll(
            database,
            sql: """
            SELECT amount_e4, currency, substr(occurred_at, 1, 10) AS occurred_date FROM transactions
            WHERE owner_id = ? AND category_kind = 'expense' AND deleted_at IS NULL AND status = 'confirmed'
              AND substr(occurred_at, 1, 10) BETWEEN ? AND ?
              AND (? IS NULL OR category_id = ?)
            """,
            arguments: [ownerId, monthStart, monthEnd, categoryId, categoryId]
        )
        var spent = RunningTotal()
        for spentRow in spentRows {
            let native: Int64 = spentRow["amount_e4"]
            let spentCurrency: String = spentRow["currency"]
            let occurredDate: String = spentRow["occurred_date"]
            try spent.add(abs(native), from: spentCurrency, at: occurredDate) {
                try convert(database, amountE4: $0, from: $1, toCurrency: baseCurrency, date: $2)
            }
        }

        return BudgetProgressLocal(
            budgetId: budgetId, categoryId: categoryId, categoryName: categoryId.flatMap { names[$0] },
            budgetedE4: budgeted, spentE4: spent.result, currency: baseCurrency
        )
    }

    // MARK: - fi_metrics

    /// Ratio math (`years_to_fi`, `coast_fi_number_e4`, `percent_progress`)
    /// uses `Double`/`ln`/`pow` — Postgres's `numeric` ln/power do not
    /// promise bit-identical output to `Foundation`'s, and the plan's own
    /// referee contract only requires these **within a stated tolerance**,
    /// not to the unit (unlike `annual_spend_e4`/`fi_number_e4`/
    /// `current_net_worth_e4`/`annual_savings_e4`, which are exact bigints
    /// carried straight through and must match exactly).
    static func fiMetrics(
        _ database: Database, ownerId: String, _ moneyScope: LocalMoneyScope, today: Date
    ) throws -> FIMetricsLocal {
        let settings = try fiSettings(database, ownerId: ownerId)
        let from = PostgresDate.dateOnlyString(
            utcCalendar.date(byAdding: .day, value: -365, to: today) ?? today, calendar: utcCalendar
        )
        let through = PostgresDate.dateOnlyString(today, calendar: utcCalendar)
        let (income, rawSpend) = try incomeAndExpense(database, moneyScope, from: from, through: through)
        let annualSpend = settings.targetSpendE4 ?? rawSpend
        let annualSavings: Int64? = {
            guard let income, let annualSpend else { return nil }
            return income - annualSpend
        }()

        let netWorthE4 = try netWorthCountingTowardFI(database, moneyScope, asOf: through, now: today)
        let fiNumber = fiNumber(annualSpend: annualSpend, withdrawalRate: settings.withdrawalRateDecimal)
        let years = yearsToFI(
            fiNumber: fiNumber, netWorthE4: netWorthE4, annualSavings: annualSavings,
            realReturnRate: settings.realReturnRate
        )
        let coastFI = coastFI(fiNumber: fiNumber, years: years, realReturnRate: settings.realReturnRate)
        let percentProgress: Decimal? = {
            guard let fiNumber, fiNumber != 0, let netWorthE4 else { return nil }
            return Decimal(netWorthE4) / Decimal(fiNumber)
        }()

        return FIMetricsLocal(
            annualSpendE4: annualSpend, fiNumberE4: fiNumber, currentNetWorthE4: netWorthE4,
            percentProgress: percentProgress, annualSavingsE4: annualSavings, yearsToFi: years,
            coastFiNumberE4: coastFI
        )
    }

    private static func fiSettings(_ database: Database, ownerId: String) throws -> FISettingsLocal {
        let row = try Row.fetchOne(
            database,
            sql: """
            SELECT target_annual_spend_e4, withdrawal_rate, real_return_rate FROM fi_settings WHERE owner_id = ?
            """,
            arguments: [ownerId]
        )
        // `withdrawalRateDecimal` stays `Decimal` (parsed straight from the
        // TEXT column, never routed through `Double`) because `fi_number_e4`
        // — a money value under the referee's exact-to-the-unit contract —
        // divides by it. `realReturnRate` only ever feeds `ln`/`pow` below
        // (years_to_fi/coast_fi, both tolerance-bound), so `Double` there
        // costs nothing.
        let withdrawalRateDecimal = (row?["withdrawal_rate"] as String?).flatMap { Decimal(string: $0) }
        let realReturnRate = (row?["real_return_rate"] as String?).flatMap(Double.init) ?? 0.05
        return FISettingsLocal(
            targetSpendE4: row?["target_annual_spend_e4"], withdrawalRateDecimal: withdrawalRateDecimal,
            realReturnRate: realReturnRate
        )
    }

    private static func fiNumber(annualSpend: Int64?, withdrawalRate: Decimal?) -> Int64? {
        guard let annualSpend, let withdrawalRate, withdrawalRate != 0 else { return nil }
        var rounded = Decimal()
        var scaled = Decimal(annualSpend) / withdrawalRate
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    /// Years to FI, contributions included — the same closed-form solve as
    /// `public.fi_metrics`' own comment: (1+r)^t applied to today's net
    /// worth plus t years of savings equals the FI number.
    private static func yearsToFI(
        fiNumber: Int64?, netWorthE4: Int64?, annualSavings: Int64?, realReturnRate: Double
    ) -> Double? {
        guard let fiNumber, let netWorthE4 else { return nil }
        if netWorthE4 >= fiNumber { return 0 }
        guard let annualSavings, annualSavings > 0 else { return nil }
        let fiValue = Double(fiNumber)
        let netWorthValue = Double(netWorthE4)
        let savings = Double(annualSavings)
        if realReturnRate == 0 { return (fiValue - netWorthValue) / savings }
        let cushion = savings / realReturnRate
        return log((fiValue + cushion) / (netWorthValue + cushion)) / log(1 + realReturnRate)
    }

    private static func coastFI(fiNumber: Int64?, years: Double?, realReturnRate: Double) -> Int64? {
        guard let fiNumber, let years else { return nil }
        if realReturnRate == 0 { return fiNumber }
        return Int64((Double(fiNumber) / pow(1 + realReturnRate, years)).rounded())
    }
}
