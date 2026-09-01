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
    /// Wallet's `Amount` capture parameter is a formatted currency string
    /// (e.g. "$1.06") — strips everything but digits, a leading minus, and
    /// the locale's decimal separator before delegating to `parse(_:)`. The
    /// stripped symbol is never used to infer currency — money rule: a
    /// captured transaction's currency comes from the mapped account, the
    /// symbol is a mismatch check only (app-architecture.md §4).
    static func parseFormattedCurrency(_ text: String, locale: Locale = .current) -> Int64? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let allowed = CharacterSet(charactersIn: "0123456789-" + decimalSeparator)
        let stripped = String(text.unicodeScalars.filter { allowed.contains($0) })
        return parse(stripped, locale: locale)
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
