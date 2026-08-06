import Foundation
import Testing
@testable import KeepoCore

@Suite("AmountParser")
struct AmountParserTests {
    @Test("parses a period-decimal string on a US locale")
    func periodOnUSLocale() {
        let result = AmountParser.parse("1250.75", locale: Locale(identifier: "en_US"))
        #expect(result == Decimal(string: "1250.75"))
    }

    @Test("parses a comma-decimal string on a comma-decimal locale — the Phase 1 bug")
    func commaOnCommaLocale() {
        // Decimal(string:) alone (Phase 1's OnboardingView) returns nil for
        // this input regardless of locale; AmountParser must not.
        let result = AmountParser.parse("1250,75", locale: Locale(identifier: "de_DE"))
        #expect(result == Decimal(string: "1250.75"))
    }

    @Test("falls back to period-decimal when typed against the wrong locale")
    func periodFallbackOnCommaLocale() {
        let result = AmountParser.parse("1250.75", locale: Locale(identifier: "de_DE"))
        #expect(result == Decimal(string: "1250.75"))
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
        #expect(AmountParser.parse("500", locale: Locale(identifier: "en_US")) == Decimal(500))
    }
}

@Suite("AmountFormatter")
struct AmountFormatterTests {
    @Test("round-trips through AmountParser on a comma-decimal locale")
    func roundTripsOnCommaLocale() {
        let locale = Locale(identifier: "de_DE")
        let original = Decimal(string: "1250.75")!
        let text = AmountFormatter.editableString(original, minorUnit: 2, locale: locale)
        #expect(text.contains(","))
        #expect(AmountParser.parse(text, locale: locale) == original)
    }

    @Test("always renders unsigned — sign is the caller's, not the field's")
    func alwaysUnsigned() {
        let text = AmountFormatter.editableString(Decimal(-42.50), minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(!text.contains("-"))
        #expect(text == "42.50")
    }

    @Test("pads to the currency's minor unit even for a whole number")
    func padsToMinorUnit() {
        let text = AmountFormatter.editableString(Decimal(500), minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(text == "500.00")
    }

    @Test("zero-decimal currencies render no fraction digits")
    func zeroDecimalCurrency() {
        let text = AmountFormatter.editableString(Decimal(1500), minorUnit: 0, locale: Locale(identifier: "en_US"))
        #expect(text == "1500")
    }

    @Test("never emits a grouping separator — the field must stay parseable")
    func noGroupingSeparator() {
        let text = AmountFormatter.editableString(Decimal(1_234.56), minorUnit: 2, locale: Locale(identifier: "en_US"))
        #expect(!text.contains(","))
    }
}
