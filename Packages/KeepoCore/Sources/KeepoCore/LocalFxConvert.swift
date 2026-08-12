import Foundation

/// EUR-pivot conversion using whatever rates are cached on-device — the
/// offline counterpart to the server's `fx_convert(amount, from, to, date)`,
/// minus the historical-date resolution (this only ever has "latest known"
/// rate per currency to work with, via `FxRateRepository.fetchLatestRates`).
/// Same same-currency short-circuit `fx_convert` has, and for the identical
/// reason: converting a currency to itself must never depend on a rate row
/// existing at all.
public enum LocalFxConvert {
    /// `rates` never carries an "EUR" entry — `fx_rates` itself never gets
    /// one, EUR's rate to EUR being structurally 1 — so EUR is resolved
    /// here rather than requiring every caller to special-case it.
    public static func convert(
        _ amount: Decimal, from fromCurrency: String, to toCurrency: String, rates: [String: Decimal]
    ) -> Decimal? {
        if fromCurrency == toCurrency { return amount }
        guard
            let fromRate = rate(for: fromCurrency, in: rates), let toRate = rate(for: toCurrency, in: rates),
            fromRate != 0
        else { return nil }
        return amount / fromRate * toRate
    }

    private static func rate(for currency: String, in rates: [String: Decimal]) -> Decimal? {
        currency == "EUR" ? 1 : rates[currency]
    }
}
