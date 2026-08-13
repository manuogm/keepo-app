import Foundation

/// EUR-pivot conversion using whatever rates are cached on-device — the
/// offline counterpart to the server's `fx_convert(amount_e4, from, to, date)`,
/// minus the historical-date resolution (this only ever has "latest known"
/// rate per currency to work with, via `FxRateRepository.fetchLatestRates`).
/// Same same-currency short-circuit `fx_convert` has, and for the identical
/// reason: converting a currency to itself must never depend on a rate row
/// existing at all. Rounds half away from zero at the final step, matching
/// the server's own rounding contract exactly (keepo-local-first-plan.md).
public enum LocalFxConvert {
    /// `rates` never carries an "EUR" entry — `fx_rates` itself never gets
    /// one, EUR's rate to EUR being structurally 1 — so EUR is resolved
    /// here rather than requiring every caller to special-case it.
    public static func convert(
        _ amountE4: Int64, from fromCurrency: String, to toCurrency: String, rates: [String: Decimal]
    ) -> Int64? {
        if fromCurrency == toCurrency { return amountE4 }
        guard
            let fromRate = rate(for: fromCurrency, in: rates), let toRate = rate(for: toCurrency, in: rates),
            fromRate != 0
        else { return nil }

        var rounded = Decimal()
        var scaled = Decimal(amountE4) / fromRate * toRate
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private static func rate(for currency: String, in rates: [String: Decimal]) -> Decimal? {
        currency == "EUR" ? 1 : rates[currency]
    }
}
