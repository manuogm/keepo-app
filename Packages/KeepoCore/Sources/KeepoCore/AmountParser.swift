import Foundation

/// The one place a user-typed amount string becomes an `Int64` e4 amount —
/// parallel to `MoneyFormatter` being the one place an `Int64` becomes
/// display text. Fixes a real Phase 1 bug: `OnboardingView` used
/// `Decimal(string:)` directly, which is period-decimal only regardless of
/// locale, so typing "1250,75" on any comma-decimal locale silently failed
/// to parse. Parsing still goes through `Decimal` (locale-aware, exact) —
/// only the final result is scaled to the fixed-point `Int64` the rest of
/// the app works in.
public enum AmountParser {
    /// - Parameter text: raw field contents, e.g. "1250.75" or "1250,75".
    /// - Returns: `nil` for empty or unparseable input — never `0`, so the
    ///   caller can distinguish "not entered yet" from "entered as zero."
    public static func parse(_ text: String, locale: Locale = .current) -> Int64? {
        parseDecimal(text, locale: locale).flatMap(toAmountE4)
    }

    /// For ratio-typed fields (withdrawal rate, real return rate) that stay
    /// `Decimal` rather than fixed-point e4 money — same locale-aware
    /// parsing as `parse(_:)`, without the ×10000 scaling.
    public static func parseRate(_ text: String, locale: Locale = .current) -> Decimal? {
        parseDecimal(text, locale: locale)
    }

    private static func parseDecimal(_ text: String, locale: Locale) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let formatter = FormatterCache.parsing(locale: locale)
        if let number = formatter.number(from: trimmed) as? NSDecimalNumber {
            return number.decimalValue
        }

        // Fallback: a period-decimal string typed on a comma-decimal locale
        // (or vice versa) — e.g. muscle memory from another app. iOS's
        // decimalPad keyboard already shows the locale-correct separator,
        // so this is a safety net for pasted or habit-typed input, not the
        // primary path.
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Scales a parsed `Decimal` to the fixed-point e4 `Int64`, rounding
    /// half away from zero (the L1 rounding contract) — a user can type more
    /// than 4 decimal digits even though the app only stores 4.
    private static func toAmountE4(_ decimal: Decimal) -> Int64? {
        var rounded = Decimal()
        var scaled = decimal * 10_000
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

public extension AmountParser {
    /// Wallet's `Amount` capture parameter is a **machine-formatted**
    /// currency string — "$1.06", "1.234,56 €", "CHF 1'234.56" — and that
    /// makes it a different problem from `parse(_:locale:)` above, which
    /// reads what a person typed on the locale's own decimalPad.
    ///
    /// **This function never consults a locale, deliberately.** It used to
    /// take its decimal separator from `Locale.current`, which is a 100×
    /// money bug the moment the string's convention and the device's differ:
    /// `$1.06` on an `es_ES` device had its `.` stripped as grouping and was
    /// captured as **106**. Nobody typed this string, so the device is the
    /// wrong authority — the convention is read out of the string itself,
    /// which is correct whichever way iOS formatted it.
    ///
    /// The symbol is discarded here. Detecting the currency from it — and
    /// acting on a mismatch with the mapped account's — is the multi-currency
    /// workstream, which is where the `original_amount`/`original_currency`
    /// columns that give a detected currency somewhere to live are added.
    ///
    /// - Returns: `nil` for a string carrying no ASCII digits. Non-Latin
    ///   digit shapes (Arabic-Indic and the rest) are a known, deliberate
    ///   boundary: they fail loudly here rather than parsing to something
    ///   wrong, and the capture surfaces "couldn't read the amount".
    static func parseFormattedCurrency(_ text: String) -> Int64? {
        guard let plain = plainDecimalString(fromFormatted: text) else { return nil }
        return parse(plain, locale: .posix)
    }
}

private extension AmountParser {
    /// Reduces a formatted currency string to a plain POSIX decimal string
    /// ("-1234.56"), inferring which of `.` and `,` is the decimal point
    /// from the shape of the string.
    static func plainDecimalString(fromFormatted text: String) -> String? {
        let isNegative = text.contains { $0 == "-" || $0 == "\u{2212}" }

        // Everything that is not an ASCII digit or one of the two separator
        // characters is noise: the symbol or code ("$", "€", "CHF", "kr"),
        // the sign (already read above), and every grouping mark that is
        // never a decimal point — the Swiss apostrophe in `1'234.56`, and
        // the plain, non-breaking and narrow spaces France, Sweden and
        // Hungary group with.
        let figures = String(text.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," })
        guard figures.contains(where: \.isNumber) else { return nil }

        let magnitude: String
        if let decimalIndex = decimalSeparatorIndex(in: figures) {
            let whole = String(figures[..<decimalIndex].filter(\.isNumber))
            // Everything after the *last* separator is digits by
            // construction, so no second filter is needed here.
            let fraction = String(figures[figures.index(after: decimalIndex)...])
            magnitude = (whole.isEmpty ? "0" : whole) + "." + fraction
        } else {
            magnitude = figures.filter(\.isNumber)
        }
        return isNegative ? "-" + magnitude : magnitude
    }

    /// The index of the separator that is the decimal point, or `nil` when
    /// every separator in the string is a grouping mark.
    static func decimalSeparatorIndex(in figures: String) -> String.Index? {
        guard let last = figures.lastIndex(where: { $0 == "." || $0 == "," }) else { return nil }

        // Both conventions present: the rightmost is the decimal point and
        // the other is grouping. True of every locale, and the only case
        // that needs no digit counting — `1.234,56` and `1,234.56` are each
        // unambiguous the moment both marks are in play.
        if figures.contains(".") && figures.contains(",") { return last }

        // One convention used more than once is grouping: `1.234.567`.
        guard figures.filter({ $0 == "." || $0 == "," }).count == 1 else { return nil }

        // A single separator with one or two digits behind it is a decimal
        // point; with exactly three it is grouping (`1.234` is one thousand
        // two hundred thirty-four). That is only a judgement call because
        // the currency is unknown here: **no supported currency has 1 or 3
        // minor digits** — every row in `currencies` is 0 or 2 — so three
        // trailing digits cannot be a fraction, and one or two cannot be a
        // group. Anything else (`1.2345`, a trailing `1.`) is not a shape
        // any formatter produces, and is treated as grouping.
        let fractionDigits = figures.distance(from: figures.index(after: last), to: figures.endIndex)
        return (1...2).contains(fractionDigits) ? last : nil
    }
}

/// `AmountParser`'s missing inverse — the one place an `Int64` e4 amount
/// becomes editable text in a form field. `TransactionFormView`'s edit-mode
/// prefill used `"\(abs(amount))"` directly, which is always period-decimal
/// regardless of locale — the exact `AmountParser`-motivating bug in
/// reverse: editing an expense on a comma-decimal locale prefilled "12.50"
/// into a field where only "12,50" parses back out.
public enum AmountFormatter {
    /// - Parameter amountE4: rendered unsigned by default — for a transaction
    ///   the sign is a property of the kind the caller already tracks, never
    ///   of the field, and prefilling "-12.50" into an expense field invites
    ///   the user to negate it a second time.
    /// - Parameter signed: pass `true` for a figure whose sign is genuinely
    ///   the user's to see and change — an ACCOUNT BALANCE, where negative
    ///   means overdrawn or owed. Dropping the sign there is a real money bug:
    ///   the field round-trips through `AmountParser`, so an unsigned prefill
    ///   of an overdrawn account silently saves it back as a positive balance.
    public static func editableString(
        _ amountE4: Int64, minorUnit: Int, locale: Locale = .current, signed: Bool = false
    ) -> String {
        let value = signed
            ? Decimal(amountE4) / Decimal(10_000)
            : Decimal(amountE4.magnitude) / Decimal(10_000)
        let formatter = FormatterCache.editable(minorUnit: minorUnit, locale: locale)
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

public extension AmountFormatter {
    /// Field text for a value that is still a `Decimal` — the pop-up
    /// calculator's running expression and its result, which never become an
    /// e4 amount here. The form the result lands in parses it back through
    /// `AmountParser` on save like any typed string, so the round trip is
    /// the same one every other amount takes.
    ///
    /// The `decimal:` label is load-bearing. Unlabelled, this overload wins
    /// against the `Int64` one for every literal call site — `Decimal` is
    /// `ExpressibleByIntegerLiteral` too — and silently reinterprets an e4
    /// amount as a plain number: `editableString(-425_000, minorUnit: 2)`
    /// would return "-425000.00" instead of "42.50". Two overloads that
    /// differ only in a numeric type are a trap; a label is the fix.
    static func editableString(decimal value: Decimal, minorUnit: Int, locale: Locale = .current) -> String {
        let formatter = FormatterCache.editable(minorUnit: minorUnit, locale: locale)
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}
