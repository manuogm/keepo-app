import Foundation

public extension Decimal {
    /// Decodes a Postgres `numeric` column — still used for the ratio
    /// columns that stayed `numeric` through L1 (`withdrawal_rate`,
    /// `real_return_rate`, `percent_progress`, `years_to_fi`, FX rates
    /// themselves). `supabase-swift` must hand this a `String`, never a
    /// `Double` — a `Double` has already lost precision by the time it
    /// exists.
    init?(supabaseNumeric string: String) {
        self.init(string: string)
    }
}

/// The single place money renders as text. Every screen calls this — never a
/// per-screen `NumberFormatter` — so a rounding or missing-rate rule only has one
/// place it can be wrong.
///
/// Money is a fixed-point `Int64` at scale 4 (see keepo-local-first-plan.md,
/// "Money representation") — `123400` is 12.34, regardless of currency. The
/// display divisor is `10^minorUnit`, never a constant `10000`: JPY has
/// `minorUnit == 0`, so `1000000` (still e4-scaled) displays as ¥100.
public enum MoneyFormatter {
    /// - Parameter amountE4: `nil` for a value that cannot be computed (e.g. a missing
    ///   FX rate). Renders as `—`, never `0` — a missing rate is not a zero balance.
    public static func format(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current
    ) -> String {
        guard let amountE4 else { return "—" }
        let formatter = currencyFormatter(currency: currency, locale: locale)
        return formatter.string(from: displayValue(amountE4, currency: currency) as NSDecimalNumber) ?? "—"
    }

    /// Same rendering as `format`, split at the locale's decimal separator so
    /// a caller (e.g. a hero balance) can give the fractional part its own,
    /// smaller styling. `fraction` includes the separator itself (e.g.
    /// ".56") and is empty for a zero-decimal currency or a missing value —
    /// callers render `whole` alone in that case.
    public static func formatSplit(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current
    ) -> (whole: String, fraction: String) {
        guard let amountE4 else { return ("—", "") }
        let formatter = currencyFormatter(currency: currency, locale: locale)
        let full = formatter.string(from: displayValue(amountE4, currency: currency) as NSDecimalNumber) ?? "—"

        guard currency.minorUnit > 0, let separator = formatter.decimalSeparator,
            let range = full.range(of: separator, options: .backwards)
        else { return (full, "") }
        return (String(full[..<range.lowerBound]), String(full[range.lowerBound...]))
    }

    private static func displayValue(_ amountE4: Int64, currency: CurrencyInfo) -> Decimal {
        var displayValue = Decimal()
        var source = Decimal(amountE4) / Decimal(10_000)
        // Display rounding only, driven by the currency's minor unit — `.plain`
        // (half away from zero) matches the L1 rounding contract used
        // server-side in `fx_convert`, not NumberFormatter's own default
        // half-even rounding.
        NSDecimalRound(&displayValue, &source, currency.minorUnit, .plain)
        return displayValue
    }

    private static func currencyFormatter(currency: CurrencyInfo, locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        formatter.locale = locale
        formatter.minimumFractionDigits = currency.minorUnit
        formatter.maximumFractionDigits = currency.minorUnit
        return formatter
    }
}
