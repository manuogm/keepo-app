import Foundation
import Testing
@testable import KeepoCore

@Suite("AmountParser")
struct AmountParserTests {
    @Test("parses a period-decimal string on a US locale")
    func periodOnUSLocale() {
        let result = AmountParser.parse("1250.75", locale: Locale(identifier: "en_US"))
        #expect(result == 12_507_500)
    }

    @Test("parses a comma-decimal string on a comma-decimal locale — the Phase 1 bug")
    func commaOnCommaLocale() {
        // Decimal(string:) alone (Phase 1's OnboardingView) returns nil for
        // this input regardless of locale; AmountParser must not.
        let result = AmountParser.parse("1250,75", locale: Locale(identifier: "de_DE"))
        #expect(result == 12_507_500)
    }

    @Test("falls back to period-decimal when typed against the wrong locale")
    func periodFallbackOnCommaLocale() {
        let result = AmountParser.parse("1250.75", locale: Locale(identifier: "de_DE"))
        #expect(result == 12_507_500)
    }

    @Test("empty input returns nil, not zero")
    func emptyReturnsNil() {
        #expect(AmountParser.parse("", locale: Locale(identifier: "en_US")) == nil)
        #expect(AmountParser.parse("   ", locale: Locale(identifier: "en_US")) == nil)
    }

    @Test("rejects garbage input")
    func garbageReturnsNil() {
        #expect(AmountParser.parse("not a number", locale: Locale(identifier: "en_US")) == nil)
    }

    @Test("parses a whole number with no decimal part")
    func wholeNumber() {
        #expect(AmountParser.parse("500", locale: Locale(identifier: "en_US")) == 5_000_000)
    }
}

@Suite("AmountParser.parseFormattedCurrency")
struct AmountParserFormattedCurrencyTests {
    /// The bug this function was rewritten for: the separator used to come
    /// from `Locale.current`, so `$1.06` on a comma-decimal device had its
    /// `.` stripped as grouping and captured as **106**. Both conventions
    /// are parsed correctly here, in one process, with no locale in sight —
    /// which is the fix, not a symptom of it.
    @Test("reads the separator out of the string, not off the device", arguments: [
        ("$1.06", Int64(10_600)),
        ("1,06 €", Int64(10_600)),
        ("$1,234.56", Int64(12_345_600)),
        ("€1.234,56", Int64(12_345_600))
    ])
    func infersSeparator(text: String, expected: Int64) {
        #expect(AmountParser.parseFormattedCurrency(text) == expected)
    }

    @Test("grouping marks that are never a decimal point are dropped", arguments: [
        // Switzerland, whose CHF is in the supported set.
        ("CHF 1'234.56", Int64(12_345_600)),
        // Narrow no-break space (U+202F) — France, Sweden, Hungary.
        ("1\u{202F}234,56 kr", Int64(12_345_600)),
        ("1\u{00A0}234,56 kr", Int64(12_345_600))
    ])
    func dropsGroupingMarks(text: String, expected: Int64) {
        #expect(AmountParser.parseFormattedCurrency(text) == expected)
    }

    /// A zero-decimal currency's grouped thousands are the one genuinely
    /// ambiguous shape, and the rule is safe because no supported currency
    /// has 1 or 3 minor digits: three trailing digits cannot be a fraction.
    @Test("a single separator with three digits behind it is grouping", arguments: [
        ("¥1,234", Int64(12_340_000)),
        ("1.234 Ft", Int64(12_340_000)),
        ("1.234.567 Ft", Int64(12_345_670_000))
    ])
    func threeTrailingDigitsAreGrouping(text: String, expected: Int64) {
        #expect(AmountParser.parseFormattedCurrency(text) == expected)
    }

    @Test("handles Indian two-digit grouping")
    func indianGrouping() {
        #expect(AmountParser.parseFormattedCurrency("₹1,23,456.78") == 1_234_567_800)
    }

    @Test("a refund keeps its sign, whichever minus the formatter used", arguments: [
        "-$1.06", "$-1.06", "\u{2212}$1.06"
    ])
    func negativeAmounts(text: String) {
        #expect(AmountParser.parseFormattedCurrency(text) == -10_600)
    }

    @Test("the symbol never changes the magnitude")
    func symbolIsIgnored() {
        #expect(AmountParser.parseFormattedCurrency("$1.06") == AmountParser.parseFormattedCurrency("1.06"))
        #expect(AmountParser.parseFormattedCurrency("CHF 1.06") == AmountParser.parseFormattedCurrency("1.06"))
    }

    @Test("zero parses as zero, not nil")
    func zeroParses() {
        #expect(AmountParser.parseFormattedCurrency("$0.00") == 0)
    }

    @Test("input carrying no digits returns nil", arguments: ["???", "", "   ", "-", "$"])
    func noDigitsReturnsNil(text: String) {
        #expect(AmountParser.parseFormattedCurrency(text) == nil)
    }
}

@Suite("AmountFormatter")
struct AmountFormatterTests {
    @Test("round-trips through AmountParser on a comma-decimal locale")
    func roundTripsOnCommaLocale() {
        let locale = Locale(identifier: "de_DE")
        let original: Int64 = 12_507_500
        let text = AmountFormatter.editableString(original, minorUnit: 2, locale: locale)
        #expect(text.contains(","))
        #expect(AmountParser.parse(text, locale: locale) == original)
    }

    @Test("always renders unsigned — sign is the caller's, not the field's")
    func alwaysUnsigned() {
        let text = AmountFormatter.editableString(-425_000, minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(!text.contains("-"))
        #expect(text == "42.50")
    }

    @Test("pads to the currency's minor unit even for a whole number")
    func padsToMinorUnit() {
        let text = AmountFormatter.editableString(5_000_000, minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(text == "500.00")
    }

    @Test("zero-decimal currencies render no fraction digits")
    func zeroDecimalCurrency() {
        let text = AmountFormatter.editableString(15_000_000, minorUnit: 0, locale: Locale(identifier: "en_US"))
        #expect(text == "1500")
    }

    @Test("never emits a grouping separator — the field must stay parseable")
    func noGroupingSeparator() {
        let text = AmountFormatter.editableString(12_345_600, minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(!text.contains(","))
    }
}

@Suite("AmountFormatter signed mode")
struct AmountFormatterSignedTests {
    let usLocale = Locale(identifier: "en_US")

    @Test("unsigned is still the default, so a transaction field never prefills a minus")
    func defaultsToUnsigned() {
        #expect(AmountFormatter.editableString(-125_000, minorUnit: 2, locale: usLocale) == "12.50")
    }

    @Test("signed keeps a negative balance negative")
    func signedKeepsMinus() {
        #expect(AmountFormatter.editableString(-8_400_000, minorUnit: 2, locale: usLocale, signed: true) == "-840.00")
    }

    @Test("a signed balance round-trips through AmountParser unchanged")
    func signedRoundTrips() {
        let stored: Int64 = -8_400_000
        let text = AmountFormatter.editableString(stored, minorUnit: 2, locale: usLocale, signed: true)
        #expect(AmountParser.parse(text, locale: usLocale) == stored)
    }

    @Test("an unsigned round-trip is what silently flips an overdrawn account positive")
    func unsignedRoundTripLosesTheSign() {
        let stored: Int64 = -8_400_000
        let text = AmountFormatter.editableString(stored, minorUnit: 2, locale: usLocale)
        #expect(AmountParser.parse(text, locale: usLocale) == 8_400_000)
    }
}
