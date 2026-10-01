import Foundation

/// What a transaction's title can say about its category — the pure half.
/// The app target runs the queries (`LocalTitleMemory`); everything that
/// decides a match lives here, where it can be pinned by tests.
///
/// **There is no title table.** The "memory" is the user's own titled
/// transactions: every one of them already records which category that title
/// was filed under, and re-filing one updates the memory without anything
/// else to keep in step. A title is never written into
/// `merchant_category_map` — the merchant model learns from what the card
/// network printed, and a title is what the person calls it.
///
/// **A title is keyed the way a merchant is**, through `MerchantNormalizer`,
/// so the two live in one key space: "Target", "target " and
/// "TARGET #4821" are the same key, and that key is directly comparable with
/// a captured merchant's `merchant_normalized`. The normalizer runs in Swift
/// only — the same one-implementation rule capture already follows — which
/// is why the server never matches titles itself and only ever receives the
/// device's answer as a category hint.
public enum TitleMatching {
    /// The comparison key for a title, or `nil` for one that is blank.
    public static func key(for title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = MerchantNormalizer.normalize(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    /// The key followed by every shorter run of its leading words, longest
    /// first — `"STARBUCKS COFFEE BEANS"` gives itself, `"STARBUCKS COFFEE"`
    /// and `"STARBUCKS"`.
    ///
    /// **Whole words only**, so `"SHELLFISH DINNER"` can never produce
    /// `"SHELL"`. Longest first, so the most specific thing Keepo knows wins:
    /// a user who has filed both "Starbucks" and "Starbucks Reserve" gets the
    /// second for "Starbucks Reserve tasting".
    ///
    /// Only the form uses the shorter prefixes. A capture matches on the
    /// whole key alone, because nobody is watching when a capture is filed and
    /// a loose match there (`APPLE` against "Apple pie for mom") would be a
    /// confident wrong answer rather than a suggestion somebody can decline.
    public static func leadingWordPrefixes(of key: String) -> [String] {
        let words = key.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return (1...words.count).reversed().map { words.prefix($0).joined(separator: " ") }
    }

    /// One (title, category) pairing as the ledger has it: how many
    /// transactions carry it and when the latest one happened. Titles are
    /// raw, as typed — grouping by key is this type's job, not the query's,
    /// because SQL cannot run the normalizer.
    public struct Use: Equatable, Sendable {
        public let title: String
        public let categoryId: String
        public let count: Int
        /// A synced timestamp string. Compared as text, which is sound
        /// because every value in the local mirror shares one rendering.
        public let lastUsedAt: String

        public init(title: String, categoryId: String, count: Int, lastUsedAt: String) {
            self.title = title
            self.categoryId = categoryId
            self.count = count
            self.lastUsedAt = lastUsedAt
        }
    }

    /// The category the user files `key` under most often, the most recent
    /// breaking a tie — the same rule `LocalCategoryRanking` uses for the
    /// form's chips, so "most used" means one thing across the app. The
    /// category id breaks a tie that survives both, so the answer never
    /// depends on the order the rows arrived in.
    ///
    /// Tallied across every raw title that keys the same, so "Lunch" filed
    /// four times and "lunch " filed once are five uses of one title.
    public static func bestCategory(for key: String, among uses: [Use]) -> String? {
        var tally: [String: (count: Int, lastUsedAt: String)] = [:]
        for use in uses where Self.key(for: use.title) == key {
            let current = tally[use.categoryId] ?? (0, "")
            tally[use.categoryId] = (current.count + use.count, max(current.lastUsedAt, use.lastUsedAt))
        }
        return tally.max { lhs, rhs in
            (lhs.value.count, lhs.value.lastUsedAt, lhs.key) < (rhs.value.count, rhs.value.lastUsedAt, rhs.key)
        }?.key
    }
}

/// The shape a stored title has — the client half of the server's
/// `transactions_title_shape` / `recurring_rules_title_shape` CHECKs, in one
/// place so the transaction form and the recurring form cannot disagree
/// about what "no title" means.
public enum TransactionTitle {
    /// The server's limit. The fields stop accepting characters here rather
    /// than letting a save fail on a constraint the user cannot see.
    public static let maxLength = 80

    /// What to store for what was typed: trimmed, capped, and `nil` when
    /// nothing is left — never `""`, which the CHECK refuses and which would
    /// make "has a title" a string comparison instead of a null check.
    public static func stored(_ typed: String) -> String? {
        let capped = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        // Trimmed again: the cap can land on a space.
        let trimmed = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
