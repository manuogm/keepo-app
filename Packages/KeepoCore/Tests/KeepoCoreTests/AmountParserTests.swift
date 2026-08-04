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
