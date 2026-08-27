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

/// How a figure's sign is *drawn* — never how it is stored. Money rule 1
/// (`amount` is signed, never re-signed in application code) is untouched
/// by this: every case below reads the same stored `Int64` and only decides
/// what glyph precedes it.
public enum MoneySignStyle: Sendable, Equatable {
    /// The stored sign, rendered as the locale does. The default for
    /// anything that can be a balance or a total, where a minus is real
    /// information ("this account is overdrawn").
    case standard
    /// Ledger style, for a transaction row whose surrounding context
    /// already says which direction the money went: an outflow drops its
    /// minus sign, an inflow gains an explicit `+`.
    case ledger
    /// The figure alone, unsigned — for a place where a **label** already
    /// names the direction. Cashflow's collapsed tile puts "Money In" and
    /// "Money Out" directly above their own totals, on opposite ends of a
    /// bar that also diverges from the centre; a `+` on one of them and
    /// nothing on the other is a third answer to a question already
    /// answered twice.
    ///
    /// Differs from `ledger` only in dropping that `+`. Both draw the
    /// magnitude, neither changes what is stored (money rule 1).
    case magnitude
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
        locale: Locale = .current,
        signStyle: MoneySignStyle = .standard
    ) -> String {
        guard let amountE4 else { return "—" }
        let formatter = currencyFormatter(currency: currency, locale: locale)
        let value = displayValue(drawnAmount(amountE4, signStyle: signStyle), currency: currency)
        let rendered = formatter.string(from: value as NSDecimalNumber) ?? "—"
        return prefix(for: amountE4, signStyle: signStyle) + rendered
    }

    /// Same rendering as `format`, split at the locale's decimal separator so
    /// a caller (e.g. a hero balance) can give the fractional part its own,
    /// smaller styling. `fraction` includes the separator itself (e.g.
    /// ".56") and is empty for a zero-decimal currency or a missing value —
    /// callers render `whole` alone in that case.
    public static func formatSplit(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current,
        signStyle: MoneySignStyle = .standard
    ) -> (whole: String, fraction: String) {
        guard let amountE4 else { return ("—", "") }
        let formatter = currencyFormatter(currency: currency, locale: locale)
        let value = displayValue(drawnAmount(amountE4, signStyle: signStyle), currency: currency)
        let full = prefix(for: amountE4, signStyle: signStyle)
            + (formatter.string(from: value as NSDecimalNumber) ?? "—")

        return split(full, separator: formatter.decimalSeparator, minorUnit: currency.minorUnit)
    }

    /// Splits an already-rendered money string at its decimal separator —
    /// the same rule `formatSplit` applies, exposed for the one caller that
    /// starts from an editable string rather than an `Int64` (`AmountField`,
    /// which renders what the user is typing at the same big-whole/
    /// small-fraction weighting as a formatted balance).
    public static func split(
        _ rendered: String, separator: String?, minorUnit: Int
    ) -> (whole: String, fraction: String) {
        guard minorUnit > 0, let separator, let range = rendered.range(of: separator, options: .backwards)
        else { return (rendered, "") }
        return (String(rendered[..<range.lowerBound]), String(rendered[range.lowerBound...]))
    }

    /// The same figure at a glance — `$4.2K` where `format` would give
    /// `$4,231.87`.
    ///
    /// For the one place a tile has room for a magnitude and nothing else:
    /// the collapsed Cashflow widget's two direction totals, which sit at
    /// the ends of a bar roughly 70 points wide. The full form does not fit
    /// there, and letting `minimumScaleFactor` shrink it until it does is
    /// worse than rounding it — nobody reads a total to the cent off a 2×2
    /// tile, and a figure at 60% of its intended size is the tile's own
    /// typography breaking down.
    ///
    /// Two rules, both deliberate:
    ///
    /// - **Never a fractional currency unit.** Under a thousand the figure
    ///   loses its cents (`$842`), because a tile rendering `$842.37` beside
    ///   `$4.2K` would be exact in one column and approximate in the other,
    ///   and the reader has no way to know which.
    /// - **Compact only past a thousand**, where the locale's own short form
    ///   takes over. ICU places the suffix itself, so a locale that trails
    ///   its currency symbol still reads correctly — appending a `K` to an
    ///   already-formatted string would not.
    ///
    /// `nil` is `—`, exactly as `format` renders it. Money rule 5 gets no
    /// exception for being short of space.
    public static func compact(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current,
        signStyle: MoneySignStyle = .standard
    ) -> String {
        guard let amountE4 else { return "—" }
        let drawn = Decimal(drawnAmount(amountE4, signStyle: signStyle)) / Decimal(10_000)
        let style = Decimal.FormatStyle.Currency(code: currency.code, locale: locale)
        let rendered = abs(drawn) < 1000
            ? drawn.formatted(style.precision(.fractionLength(0)))
            : drawn.formatted(style.notation(.compactName).precision(.fractionLength(0 ... 1)))
        return prefix(for: amountE4, signStyle: signStyle) + rendered
    }

    /// The locale's symbol for this currency ("$", "€", "¥") — used by the
    /// amount fields that draw the symbol themselves instead of letting the
    /// formatter place it. Falls back to the code, which is never wrong,
    /// only less compact.
    public static func symbol(for currency: CurrencyInfo, locale: Locale = .current) -> String {
        currencyFormatter(currency: currency, locale: locale).currencySymbol ?? currency.code
    }

    /// The locale's decimal separator — `AmountField` needs it to split what
    /// the user is typing, and nothing else should be constructing a
    /// `NumberFormatter` just to ask.
    public static func decimalSeparator(locale: Locale = .current) -> String {
        locale.decimalSeparator ?? "."
    }

    private static func drawnAmount(_ amountE4: Int64, signStyle: MoneySignStyle) -> Int64 {
        switch signStyle {
        case .standard: return amountE4
        // `Int64(clamping:)`, not `abs()` — `abs(Int64.min)` traps. No real
        // balance is anywhere near that, but a formatter must not be the
        // thing that crashes on absurd input.
        case .ledger, .magnitude: return Int64(clamping: amountE4.magnitude)
        }
    }

    private static func prefix(for amountE4: Int64, signStyle: MoneySignStyle) -> String {
        signStyle == .ledger && amountE4 > 0 ? "+" : ""
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
        FormatterCache.currency(code: currency.code, minorUnit: currency.minorUnit, locale: locale)
    }
}
