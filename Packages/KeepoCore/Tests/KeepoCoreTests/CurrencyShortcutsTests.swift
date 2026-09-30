import KeepoCore
import Testing

@Suite("Currency wheel pills")
struct CurrencyShortcutsTests {
    private let supported: Set<String> = ["EUR", "USD", "GBP", "SEK", "NOK", "CHF", "JPY"]

    private func pills(_ usage: [CurrencyShortcuts.Usage]) -> [String] {
        CurrencyShortcuts.pills(preferred: CurrencyShortcuts.rank(usage), supported: supported)
    }

    private func use(_ code: String, _ transactions: Int, accounts: Int = 1) -> CurrencyShortcuts.Usage {
        CurrencyShortcuts.Usage(code: code, transactions: transactions, accounts: accounts)
    }

    @Test("a user with no currencies of their own gets the defaults")
    func noUsage() {
        #expect(pills([]) == ["EUR", "USD", "GBP"])
    }

    @Test("scenario 1: holding exactly the defaults changes nothing when usage ties")
    func holdsTheDefaults() {
        #expect(pills([use("GBP", 0), use("USD", 0), use("EUR", 0)]) == ["EUR", "USD", "GBP"])
    }

    @Test("scenario 1: holding the defaults orders them by how much each is used")
    func holdsTheDefaultsUnevenly() {
        #expect(pills([use("EUR", 3), use("USD", 40), use("GBP", 1)]) == ["USD", "EUR", "GBP"])
    }

    @Test("scenario 2: one currency of their own, topped up with EUR and USD")
    func singleOwnCurrency() {
        #expect(pills([use("SEK", 12)]) == ["SEK", "EUR", "USD"])
    }

    @Test("scenario 3: three currencies of their own replace every default, most used first")
    func threeOwnCurrencies() {
        #expect(pills([use("NOK", 5), use("SEK", 30), use("CHF", 9)]) == ["SEK", "CHF", "NOK"])
    }

    @Test("SEK over USD by importance, then the first default not already shown")
    func mixedWithADefault() {
        #expect(pills([use("USD", 4), use("SEK", 20, accounts: 2)]) == ["SEK", "USD", "EUR"])
    }

    @Test("more accounts breaks a tie in transactions")
    func accountsBreakTies() {
        #expect(CurrencyShortcuts.rank([use("NOK", 5, accounts: 1), use("CHF", 5, accounts: 2)]) == ["CHF", "NOK"])
    }

    @Test("only the top three of four own currencies are offered")
    func capsAtThree() {
        #expect(pills([use("JPY", 1), use("SEK", 9), use("NOK", 7), use("CHF", 3)]) == ["SEK", "NOK", "CHF"])
    }

    @Test("a currency the server no longer supports is skipped, not left as a dead pill")
    func unsupportedIsSkipped() {
        #expect(pills([use("XYZ", 50), use("SEK", 2)]) == ["SEK", "EUR", "USD"])
    }
}
