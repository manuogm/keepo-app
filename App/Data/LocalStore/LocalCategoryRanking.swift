import Foundation
import GRDB
import KeepoCore

/// **"Which categories does this person actually reach for?"** — asked in
/// one place, because two places asking it would answer it differently.
///
/// Two screens need it for the same reason and would otherwise each carry
/// their own `GROUP BY`: the capture notification's quick-action buttons
/// (`CaptureQuickActionSuggestions`, which was where this SQL lived) and
/// the transaction form's three suggested chips. A capture and a
/// hand-typed entry are the same user filing the same kind of purchase, so
/// they had better agree on what "most used" means.
enum LocalCategoryRanking {
    /// Most-filed first, over the user's own confirmed and pending rows.
    ///
    /// Every filter is optional and additive, because the two callers ask
    /// slightly different questions of the same history:
    /// - `accountId` — this account's habits. `nil` widens to the whole
    ///   ledger, which is the fallback for an account with no history of
    ///   its own (a new card's first purchase should still get sensible
    ///   chips).
    /// - `categoryKind` — `expense` or `income`, from `categories.kind`.
    ///   The form must never suggest a category the save would then
    ///   reject; capture passes `nil` because a tap-to-pay purchase is an
    ///   expense by construction.
    /// - `excluding` — one category to leave out, so a notification
    ///   offering alternatives does not repeat the button beside it.
    ///
    /// **The tie-break is deliberate.** Counting alone leaves categories
    /// with equal use in whatever order SQLite happens to return, which can
    /// change between runs on the same data; `MAX(occurred_at)` breaks the
    /// tie towards the one used most recently — the better guess anyway,
    /// and stable, which matters for chips that must not reshuffle
    /// underneath a finger.
    static func mostUsed(
        _ database: Database,
        ownerId: String,
        accountId: String? = nil,
        categoryKind: String? = nil,
        excluding: String? = nil,
        limit: Int
    ) throws -> [CaptureLocalWrite.Suggestion] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT t.category_id AS id, c.name AS name, COUNT(*) AS uses
            FROM transactions t JOIN categories c ON c.id = t.category_id
            WHERE t.owner_id = ? AND t.category_id IS NOT NULL
              AND (? IS NULL OR t.account_id = ?)
              AND (? IS NULL OR c.kind = ?)
              AND (? IS NULL OR t.category_id != ?)
              AND t.deleted_at IS NULL AND c.deleted_at IS NULL
            GROUP BY t.category_id, c.name
            ORDER BY uses DESC, MAX(t.occurred_at) DESC
            LIMIT ?
            """,
            arguments: [
                ownerId, accountId, accountId, categoryKind, categoryKind, excluding, excluding, limit
            ]
        ).map(CaptureLocalWrite.Suggestion.init(row:))
    }
}
