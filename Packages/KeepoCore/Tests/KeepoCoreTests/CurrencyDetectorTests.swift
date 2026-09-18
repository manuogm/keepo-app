import Foundation
import Testing
@testable import KeepoCore

@Suite("CurrencyDetector")
struct CurrencyDetectorTests {
    /// The `currencies` reference table's set — restricting to it is what
    /// makes detection possible at all.
    static let supported = [
        "AUD", "BGN", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS",
        "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB",
        "TRY", "USD", "ZAR"
    ]

    private func detect(_ text: String, on localeId: String) -> String? {
        CurrencyDetector.detect(in: text, supported: Self.supported, locale: Locale(identifier: localeId))
    }

    @Test("an explicit ISO code wins outright", arguments: [
        ("CHF 10.00", "CHF"),
        ("1,06 CAD", "CAD"),
        ("SEK 1 234,56", "SEK"),
        ("1 JPY", "JPY")
    ])
    func spelledCode(text: String, expected: String) {
        #expect(detect(text, on: "en_US") == expected)
        #expect(detect(text, on: "es_ES") == expected)
    }

    @Test("an unambiguous symbol resolves", arguments: [
        ("€50,00", "EUR"),
        ("£12.00", "GBP"),
        ("₹1,23,456.78", "INR"),
        ("R$ 19,90", "BRL"),
        ("CA$1.06", "CAD"),
        ("MX$1.06", "MXN")
    ])
    func unambiguousSymbol(text: String, expected: String) {
        #expect(detect(text, on: "en_US") == expected)
    }

    /// The device writes `CA$`, `A$` and `MX$` for the other dollars, so a
    /// bare `$` could only have been a US one.
    @Test("a bare dollar sign is USD on a non-dollar device", arguments: ["en_US", "en_GB", "de_DE", "es_ES"])
    func bareDollarOnNonDollarLocale(localeId: String) {
        #expect(detect("$1.06", on: localeId) == "USD")
    }

    /// The case the whole design exists to get right. On these devices `$`
    /// means the local dollar *and* could have come from a US-formatted
    /// string, and there is no way to tell — so detection says nothing and
    /// the capture keeps the account's currency, exactly as it did before
    /// any of this existed.
    @Test("a bare dollar sign resolves to nothing on a dollar device", arguments: [
        "en_AU", "en_CA", "en_NZ", "en_SG", "es_MX"
    ])
    func bareDollarOnDollarLocale(localeId: String) {
        #expect(detect("$1.06", on: localeId) == nil)
    }

    /// Same rule, different sign: `¥` is JPY nearly everywhere and CNY on
    /// a Chinese phone.
    @Test("the yen sign resolves on a Japanese phone and not on a Chinese one")
    func yenSign() {
        #expect(detect("¥1,234", on: "ja_JP") == "JPY")
        #expect(detect("¥1,234", on: "zh_CN") == nil)
        #expect(detect("CN¥1,234", on: "en_US") == "CNY")
    }

    /// A Swedish phone writes `kr` for its own krone and `NOK` for
    /// Norway's, so `kr` there is unambiguous — and means something
    /// different on a Norwegian one.
    @Test("a shared krone symbol resolves per device")
    func kroneSymbol() {
        #expect(detect("1 234,56 kr", on: "sv_SE") == "SEK")
        #expect(detect("1 234,56 kr", on: "nb_NO") == "NOK")
    }

    @Test("a longer symbol beats the shorter one inside it")
    func longestSymbolWins() {
        #expect(detect("1,06 US$", on: "es_ES") == "USD")
        #expect(detect("R$ 19,90", on: "en_US") == "BRL")
    }

    @Test("a string naming no currency resolves to nothing", arguments: ["1.06", "", "???", "1 234,56"])
    func noCurrency(text: String) {
        #expect(detect(text, on: "en_US") == nil)
    }

    @Test("a code is not found inside a longer word")
    func codeNeedsLetterBoundaries() {
        #expect(detect("1.06 USDX", on: "en_US") == nil)
        #expect(detect("1.06 XUSD", on: "en_US") == nil)
    }

    /// Detection is only ever allowed to name a currency the app can
    /// actually price.
    @Test("an unsupported currency resolves to nothing")
    func unsupportedCurrency() {
        #expect(detect("1,06 ARS", on: "en_US") == nil)
        #expect(CurrencyDetector.detect(in: "€50", supported: [], locale: Locale(identifier: "en_US")) == nil)
    }
}

/// `symbol(in:)` is the opposite question to `detect`: not "which currency
/// is this?" but "what did Wallet print?". It consults no locale, no
/// supported set and no table — it partitions the characters — so these
/// cases are the same on every device.
@Suite("Currency mark extraction")
struct CurrencySymbolHintTests {
    @Test(
        "the mark is read back verbatim, on whichever side of the digits it sat",
        arguments: [
            ("$1.06", "$", true),
            ("1.234,56 €", "€", false),
            ("CHF 1'234.56", "CHF", true),
            ("1,06 US$", "US$", false),
            ("SEK 1,06", "SEK", true),
            ("-$5.00", "$", true),
            // The narrow no-break space France and Sweden group with is
            // noise, not part of the mark.
            ("1\u{202F}234,56\u{00A0}kr", "kr", false)
        ]
    )
    func marks(text: String, token: String, isPrefix: Bool) {
        #expect(CurrencyDetector.symbol(in: text) == CurrencyDetector.SymbolHint(token: token, isPrefix: isPrefix))
    }

    /// Nothing to echo, so the caller keeps rendering a bare figure —
    /// exactly the behaviour that shipped before this existed.
    @Test("a bare figure, or no figure at all, yields no mark", arguments: ["1234.56", "1 234,56", "", "€"])
    func noMark(text: String) {
        #expect(CurrencyDetector.symbol(in: text) == nil)
    }

    /// A run this long is not a currency mark — it is a string that was
    /// never a machine-formatted amount, and echoing it into a
    /// notification title would be worse than the bare figure.
    @Test("a run too long to be a mark is refused")
    func overlongRunRefused() {
        #expect(CurrencyDetector.symbol(in: "Walmart Supercenter 50.00") == nil)
    }

    /// A glyph sits tight against a leading figure; a code does not. Both
    /// take a non-breaking space when trailing, so the pair cannot wrap
    /// apart across a notification title's two lines.
    @Test("the mark is reattached the way its own shape is spaced")
    func spacing() {
        #expect(CurrencyDetector.SymbolHint(token: "$", isPrefix: true).applied(to: "1,234.56") == "$1,234.56")
        #expect(
            CurrencyDetector.SymbolHint(token: "CHF", isPrefix: true)
                .applied(to: "1,234.56") == "CHF\u{00A0}1,234.56"
        )
        #expect(
            CurrencyDetector.SymbolHint(token: "kr", isPrefix: false)
                .applied(to: "1,234.56") == "1,234.56\u{00A0}kr"
        )
    }
}
