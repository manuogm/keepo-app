import Foundation
import KeepoCore
import Testing

/// A typed amount against its currency's precision. Storage keeps four
/// decimals, so rounding to the currency is the parser's job — a dollar
/// account must never hold 12.345.
@Suite("AmountParser minor-unit rounding")
struct AmountParserMinorUnitTests {
    let usLocale = Locale(identifier: "en_US")

    @Test("rounds to the currency's minor unit, half away from zero", arguments: [
        ("12.345", 2, Int64(123_500)),
        ("12.344", 2, Int64(123_400)),
        ("-12.345", 2, Int64(-123_500)),
        ("1234.5", 0, Int64(12_350_000)),
        ("1234.4999", 0, Int64(12_340_000)),
        ("0.001", 2, Int64(0))
    ])
    func rounds(text: String, minorUnit: Int, expected: Int64) {
        #expect(AmountParser.parse(text, minorUnit: minorUnit, locale: usLocale) == expected)
    }

    @Test("without a minor unit, the four stored decimals are kept")
    func unroundedByDefault() {
        #expect(AmountParser.parse("12.345", locale: usLocale) == 123_450)
    }
}

@Suite("AmountFormatter.rounded")
struct AmountFormatterRoundedTests {
    let usLocale = Locale(identifier: "en_US")

    @Test("rewrites only precision the currency does not have")
    func rewritesExcessPrecision() {
        #expect(AmountFormatter.rounded("12.345", minorUnit: 2, locale: usLocale) == "12.35")
        #expect(AmountFormatter.rounded("-12.345", minorUnit: 2, locale: usLocale) == "-12.35")
        #expect(AmountFormatter.rounded("1234.5", minorUnit: 0, locale: usLocale) == "1235")
    }

    @Test("leaves text that already fits exactly as typed", arguments: ["12.3", "12.30", "12", "12.", "abc", ""])
    func leavesFittingText(text: String) {
        #expect(AmountFormatter.rounded(text, minorUnit: 2, locale: usLocale) == nil)
    }

    @Test("reads the locale's own decimal point")
    func commaLocale() {
        let locale = Locale(identifier: "de_DE")
        #expect(AmountFormatter.rounded("12,345", minorUnit: 2, locale: locale) == "12,35")
    }
}

@Suite("AmountIssue")
struct AmountIssueTests {
    let usLocale = Locale(identifier: "en_US")

    private func issue(_ text: String, minorUnit: Int? = 2, isFinal: Bool = false) -> AmountIssue? {
        AmountIssue.of(text, minorUnit: minorUnit, isFinal: isFinal, locale: usLocale)
    }

    @Test("valid and not-yet-entered amounts have no issue", arguments: ["", "12", "12.5", "12.50", "0.5", ".5"])
    func valid(text: String) {
        #expect(issue(text, isFinal: true) == nil)
    }

    @Test("a letter or symbol is not numeric, even mid-typing", arguments: ["12a", "abc", "1$", "1.2.3", "-12x"])
    func notNumeric(text: String) {
        #expect(issue(text) == .notNumeric)
    }

    /// "12abc" is the case that matters: the parse's POSIX fallback reads a
    /// numeric prefix, so without the gate it would have saved as 12.
    @Test("a numeric prefix does not rescue trailing junk")
    func prefixIsNotEnough() {
        #expect(issue("12abc") == .notNumeric)
    }

    @Test("a leading minus is negative, even alone", arguments: ["-", "-12", "\u{2212}12", "-0"])
    func negative(text: String) {
        #expect(issue(text) == .negative)
    }

    @Test("zero and a lone point wait for the entry to be final")
    func incompleteUntilFinal() {
        #expect(issue("0") == nil)
        #expect(issue("0.") == nil)
        #expect(issue(".") == nil)
        #expect(issue("0", isFinal: true) == .zero)
        #expect(issue(".", isFinal: true) == .notNumeric)
    }

    @Test("an amount that rounds to nothing in its currency is zero")
    func roundsToZero() {
        #expect(issue("0.001", isFinal: true) == .zero)
        #expect(issue("0.4", minorUnit: 0, isFinal: true) == .zero)
    }

    @Test("more than the store can hold is too large")
    func tooLarge() {
        #expect(issue(String(repeating: "9", count: 40)) == .tooLarge)
    }

    @Test("twelve whole digits is the ceiling; the fraction and grouping do not count")
    func wholeDigitCeiling() {
        #expect(issue("999999999999.99") == nil)
        #expect(issue("1000000000000") == .tooLarge)
        #expect(!AmountIssue.exceedsMaximum("999,999,999,999.9999", locale: usLocale))
        #expect(AmountIssue.exceedsMaximum("1,000,000,000,000", locale: usLocale))
    }

    @Test("a German grouping point is not a second decimal point")
    func germanGrouping() {
        let locale = Locale(identifier: "de_DE")
        #expect(AmountIssue.of("1.234,56", minorUnit: 2, isFinal: true, locale: locale) == nil)
        #expect(AmountIssue.of("1,2,3", minorUnit: 2, isFinal: true, locale: locale) == .notNumeric)
    }
}

@Suite("AmountFormatter grouping")
struct AmountGroupingTests {
    let usLocale = Locale(identifier: "en_US")

    @Test("groups the whole part and leaves the rest as typed", arguments: [
        ("1234567.89", "1,234,567.89"),
        ("1234.", "1,234."),
        ("1234.5", "1,234.5"),
        ("-1234567", "-1,234,567"),
        ("999", "999"),
        ("1,23,4", "1,234"),
        ("", ""),
        (".5", ".5"),
        ("12a34", "12a34")
    ])
    func groups(text: String, expected: String) {
        #expect(AmountFormatter.grouping(text, locale: usLocale) == expected)
    }

    @Test("follows the locale's own grouping")
    func localeGrouping() {
        #expect(AmountFormatter.grouping("1234567,5", locale: Locale(identifier: "de_DE")) == "1.234.567,5")
        #expect(AmountFormatter.grouping("1234567", locale: Locale(identifier: "en_IN")) == "12,34,567")
    }

    @Test("ungrouping gives back exactly what the parser always read")
    func roundTrips() {
        let grouped = AmountFormatter.grouping("1234567.89", locale: usLocale)
        #expect(AmountFormatter.ungrouping(grouped, locale: usLocale) == "1234567.89")
    }
}
