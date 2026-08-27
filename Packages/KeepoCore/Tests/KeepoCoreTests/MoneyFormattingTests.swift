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

    @Test("compact drops the cents below a thousand")
    func compactRoundsToWholeUnits() {
        #expect(MoneyFormatter.compact(8_423_700, currency: usd, locale: usLocale) == "$842")
    }

    @Test("compact abbreviates past a thousand")
    func compactAbbreviates() {
        // 4,231.87 — a tile has no room for the exact figure, and rounding
        // it is better than shrinking the type until it fits.
        #expect(MoneyFormatter.compact(42_318_700, currency: usd, locale: usLocale) == "$4.2K")
        #expect(MoneyFormatter.compact(13_000_000_000, currency: usd, locale: usLocale) == "$1.3M")
    }

    @Test("compact keeps money rule 5")
    func compactMissingValueRendersDash() {
        #expect(MoneyFormatter.compact(nil, currency: usd, locale: usLocale) == "—")
    }

    /// The direction is named by a label beside the figure, so neither a
    /// minus nor a `+` belongs on it — that is the whole difference between
    /// `magnitude` and `ledger`.
    @Test("magnitude draws neither sign")
    func magnitudeIsUnsigned() {
        #expect(MoneyFormatter.compact(-42_318_700, currency: usd, locale: usLocale, signStyle: .magnitude)
            == "$4.2K")
        #expect(MoneyFormatter.compact(42_318_700, currency: usd, locale: usLocale, signStyle: .magnitude)
            == "$4.2K")
        #expect(MoneyFormatter.format(-123_450, currency: usd, locale: usLocale, signStyle: .magnitude)
            == "$12.35")
    }

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

    // MARK: - Ledger sign style
    //
    // The stored value is never re-signed (money rule 1) — these only
    // assert what is *drawn*, which is why every case below passes the same
    // negative/positive Int64 the standard style also renders.

    @Test("ledger style drops an outflow's minus sign")
    func ledgerDropsMinus() {
        let drawn = MoneyFormatter.format(-123_450, currency: usd, locale: usLocale, signStyle: .ledger)
        #expect(!drawn.contains("-"))
        #expect(drawn == MoneyFormatter.format(123_450, currency: usd, locale: usLocale))
    }

    @Test("ledger style prefixes an inflow with an explicit plus")
    func ledgerAddsPlus() {
        let drawn = MoneyFormatter.format(123_450, currency: usd, locale: usLocale, signStyle: .ledger)
        #expect(drawn.hasPrefix("+"))
        #expect(drawn.dropFirst() == MoneyFormatter.format(123_450, currency: usd, locale: usLocale))
    }

    @Test("ledger style leaves zero unsigned")
    func ledgerZeroUnsigned() {
        let drawn = MoneyFormatter.format(0, currency: usd, locale: usLocale, signStyle: .ledger)
        #expect(drawn == MoneyFormatter.format(0, currency: usd, locale: usLocale))
    }

    @Test("ledger style still renders a missing value as an em dash, never a signed zero")
    func ledgerMissingValue() {
        #expect(MoneyFormatter.format(nil, currency: usd, locale: usLocale, signStyle: .ledger) == "—")
    }

    @Test("ledger formatSplit keeps the plus on the whole part, not the fraction")
    func ledgerFormatSplit() {
        let split = MoneyFormatter.formatSplit(123_450, currency: usd, locale: usLocale, signStyle: .ledger)
        #expect(split.whole.hasPrefix("+"))
        // 123_450 e4 is 12.345, which rounds half-away-from-zero to 12.35.
        #expect(split.fraction == ".35")
        #expect(split.whole + split.fraction
            == MoneyFormatter.format(123_450, currency: usd, locale: usLocale, signStyle: .ledger))
    }

    @Test("ledger style does not trap on Int64.min")
    func ledgerExtremeValue() {
        #expect(!MoneyFormatter.format(.min, currency: usd, locale: usLocale, signStyle: .ledger).isEmpty)
    }

    // MARK: - Symbol + separator accessors

    @Test("symbol(for:) returns the locale's currency symbol")
    func currencySymbol() {
        #expect(MoneyFormatter.symbol(for: usd, locale: usLocale) == "$")
    }

    @Test("a cached formatter is not shared across currencies")
    func cacheKeyedByCurrency() {
        let dollars = MoneyFormatter.format(123_450, currency: usd, locale: usLocale)
        let yen = MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale)
        #expect(dollars != yen)
        // Re-reading each must be stable — a cache that mutated a shared
        // formatter in place would only show up on the second call.
        #expect(MoneyFormatter.format(123_450, currency: usd, locale: usLocale) == dollars)
        #expect(MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale) == yen)
    }
}
