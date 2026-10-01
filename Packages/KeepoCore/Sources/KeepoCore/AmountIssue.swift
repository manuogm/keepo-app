import Foundation

/// Why a typed amount cannot be saved, told apart so the form can say which.
///
/// The transaction form used to answer every one of these with a single
/// "Enter a valid amount." at the bottom of the card, and only after Save
/// was tapped. The field is where the mistake is, and "valid" names nothing
/// the user can go and fix — so the form now reads the text as it is typed
/// and shows the reason under the amount itself.
///
/// Classification lives here, beside `AmountParser`, rather than in the
/// view: it is the same reading of the same string that `parse` does, and
/// two readings of one string are how "the error says numeric but it saved
/// anyway" happens.
public enum AmountIssue: Equatable, Sendable {
    /// A letter, a symbol, or a second decimal point — nothing a parse can
    /// read. Also a lone separator once the entry is final.
    case notNumeric
    /// A leading minus. A transaction's sign is its kind, never the field's.
    case negative
    /// Parses, but is nothing — including an amount that rounds to nothing
    /// in the currency's own precision ("0.001" dollars).
    case zero
    /// More whole digits than `maximumWholeDigits`, or more than the e4
    /// fixed-point store can hold (`AmountParser.toAmountE4`).
    case tooLarge

    /// 999,999,999,999 — nothing a personal ledger holds needs a thirteenth
    /// digit, and a figure this long already needs a whole line of the form
    /// to be read. `AmountField` refuses the keystroke that would cross it,
    /// so in practice this only ever reports a paste or a calculator result.
    public static let maximumWholeDigits = 12

    /// Whether `text` has more whole digits than `maximumWholeDigits`. Counts
    /// digits before the decimal point, so grouping marks and the fraction
    /// never count against it.
    public static func exceedsMaximum(_ text: String, locale: Locale = .current) -> Bool {
        let separators = AmountSeparators(locale: locale)
        let whole = text.firstIndex(where: separators.isDecimal).map { text[..<$0] } ?? text[...]
        return whole.filter { $0.isASCII && $0.isNumber }.count > maximumWholeDigits
    }

    /// - Parameter isFinal: `false` while the user may still be typing.
    ///   "0" and "." are the first keystrokes of "0.50" and ".5", so they
    ///   are only problems once the entry is being committed; flagging them
    ///   mid-typing would shake the card at a user who has done nothing
    ///   wrong. A letter or a minus is wrong whatever comes next, so those
    ///   report either way.
    /// - Returns: `nil` for empty text — "not entered yet" is not an error,
    ///   and the form's Save gate already covers it.
    public static func of(
        _ text: String, minorUnit: Int? = nil, isFinal: Bool, locale: Locale = .current
    ) -> AmountIssue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let isNegative = trimmed.first == "-" || trimmed.first == "\u{2212}"
        let body = isNegative ? String(trimmed.dropFirst()) : trimmed
        let separators = AmountSeparators(locale: locale)

        // Checked before the sign, so "-abc" reads as what is actually
        // wrong with it. The character gate is not decoration: the parse's
        // POSIX fallback reads a numeric *prefix*, so "12abc" would
        // otherwise come back as 12 and be saved.
        guard body.allSatisfy({ ($0.isASCII && $0.isNumber) || separators.contains($0) }),
              body.filter({ separators.isDecimal($0) }).count <= 1
        else { return .notNumeric }

        if isNegative { return .negative }
        if exceedsMaximum(body, locale: locale) { return .tooLarge }

        guard body.contains(where: \.isNumber) else { return isFinal ? .notNumeric : nil }
        guard let amount = AmountParser.parse(body, minorUnit: minorUnit, locale: locale) else {
            // Digits and at most one decimal point that still do not parse
            // can only have overflowed — or be grouping in the wrong place,
            // which is not a number either.
            return AmountParser.parse(body.filter(\.isNumber), locale: locale) == nil ? .tooLarge : .notNumeric
        }
        if amount == 0 { return isFinal ? .zero : nil }
        return nil
    }
}

public extension AmountFormatter {
    /// The field text, rounded to what the currency can hold — or `nil`
    /// when it already fits, or is not a number at all (that is
    /// `AmountIssue`'s to report, not this function's to rewrite).
    ///
    /// For the moment a field is committed: the user may type "12.345"
    /// against dollars, and what they see afterwards has to be the 12.35
    /// that `AmountParser.parse(_:minorUnit:)` will store, not a figure
    /// the account cannot hold. Judged by the digits typed rather than by
    /// value, so "12.3" is left as the user wrote it — only precision the
    /// currency does not have is taken away.
    static func rounded(_ text: String, minorUnit: Int, locale: Locale = .current) -> String? {
        let separators = AmountSeparators(locale: locale)
        guard let point = text.lastIndex(where: separators.isDecimal) else { return nil }
        let fractionDigits = text[text.index(after: point)...].filter(\.isNumber).count
        guard fractionDigits > minorUnit,
              let amount = AmountParser.parse(text, minorUnit: minorUnit, locale: locale)
        else { return nil }
        return editableString(amount, minorUnit: minorUnit, locale: locale, signed: true)
    }
}

public extension AmountFormatter {
    /// Typed text with the locale's grouping put into its whole part —
    /// "1234567.8" reads "1,234,567.8" — for the amount field to show while
    /// it is edited and at rest. The fraction, a trailing point and the sign
    /// are left exactly as typed, since the user is still typing them.
    ///
    /// Grouping comes from the locale's own formatter rather than "every
    /// three digits": India groups 12,34,567, and France groups with a
    /// narrow space. Text that is not a number is returned unchanged, so a
    /// typo stays visible exactly as it was typed.
    ///
    /// The field **stores** the ungrouped form (`ungrouping`), so every
    /// parse, save and conversion sees the same plain digits it always has.
    static func grouping(_ text: String, locale: Locale = .current) -> String {
        let separators = AmountSeparators(locale: locale)
        let plain = ungrouping(text, locale: locale)
        let hasSign = plain.first == "-" || plain.first == "\u{2212}"
        let body = hasSign ? plain.dropFirst() : plain[...]
        let point = body.firstIndex(where: separators.isDecimal) ?? body.endIndex
        let whole = body[..<point]
        guard !whole.isEmpty, whole.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Decimal(string: String(whole)),
              let grouped = FormatterCache.grouping(locale: locale).string(from: number as NSDecimalNumber)
        else { return text }
        return (hasSign ? String(plain.prefix(1)) : "") + grouped + body[point...]
    }

    /// The typed text without grouping marks — what the field stores.
    static func ungrouping(_ text: String, locale: Locale = .current) -> String {
        guard let grouping = AmountSeparators(locale: locale).grouping else { return text }
        return text.filter { $0 != grouping }
    }
}

/// The characters a typed amount may use besides digits: the locale's own
/// decimal point, "." (the POSIX fallback `AmountParser` also accepts — a
/// habit from another app, or a paste), and the locale's grouping mark.
private struct AmountSeparators {
    let decimal: Character
    let grouping: Character?

    init(locale: Locale) {
        decimal = locale.decimalSeparator?.first ?? "."
        grouping = locale.groupingSeparator?.first
    }

    /// "." is only a decimal point where it is not the grouping mark — on a
    /// German locale "1.234,56" has one decimal point, not two.
    func isDecimal(_ character: Character) -> Bool {
        character == decimal || (character == "." && grouping != ".")
    }

    func contains(_ character: Character) -> Bool {
        isDecimal(character) || character == grouping
    }
}
