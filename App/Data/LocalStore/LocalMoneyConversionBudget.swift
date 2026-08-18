import Foundation
import GRDB
import KeepoCore

/// `budget_progress` — split into its own file purely to stay under this
/// project's `file_length`/`type_body_length` lint limits; see
/// `LocalMoneyConversion.swift`'s header for the shared design.
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
}
