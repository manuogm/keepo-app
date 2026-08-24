import Foundation
import GRDB
import KeepoCore

// Ranking/duplicate reads for the capture notification's quick-action
// buttons — split out of CaptureLocalWrite.swift purely to keep that file
// under the project's type-body-length lint threshold, same precedent as
// OutboxLocalWrite+Cards.swift. Called from CaptureLocalWrite.resolveAndWrite
// inside the same already-open write transaction, so these never open a
// second dbQueue round trip.
enum CaptureQuickActionSuggestions {
    /// The merchant's own history, ranked by how often each category was
    /// used — the strongest signal available, since it's specific to this
    /// exact merchant rather than the account as a whole. `excluding` drops
    /// whichever category resolution already applied, so a "successful
    /// purchase" notification offers genuine *alternatives*, not a repeat
    /// of the button that's already covered by Confirm.
    static func topCategoriesForMerchant(
        _ database: Database, ownerId: String, merchantNormalized: String, excluding: String?, limit: Int
    ) throws -> [CaptureLocalWrite.Suggestion] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT t.category_id AS id, c.name AS name, COUNT(*) AS uses
            FROM transactions t JOIN categories c ON c.id = t.category_id
            WHERE t.owner_id = ? AND t.merchant_normalized = ? AND t.category_id IS NOT NULL
              AND (? IS NULL OR t.category_id != ?) AND t.deleted_at IS NULL AND c.deleted_at IS NULL
            GROUP BY t.category_id, c.name
            ORDER BY uses DESC
            LIMIT ?
            """,
            arguments: [ownerId, merchantNormalized, excluding, excluding, limit]
        ).map(CaptureLocalWrite.Suggestion.init(row:))
    }

    /// The fallback when the merchant has no history of its own (first
    /// visit, or every past visit used the same category `excluding` just
    /// dropped) — and the primary source for the "category unknown" branch,
    /// where there's no learned category to exclude at all.
    static func topCategoriesForAccount(
        _ database: Database, ownerId: String, accountId: String, excluding: String?, limit: Int
    ) throws -> [CaptureLocalWrite.Suggestion] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT t.category_id AS id, c.name AS name, COUNT(*) AS uses
            FROM transactions t JOIN categories c ON c.id = t.category_id
            WHERE t.owner_id = ? AND t.account_id = ? AND t.category_id IS NOT NULL
              AND (? IS NULL OR t.category_id != ?) AND t.deleted_at IS NULL AND c.deleted_at IS NULL
            GROUP BY t.category_id, c.name
            ORDER BY uses DESC
            LIMIT ?
            """,
            arguments: [ownerId, accountId, excluding, excluding, limit]
        ).map(CaptureLocalWrite.Suggestion.init(row:))
    }

    /// Candidates for "which account does this new card belong to" —
    /// `kind = 'regular'` (money rule: display/suggestion classification
    /// only, never balance computation), never already linked to a card.
    ///
    /// Ranked by name match first, usage second: a card called "Revolut
    /// Mastercard" almost certainly belongs to the account called
    /// "Revolut" no matter how little that account has been used, so
    /// `CardAccountMatcher` gets first say and the most-used ordering is
    /// only the fallback for cards whose name resembles nothing
    /// (device-testing feedback). The SQL still returns usage order, which
    /// is what the index below preserves as the tie-breaker — `sorted(by:)`
    /// is not documented as stable, so ties are broken explicitly rather
    /// than by relying on it.
    static func topUnmappedAccounts(
        _ database: Database, ownerId: String, cardIdentifier: String, limit: Int
    ) throws -> [CaptureLocalWrite.Suggestion] {
        let byUsage = try Row.fetchAll(
            database,
            sql: """
            SELECT a.id AS id, a.name AS name, COUNT(t.id) AS uses
            FROM accounts a
            LEFT JOIN transactions t ON t.account_id = a.id AND t.deleted_at IS NULL
            WHERE a.owner_id = ? AND a.kind = 'regular' AND a.deleted_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM card_mappings cm WHERE cm.account_id = a.id AND cm.deleted_at IS NULL
              )
            GROUP BY a.id, a.name
            ORDER BY uses DESC
            """,
            arguments: [ownerId]
        ).map(CaptureLocalWrite.Suggestion.init(row:))

        // Spelled out rather than chained — the fused
        // enumerated/map/sorted/prefix/map pipeline this replaced pushed
        // the type-checker past its budget (a real build failure, same
        // class of thing `RootView`'s own modifier chain hit).
        var ranked: [RankedAccount] = []
        ranked.reserveCapacity(byUsage.count)
        for (usageRank, suggestion) in byUsage.enumerated() {
            let score = CardAccountMatcher.matchScore(cardIdentifier: cardIdentifier, accountName: suggestion.name)
            ranked.append(RankedAccount(suggestion: suggestion, score: score, usageRank: usageRank))
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.usageRank < rhs.usageRank : lhs.score > rhs.score
        }
        return ranked.prefix(limit).map(\.suggestion)
    }

    private struct RankedAccount {
        let suggestion: CaptureLocalWrite.Suggestion
        let score: Int
        let usageRank: Int
    }

    /// The match key for `hasPossibleDuplicate` — grouped into its own type
    /// purely to keep that function's parameter count under the project's
    /// lint threshold. `amountE4` is the *stored*, already-signed value
    /// (`-abs(...)`), same convention as the `transactions` table itself,
    /// not the raw Wallet-automation amount.
    struct DuplicateCandidate {
        let cardIdentifier: String
        let merchantNormalized: String
        let amountE4: Int64
        let occurredAt: Date
    }

    /// Same card, merchant, and amount as another still-live transaction
    /// within a 15-minute window — wider than `CaptureIdentity.externalId`'s
    /// own 1-minute dedupe bucket (App/../CaptureIdentity.swift), which
    /// already collapses a rapid Shortcuts re-fire onto the same row. This
    /// catches what that bucket doesn't: a genuine second capture a few
    /// minutes later, the case Manu described (misfire, or an actual
    /// double-charge worth flagging for review).
    static func hasPossibleDuplicate(
        _ database: Database, ownerId: String, candidate: DuplicateCandidate, excluding: String
    ) throws -> Bool {
        let windowStart = PostgresDate.sqliteTimestampBoundaryString(candidate.occurredAt.addingTimeInterval(-15 * 60))
        let windowEnd = PostgresDate.sqliteTimestampBoundaryString(candidate.occurredAt.addingTimeInterval(15 * 60))
        return try Row.fetchOne(
            database,
            sql: """
            SELECT 1 FROM transactions
            WHERE owner_id = ? AND card_identifier = ? AND merchant_normalized = ? AND amount_e4 = ?
              AND id != ? AND deleted_at IS NULL AND occurred_at BETWEEN ? AND ?
            LIMIT 1
            """,
            arguments: [
                ownerId, candidate.cardIdentifier, candidate.merchantNormalized, candidate.amountE4, excluding,
                windowStart, windowEnd
            ]
        ) != nil
    }
}
