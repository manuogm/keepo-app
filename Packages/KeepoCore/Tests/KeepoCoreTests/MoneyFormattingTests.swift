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
        let result = MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale, exact: true)
        #expect(result == "¥1,500")
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

@Suite("MoneyFormatter short form")
struct MoneyShortFormTests {
    let usd = CurrencyInfo(code: "USD", minorUnit: 2)
    let jpy = CurrencyInfo(code: "JPY", minorUnit: 0)
    let usLocale = Locale(identifier: "en_US")

    private func format(_ amountE4: Int64?, signStyle: MoneySignStyle = .standard) -> String {
        MoneyFormatter.format(amountE4, currency: usd, locale: usLocale, signStyle: signStyle)
    }

    @Test("a thousand and up is short, one decimal at most, rounded to nearest", arguments: [
        (Int64(10_000_000), "$1K"),
        (Int64(19_600_000), "$2K"),
        (Int64(568_465_000), "$56.8K"),
        (Int64(-568_465_000), "-$56.8K"),
        (Int64(9_999_600_000), "$1M"),
        (Int64(999_999_999_900), "$100M"),
        (Int64(1_234_567_890_129_900), "$123.5B")
    ])
    func shortens(amountE4: Int64, expected: String) {
        #expect(format(amountE4) == expected)
    }

    @Test("below a thousand stays exact, cents and all")
    func belowThresholdIsExact() {
        #expect(format(9_999_900) == "$999.99")
        #expect(format(-8_423_700) == "-$842.37")
    }

    @Test("the sign styles apply to the short form too")
    func signStyles() {
        #expect(format(568_465_000, signStyle: .ledger) == "+$56.8K")
        #expect(format(-568_465_000, signStyle: .ledger) == "$56.8K")
        #expect(format(-568_465_000, signStyle: .magnitude) == "$56.8K")
    }

    @Test("exact opts out, for a record or a check")
    func exactOptsOut() {
        #expect(MoneyFormatter.format(568_465_000, currency: usd, locale: usLocale, exact: true) == "$56,846.50")
    }

    @Test("a zero-decimal currency shortens by the same rule")
    func yen() {
        #expect(MoneyFormatter.format(15_000_000, currency: jpy, locale: usLocale) == "¥1.5K")
        #expect(MoneyFormatter.format(9_000_000, currency: jpy, locale: usLocale) == "¥900")
    }

    @Test("a short figure has no fraction to split off")
    func splitShort() {
        let split = MoneyFormatter.formatSplit(568_465_000, currency: usd, locale: usLocale)
        #expect(split.whole == "$56.8K")
        #expect(split.fraction.isEmpty)
    }

    @Test("still a dash for a missing value")
    func missing() {
        #expect(format(nil) == "—")
    }

    @Test("the amount field's short figure matches, without symbol or sign")
    func compactFigure() {
        #expect(MoneyFormatter.compactFigure(-568_465_000, locale: usLocale) == "56.8K")
        #expect(MoneyFormatter.compactFigure(1_234_567_890_129_900, locale: usLocale) == "123.5B")
        #expect(MoneyFormatter.isShort(10_000_000, minorUnit: 2))
        #expect(!MoneyFormatter.isShort(9_999_900, minorUnit: 2))
        // 999.995 is shown as 1,000.00, so it is shortened like it.
        #expect(MoneyFormatter.isShort(9_999_950, minorUnit: 2))
    }
}
