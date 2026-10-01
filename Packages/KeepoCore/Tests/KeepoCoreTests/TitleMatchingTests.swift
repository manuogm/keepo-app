import Foundation
import Testing

@testable import KeepoCore

/// A title's route to a category. The two directions the feature has — a typed
/// title suggesting a category, and an unknown merchant matching a title the
/// user typed before — both rest on these three functions, so the cases that
/// would make either of them confidently wrong are pinned here by name.
@Suite("Title matching")
struct TitleMatchingTests {
    // MARK: - key(for:)

    @Test("a title keys the way a merchant does, so the two are comparable", arguments: [
        ("Starbucks", "STARBUCKS"),
        ("  starbucks  ", "STARBUCKS"),
        ("Target #4821", "TARGET"),
        ("Coffee with Beth", "COFFEE WITH BETH")
    ])
    func keysLikeAMerchant(pair: (String, String)) {
        #expect(TitleMatching.key(for: pair.0) == pair.1)
    }

    @Test("a blank title has no key — it is not a title", arguments: ["", "   ", "\n"])
    func blankHasNoKey(title: String) {
        #expect(TitleMatching.key(for: title) == nil)
    }

    @Test("a title and a captured merchant land on the same key")
    func titleMeetsMerchant() {
        #expect(TitleMatching.key(for: "Blue Bottle") == MerchantNormalizer.normalize("SQ *BLUE BOTTLE"))
    }

    // MARK: - leadingWordPrefixes(of:)

    @Test("prefixes run longest first, whole words only")
    func prefixesLongestFirst() {
        #expect(
            TitleMatching.leadingWordPrefixes(of: "STARBUCKS COFFEE BEANS")
                == ["STARBUCKS COFFEE BEANS", "STARBUCKS COFFEE", "STARBUCKS"]
        )
    }

    @Test("a word is never cut, so SHELLFISH does not become SHELL")
    func wholeWordsOnly() {
        #expect(!TitleMatching.leadingWordPrefixes(of: "SHELLFISH DINNER").contains("SHELL"))
    }

    @Test("an empty key has no prefixes")
    func emptyKey() {
        #expect(TitleMatching.leadingWordPrefixes(of: "").isEmpty)
    }

    // MARK: - bestCategory(for:among:)

    private func use(_ title: String, _ category: String, _ count: Int, _ last: String) -> TitleMatching.Use {
        TitleMatching.Use(title: title, categoryId: category, count: count, lastUsedAt: last)
    }

    @Test("the most-used category for a title wins, not the most recent")
    func mostUsedWins() {
        let uses = [
            use("Lunch", "dining", 9, "2026-08-01 12:00:00.000000+00:00"),
            use("Lunch", "groceries", 1, "2026-09-20 12:00:00.000000+00:00")
        ]
        #expect(TitleMatching.bestCategory(for: "LUNCH", among: uses) == "dining")
    }

    @Test("recency breaks a tie in use count")
    func recencyBreaksTie() {
        let uses = [
            use("Lunch", "dining", 2, "2026-08-01 12:00:00.000000+00:00"),
            use("Lunch", "groceries", 2, "2026-09-20 12:00:00.000000+00:00")
        ]
        #expect(TitleMatching.bestCategory(for: "LUNCH", among: uses) == "groceries")
    }

    @Test("spellings that key the same are tallied as one title")
    func variantsTallyTogether() {
        let uses = [
            use("lunch ", "dining", 2, "2026-08-01 12:00:00.000000+00:00"),
            use("LUNCH", "dining", 2, "2026-08-02 12:00:00.000000+00:00"),
            use("Lunch", "groceries", 3, "2026-09-20 12:00:00.000000+00:00")
        ]
        #expect(TitleMatching.bestCategory(for: "LUNCH", among: uses) == "dining")
    }

    @Test("titles with a different key take no part")
    func otherTitlesIgnored() {
        let uses = [use("Lunch with Sam", "dining", 5, "2026-09-20 12:00:00.000000+00:00")]
        #expect(TitleMatching.bestCategory(for: "LUNCH", among: uses) == nil)
    }

    @Test("an exact tie resolves the same way whatever order the rows arrive in")
    func stableOnExactTie() {
        let forward = [
            use("Gym", "a", 1, "2026-09-01 00:00:00.000000+00:00"),
            use("Gym", "b", 1, "2026-09-01 00:00:00.000000+00:00")
        ]
        #expect(
            TitleMatching.bestCategory(for: "GYM", among: forward)
                == TitleMatching.bestCategory(for: "GYM", among: forward.reversed())
        )
    }
}

/// What a form stores for what was typed — the client half of the server's
/// title CHECK, so the two cannot disagree.
@Suite("Transaction title shape")
struct TransactionTitleTests {
    @Test("blank input stores no title at all, never an empty string", arguments: ["", "   ", "\n\t"])
    func blankIsNil(typed: String) {
        #expect(TransactionTitle.stored(typed) == nil)
    }

    @Test("surrounding whitespace is trimmed")
    func trims() {
        #expect(TransactionTitle.stored("  Coffee with Beth ") == "Coffee with Beth")
    }

    @Test("a title is capped at the server's limit, and trimmed again after the cap")
    func capped() {
        let typed = String(repeating: "a", count: TransactionTitle.maxLength - 1) + " tail"
        let stored = TransactionTitle.stored(typed)
        #expect(stored?.count == TransactionTitle.maxLength - 1)
        #expect(stored?.hasSuffix(" ") == false)
    }
}
