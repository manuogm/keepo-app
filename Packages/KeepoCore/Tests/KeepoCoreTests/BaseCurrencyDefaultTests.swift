import Foundation
import Testing
@testable import KeepoCore

/// The base-currency step opens on whatever this returns, so every case
/// here is a first impression: the wheel is either already right or the
/// user's first act in the app is correcting it.
@Suite("Base currency default")
struct BaseCurrencyDefaultTests {
    /// The ECB/Frankfurter set, near enough — what `currencies` holds.
    private let supported = ["AUD", "BRL", "CAD", "CHF", "CNY", "EUR", "GBP", "JPY", "MXN", "SEK", "USD"]

    @Test("the device's own currency wins when Keepo supports it")
    func localeCurrency() {
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "es_ES")) == "EUR")
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "en_GB")) == "GBP")
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "ja_JP")) == "JPY")
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "en_US")) == "USD")
    }

    /// The whole point of restricting to the supported set: a base currency
    /// with no FX rates would render every converted balance as `—`
    /// forever. A locale Keepo cannot price falls back rather than being
    /// honoured.
    @Test("an unsupported local currency falls back rather than being offered")
    func unsupportedLocale() {
        // INR and ZAR are outside the set above.
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "hi_IN")) == "USD")
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "af_ZA")) == "USD")
    }

    /// `Locale(identifier: "en")` has no region and therefore no currency.
    @Test("a locale with no currency at all falls back")
    func noCurrency() {
        #expect(BaseCurrencyDefault.suggestion(supported: supported, locale: Locale(identifier: "en")) == "USD")
    }

    @Test("case is normalised on both sides")
    func caseInsensitive() {
        #expect(BaseCurrencyDefault.suggestion(supported: ["eur", "usd"], locale: Locale(identifier: "de_DE")) == "EUR")
    }

    /// Only reachable before the first sync pull lands, when the step is
    /// still showing its spinner — but it must not return something that is
    /// not a currency.
    @Test("an empty supported set still answers with a real code")
    func emptySupported() {
        #expect(BaseCurrencyDefault.suggestion(supported: [], locale: Locale(identifier: "es_ES")) == "USD")
    }

    @Test("a set without USD falls back to a code that is actually in it")
    func fallbackWithoutUSD() {
        let codes = ["EUR", "GBP", "CHF"]
        #expect(BaseCurrencyDefault.suggestion(supported: codes, locale: Locale(identifier: "hi_IN")) == "CHF")
    }
}
