import Foundation

/// The one place a user-typed amount string becomes a `Decimal` — parallel
/// to `MoneyFormatter` being the one place a `Decimal` becomes display text.
/// Fixes a real Phase 1 bug: `OnboardingView` used `Decimal(string:)`
/// directly, which is period-decimal only regardless of locale, so typing
/// "1250,75" on any comma-decimal locale silently failed to parse.
public enum AmountParser {
    /// - Parameter text: raw field contents, e.g. "1250.75" or "1250,75".
    /// - Returns: `nil` for empty or unparseable input — never `0`, so the
    ///   caller can distinguish "not entered yet" from "entered as zero."
    public static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
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
}

/// `AmountParser`'s missing inverse — the one place a `Decimal` becomes
/// editable text in a form field. `TransactionFormView`'s edit-mode prefill
/// used `"\(abs(amount))"` directly, which is always period-decimal
/// regardless of locale — the exact `AmountParser`-motivating bug in
/// reverse: editing an expense on a comma-decimal locale prefilled "12.50"
/// into a field where only "12,50" parses back out.
public enum AmountFormatter {
    /// - Parameter amount: always rendered unsigned — sign is a property of
    ///   the transaction kind the caller already tracks, never the field.
    public static func editableString(_ amount: Decimal, minorUnit: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minorUnit
        formatter.maximumFractionDigits = minorUnit
        let magnitude = amount.magnitude
        return formatter.string(from: magnitude as NSDecimalNumber) ?? "\(magnitude)"
    }
}
