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
    ///
    /// **Returns units of `currency` per one euro** — 1.1669 means a euro
    /// buys 1.1669 dollars. That is the shape Frankfurter answers `?base=EUR`
    /// with, and the shape `convert` below needs: divide out of the source
    /// currency into euros, multiply into the target. EUR is 1 by
    /// construction, which is why `fx_rates` never holds a row for it.
    /// `cache` is a per-read memo (`LocalFxCache`) — see its own header for
    /// why it exists and why it must not outlive the `dbQueue.read` block
    /// that made it. Omitting it is exactly the old behaviour: one `SELECT`
    /// per call.
    static func fxRateOn(
        _ database: Database, currency: String, date: String, cache: LocalFxCache? = nil
    ) throws -> Decimal? {
        if currency == "EUR" { return 1 }
        guard let cache else { return try loadFxRate(database, currency: currency, date: date) }
        return try cache.rate(database, currency: currency, date: date, load: loadFxRate)
    }

    private static func loadFxRate(_ database: Database, currency: String, date: String) throws -> Decimal? {
        guard let rateString = try String.fetchOne(
            database,
            sql: """
            SELECT units_per_eur FROM fx_rates WHERE currency = ? AND rate_date <= ?
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
        _ database: Database, amountE4: Int64, from: String, toCurrency: String, date: String,
        cache: LocalFxCache? = nil
    ) throws -> Int64? {
        if from == toCurrency { return amountE4 }
        guard let fromRate = try fxRateOn(database, currency: from, date: date, cache: cache),
              let toRate = try fxRateOn(database, currency: toCurrency, date: date, cache: cache)
        else { return nil }
        var rates: [String: Decimal] = [:]
        if from != "EUR" { rates[from] = fromRate }
        if toCurrency != "EUR" { rates[toCurrency] = toRate }
        return LocalFxConvert.convert(amountE4, from: from, to: toCurrency, rates: rates)
    }

    // MARK: - net_worth(scope) / net_worth_series

    /// Port of `net_worth(p_scope)` at an arbitrary date — server-side this
    /// is always "today". L4 generalized it because the dashboard needs the
    /// same computation at each bucket's end and there is no on-device
    /// `net_worth_daily` to read instead (the plan's explicit call: a local
    /// store can afford to recompute).
    static func netWorth(
        _ database: Database, _ moneyScope: LocalMoneyScope, asOf: String, now: Date,
        cache: LocalFxCache? = nil
    ) throws -> Int64? {
        try sum(
            try LocalMoneyQueries.accountBalances(
                database, matching: LocalMoneyQueries.inScopeFilter(moneyScope.scope), asOf: asOf, now: now
            ),
            database, into: moneyScope.baseCurrency, asOf: asOf, cache: cache ?? LocalFxCache()
        )
    }

    /// Converts each native balance into `baseCurrency` and adds them up,
    /// propagating money rule 5: one unresolvable rate makes the whole total
    /// `nil`, never a figure that quietly omits an account.
    ///
    /// Conversion is once per account — each balance is single-currency, so
    /// converting the already-aggregated native figure is exact by
    /// construction and matches what Postgres does (see `LocalMoneyQueries`'
    /// header on conversion granularity).
    static func sum(
        _ balances: [NativeAccountBalance], _ database: Database,
        into baseCurrency: String, asOf: String, cache: LocalFxCache
    ) throws -> Int64? {
        var total: Int64 = 0
        for balance in balances {
            guard let converted = try convert(
                database, amountE4: balance.balanceE4, from: balance.currency,
                toCurrency: baseCurrency, date: asOf, cache: cache
            ) else { return nil }
            total += converted
        }
        return total
    }

}
