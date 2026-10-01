import Foundation
import GRDB
import KeepoCore

// The counts behind the transaction form's tag suggestions — split out of
// LocalTableQueries.swift for the file-length lint. What counts as "alike",
// and how the counts rank, is `TagSuggestions`' to say; these only count.

extension LocalTableQueries {
    /// Every tag used on a transaction in `categoryId`, with how many of
    /// those were on `accountId` (close) and how many in all (broad).
    static func tagUsage(
        _ database: Database, categoryId: String, accountId: String?
    ) throws -> [TagSuggestions.Usage] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT tg.id AS tag_id, tg.name AS name,
                       SUM(CASE WHEN t.account_id = ? THEN 1 ELSE 0 END) AS close,
                       COUNT(*) AS broad
                FROM transaction_tags tt
                JOIN transactions t ON t.id = tt.transaction_id AND t.deleted_at IS NULL
                JOIN tags tg ON tg.id = tt.tag_id AND tg.deleted_at IS NULL
                WHERE tt.deleted_at IS NULL AND t.category_id = ?
                GROUP BY tg.id
                """,
            arguments: [accountId, categoryId]
        )
        .map(usage)
    }

    /// Every tag used on a transfer that leaves `fromAccountId` or reaches
    /// `toAccountId`, with how many of those ran between exactly that pair
    /// (close) and how many in all (broad).
    ///
    /// A transfer's tags sit on its outflow leg (`applyTagChanges`), so the
    /// tagged row's own account is the origin and the destination is the
    /// other leg of its group — joined LEFT, because that leg may be on an
    /// account this viewer cannot see.
    static func transferTagUsage(
        _ database: Database, fromAccountId: String?, toAccountId: String?
    ) throws -> [TagSuggestions.Usage] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT tg.id AS tag_id, tg.name AS name,
                       SUM(CASE WHEN t.account_id = ? AND p.account_id = ? THEN 1 ELSE 0 END) AS close,
                       COUNT(*) AS broad
                FROM transaction_tags tt
                JOIN transactions t ON t.id = tt.transaction_id AND t.deleted_at IS NULL
                     AND t.transfer_group_id IS NOT NULL
                LEFT JOIN transactions p ON p.transfer_group_id = t.transfer_group_id AND p.id != t.id
                     AND p.deleted_at IS NULL
                JOIN tags tg ON tg.id = tt.tag_id AND tg.deleted_at IS NULL
                WHERE tt.deleted_at IS NULL AND (t.account_id = ? OR p.account_id = ?)
                GROUP BY tg.id
                """,
            arguments: [fromAccountId, toAccountId, fromAccountId, toAccountId]
        )
        .map(usage)
    }

    private static func usage(_ row: Row) -> TagSuggestions.Usage {
        TagSuggestions.Usage(tagId: row["tag_id"], name: row["name"], close: row["close"], broad: row["broad"])
    }
}
