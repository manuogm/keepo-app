import Foundation
import GRDB
import KeepoCore

// A rule has nine fields and both writers below set all of them; bundling them
// into a parameter object would be a type that exists only to satisfy a lint
// rule. `RecurringRuleRepository`'s own writers carry the same exemption for
// the same reason.
// swiftlint:disable function_parameter_count

/// Mirrors a recurring-rule write into the local store the instant the
/// server accepts it, so the screen that made the write is looking at what
/// it just did.
///
/// **Why this is needed at all.** `RecurringRuleRepository` writes straight
/// to PostgREST — it is not an outbox path, because a rule is edited rarely
/// and by one person, and the versioned RPC machinery transactions need does
/// not earn its keep here. But `RecurringRulesView` reads the **local
/// mirror**, and `RefreshCoordinator.bump()` only invalidates screens; it
/// does not pull. So without a write-through, a rule created, edited or
/// paused sat invisible until the next sync pull happened to land.
///
/// The switch on each row is what made that unmissable: the user flips it,
/// the reload reads the mirror, the mirror still says the old value, and the
/// switch springs back under their finger while the server quietly holds the
/// new value. Same reasoning as `AccountLocalWrite.delete` — the window
/// between a successful write and the next pull is exactly the window the
/// user is looking at.
enum RecurringRuleLocalWrite {
    /// Pausing or resuming. Bumps `updated_at` the way the server's own
    /// trigger just did, so a later pull carrying the same change is a
    /// no-op rather than a visible flicker back and forth.
    ///
    /// `version` and `sync_seq` are deliberately left alone: both are the
    /// server's to assign, and guessing at them here would make the next
    /// pull look like a conflict.
    static func setActive(id: UUID, active: Bool, in database: Database) throws {
        try database.execute(
            sql: "UPDATE recurring_rules SET active = ?, updated_at = ? WHERE id = ?",
            arguments: [active, PostgresDate.sqliteTimestampBoundaryString(Date()), id.uuidString]
        )
    }

    /// An edit, applied to the row already in the mirror.
    ///
    /// **Both shape columns are written every time, one of them as NULL** —
    /// the same reason `RecurringRuleRepository.update` hand-encodes its
    /// patch. Turning an expense rule into a transfer has to clear the
    /// category as well as set the destination, or the local row carries
    /// both and `LocalRecurringRuleRow.fetchAll` resolves it to whichever
    /// branch it tests first, which would be a row disagreeing with the
    /// server it was just written from.
    static func update(
        id: UUID,
        accountId: UUID,
        target: RecurringRuleRepository.Target,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date,
        active: Bool,
        notes: String?,
        title: String?,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE recurring_rules
            SET account_id = ?, category_id = ?, to_account_id = ?, amount_e4 = ?, currency = ?,
                notes = ?, title = ?, frequency = ?, next_due_at = ?, active = ?, updated_at = ?
            WHERE id = ?
            """,
            arguments: [
                accountId.uuidString, target.categoryId?.uuidString, target.toAccountId?.uuidString,
                amountE4, currency, notes, title, frequency.rawValue, PostgresDate.dateOnlyString(nextDueAt),
                active, PostgresDate.sqliteTimestampBoundaryString(Date()), id.uuidString
            ]
        )
    }

    /// A newly created rule.
    ///
    /// `owner_id` is the account's owner, read the way the server's
    /// `set_recurring_rule_owner` trigger reads it: a partner's rule on the
    /// owner's shared account is the owner's. `created_by` is whoever made
    /// it. For a transfer both ends share an owner by composite foreign key
    /// (migration 20260927100000).
    ///
    /// The category is kept as sent. On someone else's account the server
    /// swaps it for the owner's counterpart (`owners_category`), which the
    /// next pull brings back — the same name either way.
    ///
    /// `version` starts at 1 and `sync_seq` at 0 to match the server's own
    /// defaults for a fresh row. `sync_seq` being 0 is the load-bearing half:
    /// every real value the server assigns is greater, so the next pull
    /// always wins over this optimistic copy rather than being mistaken for
    /// older news.
    static func insert(
        id: UUID,
        createdBy: UUID,
        accountId: UUID,
        target: RecurringRuleRepository.Target,
        amountE4: Int64,
        currency: String,
        frequency: PublicSchema.RecurringFrequency,
        nextDueAt: Date,
        notes: String?,
        title: String?,
        in database: Database
    ) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            INSERT OR REPLACE INTO recurring_rules (
                id, owner_id, created_by, account_id, category_id, to_account_id, amount_e4, currency,
                notes, title, frequency, next_due_at, last_materialized_at, active, version,
                created_at, updated_at, sync_seq
            ) VALUES (
                ?, COALESCE((SELECT owner_id FROM accounts WHERE id = ?), ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                NULL, 1, 1, ?, ?, 0
            )
            """,
            arguments: [
                id.uuidString, accountId.uuidString, createdBy.uuidString, createdBy.uuidString, accountId.uuidString,
                target.categoryId?.uuidString, target.toAccountId?.uuidString, amountE4, currency,
                notes, title, frequency.rawValue, PostgresDate.dateOnlyString(nextDueAt), now, now
            ]
        )
    }

    /// Mirrors a tag-link change, soft-deleting and reviving rather than
    /// deleting — the same contract the server write uses, because
    /// `(recurring_rule_id, tag_id)` is a primary key carrying tombstones the
    /// other device pulls.
    static func setTags(
        ruleId: UUID, ownerId: UUID, tagIds: Set<UUID>, previous: Set<UUID>, in database: Database
    ) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())

        for tagId in tagIds.subtracting(previous) {
            try database.execute(
                sql: """
                INSERT INTO recurring_rule_tags
                    (recurring_rule_id, tag_id, owner_id, created_at, updated_at, deleted_at, sync_seq)
                VALUES (?, ?, ?, ?, ?, NULL, 0)
                ON CONFLICT (recurring_rule_id, tag_id)
                DO UPDATE SET deleted_at = NULL, updated_at = excluded.updated_at
                """,
                arguments: [ruleId.uuidString, tagId.uuidString, ownerId.uuidString, now, now]
            )
        }

        for tagId in previous.subtracting(tagIds) {
            try database.execute(
                sql: """
                UPDATE recurring_rule_tags SET deleted_at = ?, updated_at = ?
                WHERE recurring_rule_id = ? AND tag_id = ?
                """,
                arguments: [now, now, ruleId.uuidString, tagId.uuidString]
            )
        }
    }
}
// swiftlint:enable function_parameter_count
