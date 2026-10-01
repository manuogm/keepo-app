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
    /// From here up, a figure is read at a glance: `$56.8K`, not
    /// `$56,846.50`.
    public static let shortThreshold: Decimal = 1000

    /// Money as the app shows it everywhere a person reads it: exact below
    /// a thousand, the locale's short form from a thousand up — `$842.37`,
    /// `-$56.8K`, `$123.5B`. One decimal at most (a trailing `.0` is
    /// dropped: `$1K`), rounded to nearest, so a figure is never shown as
    /// less than it is by the rounding alone.
    ///
    /// **`exact: true`** is for the few places where the figure is a
    /// record or a check rather than a glance: an export, a capture
    /// notification, a conflict between two versions that may differ by
    /// cents, and VoiceOver, which reads the figure a sighted user can open
    /// the account to see. Amount fields never come through here.
    ///
    /// - Parameter amountE4: `nil` for a value that cannot be computed (e.g. a missing
    ///   FX rate). Renders as `—`, never `0` — a missing rate is not a zero balance.
    public static func format(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current,
        signStyle: MoneySignStyle = .standard,
        exact: Bool = false
    ) -> String {
        guard let amountE4 else { return "—" }
        let value = displayValue(drawnAmount(amountE4, signStyle: signStyle), minorUnit: currency.minorUnit)
        let rendered = !exact && isShort(value)
            ? short(value, currency: currency, locale: locale)
            : currencyFormatter(currency: currency, locale: locale).string(from: value as NSDecimalNumber) ?? "—"
        return prefix(for: amountE4, signStyle: signStyle) + rendered
    }

    /// Same rendering as `format`, split at the locale's decimal separator so
    /// a caller (e.g. a hero balance) can give the fractional part its own,
    /// smaller styling. `fraction` includes the separator itself (e.g.
    /// ".56") and is empty for a zero-decimal currency, a missing value, or
    /// a short figure — "$56.8K" has no cents to set apart, and splitting
    /// it would draw ".8K" small.
    public static func formatSplit(
        _ amountE4: Int64?,
        currency: CurrencyInfo,
        locale: Locale = .current,
        signStyle: MoneySignStyle = .standard
    ) -> (whole: String, fraction: String) {
        guard let amountE4 else { return ("—", "") }
        let full = format(amountE4, currency: currency, locale: locale, signStyle: signStyle)
        if isShort(amountE4, minorUnit: currency.minorUnit) { return (full, "") }
        let separator = currencyFormatter(currency: currency, locale: locale).decimalSeparator
        return split(full, separator: separator, minorUnit: currency.minorUnit)
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

    /// `format` for a tile with room for a magnitude and nothing else: the
    /// collapsed Cashflow widget's two direction totals, and Currency
    /// Exposure's, which sit at the ends of a bar roughly 70 points wide.
    /// The same short form from a thousand up; below it, the figure also
    /// loses its cents (`$842`), which `$842.37` would not fit.
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
        let value = Decimal(drawnAmount(amountE4, signStyle: signStyle)) / Decimal(10_000)
        let rendered = isShort(value)
            ? short(value, currency: currency, locale: locale)
            : value.formatted(Decimal.FormatStyle.Currency(code: currency.code, locale: locale)
                .precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
        return prefix(for: amountE4, signStyle: signStyle) + rendered
    }

    /// `format`'s short form with no symbol and no sign — "56.8K" — for
    /// `AmountField`, which draws both itself ahead of the number, exactly
    /// as it does for the full figure.
    public static func compactFigure(_ amountE4: Int64, locale: Locale = .current) -> String {
        let value = Decimal(amountE4.magnitude) / Decimal(10_000)
        return value.formatted(
            .number.notation(.compactName).precision(.fractionLength(0 ... 1))
                .rounded(rule: .toNearestOrAwayFromZero).locale(locale)
        )
    }

    /// Whether `format` shortens this figure. `AmountField` asks, so the
    /// form rests on the same short form as every list — by minor unit
    /// alone, since the field may not know its currency yet.
    public static func isShort(_ amountE4: Int64, minorUnit: Int) -> Bool {
        isShort(displayValue(amountE4, minorUnit: minorUnit))
    }

    private static func isShort(_ value: Decimal) -> Bool {
        abs(value) >= shortThreshold
    }

    /// ICU places the suffix, so a locale that trails its symbol still reads
    /// correctly ("1,2 Mio. €") — appending a `K` to a formatted string
    /// would not. Rounded to nearest, so 999,960 reads "$1M", not "$1000K".
    private static func short(_ value: Decimal, currency: CurrencyInfo, locale: Locale) -> String {
        value.formatted(
            Decimal.FormatStyle.Currency(code: currency.code, locale: locale)
                .notation(.compactName).precision(.fractionLength(0 ... 1))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
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

    /// The figure a machine reads: signed, `.` as the decimal point, no
    /// grouping and no symbol — `-1234.50` — rounded to the currency's minor
    /// unit by the same rule the screen uses, so an export and the ledger can
    /// never disagree by a cent. For file formats (CSV, a spreadsheet cell),
    /// never for anything a person reads on screen.
    public static func plain(_ amountE4: Int64, currency: CurrencyInfo) -> String {
        let value = displayValue(amountE4, minorUnit: currency.minorUnit)
        let formatter = FormatterCache.editable(minorUnit: currency.minorUnit, locale: .posix)
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
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

    private static func displayValue(_ amountE4: Int64, minorUnit: Int) -> Decimal {
        var displayValue = Decimal()
        var source = Decimal(amountE4) / Decimal(10_000)
        // Display rounding only, driven by the currency's minor unit — `.plain`
        // (half away from zero) matches the L1 rounding contract used
        // server-side in `fx_convert`, not NumberFormatter's own default
        // half-even rounding.
        NSDecimalRound(&displayValue, &source, minorUnit, .plain)
        return displayValue
    }

    private static func currencyFormatter(currency: CurrencyInfo, locale: Locale) -> NumberFormatter {
        FormatterCache.currency(code: currency.code, minorUnit: currency.minorUnit, locale: locale)
    }
}
