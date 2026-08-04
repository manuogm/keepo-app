import Foundation

public extension Decimal {
    /// Decodes a Postgres `numeric` column. `supabase-swift` must hand this a `String`,
    /// never a `Double` — a `Double` has already lost precision by the time it exists.
    init?(supabaseNumeric string: String) {
        self.init(string: string)
    }
}

/// The single place money renders as text. Every screen calls this — never a
/// per-screen `NumberFormatter` — so a rounding or missing-rate rule only has one
/// place it can be wrong.
public enum MoneyFormatter {
    /// - Parameter amount: `nil` for a value that cannot be computed (e.g. a missing
    ///   FX rate). Renders as `—`, never `0` — a missing rate is not a zero balance.
    public static func format(
        _ amount: Decimal?,
        currency: CurrencyInfo,
        locale: Locale = .current
    ) -> String {
        guard let amount else { return "—" }

        var rounded = Decimal()
        var source = amount
        // Display rounding only, driven by the currency's minor unit — the stored
        // value keeps its full numeric(20,4) precision untouched.
        NSDecimalRound(&rounded, &source, currency.minorUnit, .plain)

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        formatter.locale = locale
        formatter.minimumFractionDigits = currency.minorUnit
        formatter.maximumFractionDigits = currency.minorUnit

        return formatter.string(from: rounded as NSDecimalNumber) ?? "—"
    }
}
