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

        var displayValue = Decimal()
        var source = Decimal(amountE4) / Decimal(10_000)
        // Display rounding only, driven by the currency's minor unit — `.plain`
        // (half away from zero) matches the L1 rounding contract used
        // server-side in `fx_convert`, not NumberFormatter's own default
        // half-even rounding.
        NSDecimalRound(&displayValue, &source, currency.minorUnit, .plain)

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        formatter.locale = locale
        formatter.minimumFractionDigits = currency.minorUnit
        formatter.maximumFractionDigits = currency.minorUnit

        return formatter.string(from: displayValue as NSDecimalNumber) ?? "—"
    }
}
