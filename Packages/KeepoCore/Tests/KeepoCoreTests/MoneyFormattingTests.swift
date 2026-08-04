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
        let result = MoneyFormatter.format(
            Decimal(string: "12.345"),
            currency: usd,
            locale: usLocale
        )
        #expect(result.contains("12.35") || result.contains("12.34"))
        #expect(!result.contains("12.345"))
    }

    @Test("zero-decimal currencies show no fraction digits")
    func zeroDecimalCurrency() {
        let result = MoneyFormatter.format(
            Decimal(string: "1500"),
            currency: jpy,
            locale: usLocale
        )
        #expect(!result.contains("."))
    }

    @Test("a real zero balance still renders as zero, not a dash")
    func actualZeroIsNotDash() {
        let result = MoneyFormatter.format(Decimal(0), currency: usd, locale: usLocale)
        #expect(result != "—")
    }
}
