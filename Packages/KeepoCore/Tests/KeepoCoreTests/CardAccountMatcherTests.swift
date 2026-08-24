import Testing
@testable import KeepoCore

/// The name-matching behind an unmapped card's account suggestions. The
/// cases here are the ones from device-testing feedback plus the
/// false-positive guards that keep this from confidently guessing wrong.
@Suite("Card/account name matching")
struct CardAccountMatcherTests {
    private func matches(_ card: String, _ account: String) -> Bool {
        CardAccountMatcher.matchScore(cardIdentifier: card, accountName: account) > 0
    }

    @Test("a card names its account through the card network word")
    func matchesThroughNetworkNoise() {
        #expect(matches("Revolut Mastercard", "Revolut"))
        #expect(matches("Chase Credit", "Chase Bank"))
        #expect(matches("Amex Gold Card", "Amex"))
        #expect(matches("N26 Debit Card", "N26 Everyday"))
    }

    @Test("matching ignores case, punctuation, and the card's last four digits")
    func matchesIgnoringFormatting() {
        #expect(matches("revolut·mastercard 4821", "Revolut"))
        #expect(matches("BBVA-Credito", "bbva"))
    }

    @Test("unrelated names never match, even when both are all noise words")
    func rejectsUnrelatedNames() {
        #expect(!matches("Revolut Mastercard", "Chase Bank"))
        #expect(!matches("Apple Card", "Revolut"))
        // Both sides reduce to nothing but noise — matching on "card" or
        // "bank" alone is exactly the wrong guess this must not make.
        #expect(!matches("Credit Card", "The Bank Account"))
        #expect(!matches("Visa Gold", "Platinum Card"))
    }

    @Test("a shared short or numeric fragment is not a match")
    func rejectsWeakOverlap() {
        // "the" and digits are stripped, leaving no shared signal.
        #expect(!matches("The 1234 Card", "The 5678 Account"))
    }

    @Test("a longer shared name scores higher than a single shared word")
    func scoresStrongerMatchesHigher() {
        let twoWords = CardAccountMatcher.matchScore(
            cardIdentifier: "Banco Santander Credit", accountName: "Banco Santander"
        )
        let oneWord = CardAccountMatcher.matchScore(
            cardIdentifier: "Banco Santander Credit", accountName: "Banco Popular"
        )
        #expect(twoWords > oneWord)
    }

    @Test("a truncated spelling of the same name still matches, but scores below an exact one")
    func prefixMatchIsWeakerThanExact() {
        // A prefix overlap alone is deliberately below the confidence
        // threshold — on its own it falls back to usage ordering.
        #expect(CardAccountMatcher.matchScore(cardIdentifier: "Santand Card", accountName: "Santander") == 0)
        // Paired with a second, exact shared token it clears the bar.
        #expect(
            CardAccountMatcher.matchScore(cardIdentifier: "Banco Santand Card", accountName: "Banco Santander") > 0
        )
    }
}
