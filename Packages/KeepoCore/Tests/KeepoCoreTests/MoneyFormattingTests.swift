import Foundation
import Testing
@testable import KeepoCore

@Suite("Decimal(supabaseNumeric:)")
struct SupabaseNumericDecodingTests {
    @Test("decodes a numeric column string without going through Double")
    func decodesExactly() {
        // 0.1 + 0.2 is not exact as a Double; it must be exact coming from a string.
        let amount = Decimal(supabaseNumeric: "1234.5678")
        #expect(amount == Decimal(string: "1234.5678"))
    }

    @Test("rejects malformed input instead of coercing")
    func rejectsGarbage() {
        #expect(Decimal(supabaseNumeric: "not-a-number") == nil)
    }
}

@Suite("MoneyFormatter")
struct MoneyFormatterTests {
    let usd = CurrencyInfo(code: "USD", minorUnit: 2)
    let jpy = CurrencyInfo(code: "JPY", minorUnit: 0)
    let usLocale = Locale(identifier: "en_US")

    @Test("a missing value renders as em dash, never zero")
    func missingValueRendersDash() {
        #expect(MoneyFormatter.format(nil, currency: usd, locale: usLocale) == "—")
    }

    @Test("rounds display to the currency's minor unit")
    func roundsToMinorUnit() {
        // 12.345 at e4 scale is 123450.
        let result = MoneyFormatter.format(123_450, currency: usd, locale: usLocale)
        #expect(result.contains("12.35") || result.contains("12.34"))
        #expect(!result.contains("12.345"))
    }

    @Test("zero-decimal currencies show no fraction digits")
    func zeroDecimalCurrency() {
        // 1500 JPY at e4 scale is 15000000.
        let result = MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale)
        #expect(!result.contains("."))
    }

    @Test("a real zero balance still renders as zero, not a dash")
    func actualZeroIsNotDash() {
        let result = MoneyFormatter.format(0, currency: usd, locale: usLocale)
        #expect(result != "—")
    }

    @Test("formatSplit's two parts concatenate back to the plain format")
    func formatSplitReassemblesToFullFormat() {
        let full = MoneyFormatter.format(123_450, currency: usd, locale: usLocale)
        let split = MoneyFormatter.formatSplit(123_450, currency: usd, locale: usLocale)
        #expect(split.whole + split.fraction == full)
        #expect(split.fraction.hasPrefix("."))
    }

    @Test("formatSplit has no fraction for a zero-decimal currency")
    func formatSplitZeroDecimalCurrency() {
        let split = MoneyFormatter.formatSplit(15_000_000, currency: jpy, locale: usLocale)
        #expect(split.fraction.isEmpty)
        #expect(split.whole == MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale))
    }

    @Test("formatSplit renders a missing value as a whole-only dash")
    func formatSplitMissingValue() {
        let split = MoneyFormatter.formatSplit(nil, currency: usd, locale: usLocale)
        #expect(split.whole == "—")
        #expect(split.fraction.isEmpty)
    }
}
