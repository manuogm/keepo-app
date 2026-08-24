import Foundation

/// Scores how likely a Wallet card name is to belong to a given account,
/// by name alone — "Revolut Mastercard" → the "Revolut" account, "Chase
/// Credit" → "Chase Bank". Used to rank the account suggestions on an
/// unmapped-card capture notification (`CaptureQuickActionSuggestions
/// .topUnmappedAccounts`) ahead of the plain most-used ordering, which is
/// only a fallback for when no name match exists.
///
/// Deliberately name-only and conservative: this drives a *suggestion*, and
/// a wrong confident guess costs the user a mis-filed transaction, while a
/// missed match costs nothing but a fallback to usage order. Nothing here
/// ever writes a card mapping on its own — the user still taps the button.
public enum CardAccountMatcher {
    /// Words that appear in card and account names alike without carrying
    /// any identity — payment networks, product tiers, and generic banking
    /// nouns. Stripping them is what lets "Revolut Mastercard" and
    /// "Revolut" match on the one token that actually names the issuer.
    ///
    /// Only words that are *never* somebody's account name belong here.
    /// Issuer brands that double as a network deliberately do not: nobody
    /// names an account "Visa", but plenty of people name one "Amex" or
    /// "Discover", and listing those cost the very match this exists to
    /// make ("Amex Gold Card" → the "Amex" account, caught by
    /// `CardAccountMatcherTests`). Being over-inclusive here only ever
    /// costs a missed match — harmless, it falls back to usage order — but
    /// a missed match is still the thing this file is for.
    private static let noiseTokens: Set<String> = [
        "card", "cards", "credit", "debit", "prepaid", "mastercard", "visa", "maestro",
        "gold", "platinum", "silver", "black", "classic", "premium", "plus", "rewards",
        "bank", "banking", "account", "acct", "the", "and"
    ]

    /// The lowest score that still counts as a real name match. One exact
    /// significant token (worth 2) clears it; a prefix-only near-miss
    /// (worth 1) deliberately does not.
    private static let minimumConfidentScore = 2

    /// - Returns: a score where higher is a better match, and `0` means "no
    ///   confident match — rank this by usage instead." An exact shared
    ///   token scores 2, a prefix overlap of two long tokens scores 1, and
    ///   anything totalling below `minimumConfidentScore` is flattened to 0
    ///   rather than being allowed to outrank a genuinely well-used account.
    public static func matchScore(cardIdentifier: String, accountName: String) -> Int {
        let cardTokens = significantTokens(cardIdentifier)
        let accountTokens = significantTokens(accountName)
        guard !cardTokens.isEmpty, !accountTokens.isEmpty else { return 0 }

        var score = 0
        for cardToken in cardTokens {
            if accountTokens.contains(cardToken) {
                score += 2
            } else if accountTokens.contains(where: { sharePrefix(cardToken, $0) }) {
                score += 1
            }
        }
        return score >= minimumConfidentScore ? score : 0
    }

    /// Lowercased alphanumeric words, minus `noiseTokens`, pure digits (a
    /// card's last-four), and anything under three characters.
    private static func significantTokens(_ value: String) -> Set<String> {
        let words = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(
            words.filter { word in
                word.count >= 3 && !noiseTokens.contains(word) && !word.allSatisfy(\.isNumber)
            }
        )
    }

    /// Catches a truncated or extended spelling of the same name
    /// ("santander" vs "santand"). Both sides must be at least four
    /// characters so short unrelated words can't collide.
    private static func sharePrefix(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4 else { return false }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}
