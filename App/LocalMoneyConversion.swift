import Foundation
import GRDB
import KeepoCore

/// `(scope, baseCurrency)` travels together through every scoped query
/// below — pairing them cuts one parameter off each function's signature
/// (the project's `function_parameter_count` lint caps at 5) rather than
/// inventing a home for a rule that only exists to satisfy the linter.
struct LocalMoneyScope {
    let scope: PublicSchema.AccountScope
    let baseCurrency: String
}

/// The one place `LocalMoneyQueries`' native-currency results become
/// base-currency figures (Phase L4) — see that file's header for why FX
/// conversion lives here in Swift rather than in the SQLite layer, and at
/// what granularity each function converts to stay byte-exact against the
/// server's own `sum(fx_convert(...))` rounding.
enum LocalMoneyConversion {
    // MARK: - fx_rate_on / fx_convert

    /// Port of `fx_rate_on(p_currency, p_date)` — EUR is structurally 1;
    /// everything else carries forward the newest `fx_rates` row at or
    /// before `date`, exactly like the server's `order by rate_date desc limit 1`.
    static func fxRateOn(_ database: Database, currency: String, date: String) throws -> Decimal? {
        if currency == "EUR" { return 1 }
        guard let rateString = try String.fetchOne(
            database,
            sql: """
            SELECT rate_to_eur FROM fx_rates WHERE currency = ? AND rate_date <= ?
            ORDER BY rate_date DESC LIMIT 1
            """,
            arguments: [currency, date]
        ) else { return nil }
        return Decimal(string: rateString)
    }

    /// Port of `fx_convert(p_amount_e4, p_from, p_to, p_date)`: the
    /// same-currency short-circuit, then a rate lookup on both sides and a
    /// call into `LocalFxConvert` — the shared, unit-tested, exact-rounding
    /// function the plan calls for.
    static func convert(
        _ database: Database, amountE4: Int64, from: String, toCurrency: String, date: String
    ) throws -> Int64? {
        if from == toCurrency { return amountE4 }
        guard let fromRate = try fxRateOn(database, currency: from, date: date),
              let toRate = try fxRateOn(database, currency: toCurrency, date: date)
        else { return nil }
        var rates: [String: Decimal] = [:]
        if from != "EUR" { rates[from] = fromRate }
        if toCurrency != "EUR" { rates[toCurrency] = toRate }
        return LocalFxConvert.convert(amountE4, from: from, to: toCurrency, rates: rates)
    }

    // MARK: - net_worth(scope) / net_worth_series

    /// Port of `net_worth(p_scope)` at an arbitrary date — server-side this
    /// is always "today"; L4 generalizes it because `netWorthSeries` below
    /// needs the same computation once per day and there is no on-device
    /// `net_worth_daily` to read instead (the plan's explicit call: a local
    /// store can afford to recompute).
    static func netWorth(
        _ database: Database, _ moneyScope: LocalMoneyScope, asOf: String, now: Date
    ) throws -> Int64? {
        try netWorth(
            database, baseCurrency: moneyScope.baseCurrency, asOf: asOf, now: now,
            accountIds: try scopedAccountIds(database, scope: moneyScope.scope)
        )
    }

    /// The `counts_toward_fi`-restricted variant `fiMetrics` needs — a
    /// distinct function rather than a flag parameter, for the same
    /// parameter-count reason `LocalMoneyScope` exists.
    static func netWorthCountingTowardFI(
        _ database: Database, _ moneyScope: LocalMoneyScope, asOf: String, now: Date
    ) throws -> Int64? {
        try netWorth(
            database, baseCurrency: moneyScope.baseCurrency, asOf: asOf, now: now,
            accountIds: try scopedAccountIds(database, scope: moneyScope.scope, countsTowardFiOnly: true)
        )
    }

    static func netWorthSeries(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: String, through: String, now: Date
    ) throws -> [(asOf: String, totalE4: Int64?)] {
        guard var cursor = PostgresDate.dateOnly(from: from, calendar: utcCalendar),
              let end = PostgresDate.dateOnly(from: through, calendar: utcCalendar)
        else { return [] }

        var results: [(String, Int64?)] = []
        while cursor <= end {
            let asOf = PostgresDate.dateOnlyString(cursor, calendar: utcCalendar)
            let total = try netWorth(database, moneyScope, asOf: asOf, now: now)
            results.append((asOf, total))
            cursor = utcCalendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        return results
    }

    /// Accounts (not deleted) in scope, mirroring the `EXISTS`/`NOT EXISTS
    /// household_accounts` predicate every scoped server function repeats.
    static func scopedAccountIds(
        _ database: Database, scope: PublicSchema.AccountScope, countsTowardFiOnly: Bool = false
    ) throws -> [String] {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        var sql = "SELECT id FROM accounts WHERE deleted_at IS NULL AND (\(scopeClause))"
        if countsTowardFiOnly { sql += " AND counts_toward_fi = 1" }
        return try String.fetchAll(database, sql: sql)
    }

    // MARK: - spending_by_category

    static func spendingByCategory(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: String, through: String
    ) throws -> [CategorySpendingLocal] {
        let rows = try LocalMoneyQueries.categorizedNativeTransactions(
            database, scope: moneyScope.scope, from: from, through: through, categoryKind: "expense"
        )
        let names = try LocalMoneyQueries.categoryNames(database)

        var accumulators: [String: RunningTotal] = [:]
        var order: [String] = []
        for row in rows {
            guard let categoryId = row.categoryId else { continue }
            if order.contains(categoryId) == false { order.append(categoryId) }
            var accumulator = accumulators[categoryId] ?? RunningTotal()
            try accumulator.add(abs(row.amountE4), from: row.currency, at: row.occurredDate) {
                try convert(database, amountE4: $0, from: $1, toCurrency: moneyScope.baseCurrency, date: $2)
            }
            accumulators[categoryId] = accumulator
        }

        let results = order.map { categoryId in
            // Optional chaining flattens `RunningTotal??` to `Int64?` here,
            // which is exactly the propagation money rule 5 wants: a
            // missing-rate row (`.result == nil`) must stay `nil`, never
            // become `0` — this dictionary entry is never actually absent,
            // since `order` and `accumulators` are populated together above.
            CategorySpendingLocal(
                categoryId: categoryId, categoryName: names[categoryId] ?? "",
                totalE4: accumulators[categoryId]?.result, currency: moneyScope.baseCurrency
            )
        }
        // "order by total desc nulls last" — the same tie-break Postgres leaves unspecified.
        return results.sorted { lhs, rhs in
            switch (lhs.totalE4, rhs.totalE4) {
            case let (left?, right?): return left > right
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    // MARK: - income_expense_series

    static func incomeExpenseSeries(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: String, through: String, granularity: String
    ) throws -> [IncomeExpensePointLocal] {
        let rows = try LocalMoneyQueries.categorizedNativeTransactions(
            database, scope: moneyScope.scope, from: from, through: through
        )

        var income: [String: RunningTotal] = [:]
        var expense: [String: RunningTotal] = [:]
        var order: [String] = []
        for row in rows {
            guard let occurredDate = PostgresDate.dateOnly(from: row.occurredDate, calendar: utcCalendar)
            else { continue }
            let bucketStart = granularity == "monthly" ? monthStart(occurredDate) : weekStart(occurredDate)
            let key = PostgresDate.dateOnlyString(bucketStart, calendar: utcCalendar)
            if order.contains(key) == false {
                order.append(key)
                // Postgres's GROUP BY emits both `income_e4` and `expense_e4`
                // for every bucket that has ANY transaction, conditionally
                // summing to `0` (not `nil`) on whichever side has no rows —
                // a bucket touched only by expenses still reports `income_e4
                // = 0`. Seeding both sides here the moment a bucket is first
                // seen, regardless of which side triggered it, is what makes
                // that true below (an absent dictionary entry would
                // otherwise read as "missing rate" via the optional chain).
                income[key] = RunningTotal()
                expense[key] = RunningTotal()
            }
            let convertRow: (Int64, String, String) throws -> Int64? = {
                try convert(database, amountE4: $0, from: $1, toCurrency: moneyScope.baseCurrency, date: $2)
            }
            try accumulate(row, into: &income, into: &expense, key: key, convert: convertRow)
        }

        return order.sorted().map {
            IncomeExpensePointLocal(bucketStart: $0, incomeE4: income[$0]?.result, expenseE4: expense[$0]?.result)
        }
    }

    private static func accumulate(
        _ row: NativeCategorizedTransaction, into income: inout [String: RunningTotal],
        into expense: inout [String: RunningTotal], key: String,
        convert: (Int64, String, String) throws -> Int64?
    ) throws {
        if row.amountE4 > 0 {
            var accumulator = income[key] ?? RunningTotal()
            try accumulator.add(row.amountE4, from: row.currency, at: row.occurredDate, convert: convert)
            income[key] = accumulator
        } else if row.amountE4 < 0 {
            var accumulator = expense[key] ?? RunningTotal()
            try accumulator.add(abs(row.amountE4), from: row.currency, at: row.occurredDate, convert: convert)
            expense[key] = accumulator
        }
    }

    // MARK: - savings_rate

    static func savingsRate(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: String, through: String
    ) throws -> Decimal? {
        let (income, expense) = try incomeAndExpense(database, moneyScope, from: from, through: through)
        guard let income, let expense, income != 0 else { return nil }
        return Decimal(income - expense) / Decimal(income)
    }

    static func incomeAndExpense(
        _ database: Database, _ moneyScope: LocalMoneyScope, from: String, through: String
    ) throws -> (income: Int64?, expense: Int64?) {
        let rows = try LocalMoneyQueries.categorizedNativeTransactions(
            database, scope: moneyScope.scope, from: from, through: through
        )
        var income = RunningTotal()
        var expense = RunningTotal()
        for row in rows {
            if row.amountE4 > 0 {
                try income.add(row.amountE4, from: row.currency, at: row.occurredDate) {
                    try convert(database, amountE4: $0, from: $1, toCurrency: moneyScope.baseCurrency, date: $2)
                }
            } else if row.amountE4 < 0 {
                try expense.add(abs(row.amountE4), from: row.currency, at: row.occurredDate) {
                    try convert(database, amountE4: $0, from: $1, toCurrency: moneyScope.baseCurrency, date: $2)
                }
            }
        }
        return (income.result, expense.result)
    }

    private static func netWorth(
        _ database: Database, baseCurrency: String, asOf: String, now: Date, accountIds: [String]
    ) throws -> Int64? {
        if accountIds.isEmpty { return 0 }
        var total: Int64 = 0
        for accountId in accountIds {
            guard let currency = try String.fetchOne(
                database, sql: "SELECT currency FROM accounts WHERE id = ?", arguments: [accountId]
            ) else { continue }
            guard let native = try LocalMoneyQueries.accountBalance(
                database, accountId: accountId, asOf: asOf, now: now
            ) else { return nil }
            guard let converted = try convert(
                database, amountE4: native, from: currency, toCurrency: baseCurrency, date: asOf
            ) else { return nil }
            total += converted
        }
        return total
    }
}
