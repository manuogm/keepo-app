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

    /// Accounts (not deleted, not archived) in scope, mirroring the
    /// `EXISTS`/`NOT EXISTS household_accounts` predicate every scoped
    /// server function repeats, plus `net_worth()`'s own `archived_at is
    /// null` filter (20260820100000_archived_account_net_worth_exclusion).
    static func scopedAccountIds(_ database: Database, scope: PublicSchema.AccountScope) throws -> [String] {
        let scopeClause = LocalMoneyQueries.scopeFilterSQL(scope, accountIdColumn: "id")
        let sql = "SELECT id FROM accounts WHERE deleted_at IS NULL AND archived_at IS NULL AND (\(scopeClause))"
        return try String.fetchAll(database, sql: sql)
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
