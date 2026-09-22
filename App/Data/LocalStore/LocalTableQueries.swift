import Foundation
import GRDB
import KeepoCore

/// Straight local reads of tables whose generated `PublicSchema.*Select`
/// type already matches the local mirror's columns 1:1 (Phase L6,
/// `keepo-local-first-plan.md`) — unlike `LocalMoneyQueries`/
/// `LocalMoneyConversion` (L4), which port *computed* views/functions and so
/// need their own result types, these are the plain-table screens (category
/// list, recurring rules, currencies, a single account or
/// transaction, household membership) where the generated Codable struct
/// already IS the row shape. Conforming it to `FetchableRecord` here (GRDB's
/// default `Decodable`-based decoder) reuses that struct instead of writing
/// a second, parallel one per table — CLAUDE.md's "reuse before writing".
///
/// Every read filters `deleted_at IS NULL` explicitly, even where the
/// server-side call didn't need to: PostgREST's own RLS/query already
/// excluded soft-deleted rows there, but the local mirror carries tombstones
/// as ordinary upserted rows (L5's sync applies a tombstone the same way as
/// any other write), so a local read has to filter for itself.
extension PublicSchema.CategoriesSelect: @retroactive FetchableRecord {}
extension PublicSchema.TagsSelect: @retroactive FetchableRecord {}
extension PublicSchema.RecurringRulesSelect: @retroactive FetchableRecord {}
extension PublicSchema.CurrenciesSelect: @retroactive FetchableRecord {}
extension PublicSchema.AccountsSelect: @retroactive FetchableRecord {}
extension PublicSchema.TransactionsSelect: @retroactive FetchableRecord {}
extension PublicSchema.HouseholdsSelect: @retroactive FetchableRecord {}
extension PublicSchema.HouseholdMembersSelect: @retroactive FetchableRecord {}
extension PublicSchema.HouseholdAccountsSelect: @retroactive FetchableRecord {}
extension PublicSchema.ProfilesSelect: @retroactive FetchableRecord {}
extension PublicSchema.CardMappingsSelect: @retroactive FetchableRecord {}

enum LocalTableQueries {
    /// **Your own** categories — the ones you can file a transaction under.
    ///
    /// Owner-scoped even though `categories_select` is no longer owner-only:
    /// since 20260912100000 a household member can *read* the other member's
    /// shared categories, but `transactions (category_id, owner_id) →
    /// categories (id, owner_id)` still forbids filing anything under one.
    /// Every picker in the app wants this list, and offering a row the
    /// foreign key would reject is worse than not offering it.
    ///
    /// The household screens want the other reading, and take
    /// `householdCategories` below.
    static func categories(_ database: Database, ownerId: String) throws -> [PublicSchema.CategoriesSelect] {
        try PublicSchema.CategoriesSelect.fetchAll(
            database,
            sql: "SELECT * FROM categories WHERE owner_id = ? AND deleted_at IS NULL ORDER BY kind, name",
            arguments: [ownerId]
        )
    }

    /// Every category this device can see, both members' included.
    ///
    /// Deliberately unfiltered, on the same reasoning as `tags` below: the
    /// pull already applies `can_read_category`, so the local table holds
    /// exactly what the server would return, and filtering by owner here
    /// would hide the other member's half of every shared pair — which is
    /// the half the household screens exist to show.
    static func householdCategories(_ database: Database) throws -> [PublicSchema.CategoriesSelect] {
        try PublicSchema.CategoriesSelect.fetchAll(
            database,
            sql: "SELECT * FROM categories WHERE deleted_at IS NULL ORDER BY kind, name COLLATE NOCASE"
        )
    }

    static func recurringRules(_ database: Database) throws -> [PublicSchema.RecurringRulesSelect] {
        try PublicSchema.RecurringRulesSelect.fetchAll(
            database, sql: "SELECT * FROM recurring_rules ORDER BY next_due_at"
        )
    }

    static func recurringRule(_ database: Database, id: String) throws -> PublicSchema.RecurringRulesSelect? {
        try PublicSchema.RecurringRulesSelect.fetchOne(
            database, sql: "SELECT * FROM recurring_rules WHERE id = ?", arguments: [id]
        )
    }

    /// Every tag the local mirror holds for this owner.
    ///
    /// **Not** owner-scoped the way `categories` is, deliberately: `tags`'
    /// own RLS is `can_read_tag`, which also admits a household member's tag
    /// once it has been applied to a transaction on a shared account. Scoping
    /// this read to `owner_id = me` would hide exactly those rows — the ones
    /// the sharing rule exists to surface — so it mirrors the server's
    /// visibility by not filtering at all, and lets the pull decide what is
    /// in the table.
    static func tags(_ database: Database) throws -> [PublicSchema.TagsSelect] {
        try PublicSchema.TagsSelect.fetchAll(
            database,
            sql: "SELECT * FROM tags WHERE deleted_at IS NULL ORDER BY name COLLATE NOCASE"
        )
    }

    /// The tag ids currently on one transaction.
    static func tagIds(_ database: Database, transactionId: String) throws -> [String] {
        try String.fetchAll(
            database,
            sql: "SELECT tag_id FROM transaction_tags WHERE transaction_id = ? AND deleted_at IS NULL",
            arguments: [transactionId]
        )
    }

    /// The tag ids currently on one recurring rule — the same query as
    /// `tagIds` above, one step earlier in the chain.
    static func recurringRuleTagIds(_ database: Database, ruleId: String) throws -> [String] {
        try String.fetchAll(
            database,
            sql: "SELECT tag_id FROM recurring_rule_tags WHERE recurring_rule_id = ? AND deleted_at IS NULL",
            arguments: [ruleId]
        )
    }

    static func currencies(_ database: Database) throws -> [PublicSchema.CurrenciesSelect] {
        try PublicSchema.CurrenciesSelect.fetchAll(database, sql: "SELECT * FROM currencies ORDER BY code")
    }

    static func account(_ database: Database, id: String) throws -> PublicSchema.AccountsSelect? {
        try PublicSchema.AccountsSelect.fetchOne(
            database, sql: "SELECT * FROM accounts WHERE id = ? AND deleted_at IS NULL", arguments: [id]
        )
    }

    static func accountsOwnedBy(_ database: Database, ownerId: String) throws -> [PublicSchema.AccountsSelect] {
        try PublicSchema.AccountsSelect.fetchAll(
            database,
            sql: "SELECT * FROM accounts WHERE owner_id = ? AND deleted_at IS NULL ORDER BY name",
            arguments: [ownerId]
        )
    }

    /// The instant-cold-start read (D): `SessionStore.start()` used to gate
    /// `.ready` on a network `refreshProfile()` call even though `profiles`
    /// is already in the local mirror — this is what lets it render
    /// immediately instead, with the network refresh happening in the
    /// background afterward.
    static func profile(_ database: Database, id: String) throws -> PublicSchema.ProfilesSelect? {
        try PublicSchema.ProfilesSelect.fetchOne(
            database, sql: "SELECT * FROM profiles WHERE id = ? AND deleted_at IS NULL", arguments: [id]
        )
    }

    static func transaction(_ database: Database, id: String) throws -> PublicSchema.TransactionsSelect? {
        try PublicSchema.TransactionsSelect.fetchOne(
            database, sql: "SELECT * FROM transactions WHERE id = ? AND deleted_at IS NULL", arguments: [id]
        )
    }

    /// The Account edit sheet's "Mapped Cards" section — every card
    /// currently linked to this account, owner-scoped like every other
    /// read here (`card_mappings` is per-user, never household-shared).
    static func cardMappings(
        _ database: Database, accountId: String, ownerId: String
    ) throws -> [PublicSchema.CardMappingsSelect] {
        try PublicSchema.CardMappingsSelect.fetchAll(
            database,
            sql: """
            SELECT * FROM card_mappings WHERE account_id = ? AND owner_id = ? AND deleted_at IS NULL
            ORDER BY card_identifier
            """,
            arguments: [accountId, ownerId]
        )
    }

    static func cardMapping(_ database: Database, id: String) throws -> PublicSchema.CardMappingsSelect? {
        try PublicSchema.CardMappingsSelect.fetchOne(
            database, sql: "SELECT * FROM card_mappings WHERE id = ? AND deleted_at IS NULL", arguments: [id]
        )
    }

    // MARK: - scope availability

    /// How many accounts the user can see at all, and how many of those are
    /// shared into their household — the two counts every "this scope has
    /// nothing in it" blank state is decided from (`ScopeContext`).
    ///
    /// Counted in SQL rather than by filtering `LocalAccountRow.fetchAll`,
    /// which is the same visibility clause but also FX-converts a balance
    /// for every account on the way. Nothing here needs a figure — only
    /// whether a row exists — and that read runs on every refresh.
    ///
    /// "Shared" is `household_accounts`, matching `LocalMoneyQueries
    /// .scopeFilterSQL` exactly, so "private" here means precisely what the
    /// `me` scope means everywhere else: visible and not shared. Archived
    /// accounts are excluded — they are out of every balance on screen, so
    /// a user whose only account is archived is correctly told they have
    /// none to look at.
    struct ScopeAvailability {
        let visibleCount: Int
        let sharedCount: Int
    }

    static func scopeAvailability(_ database: Database, ownerId: String) throws -> ScopeAvailability {
        let row = try Row.fetchOne(
            database,
            sql: """
            SELECT
                COUNT(*) AS visible_count,
                COALESCE(SUM(CASE WHEN shared.account_id IS NULL THEN 0 ELSE 1 END), 0) AS shared_count
            FROM accounts a
            LEFT JOIN (
                SELECT DISTINCT ha.account_id FROM household_accounts ha
                JOIN household_members hm ON hm.household_id = ha.household_id
                WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND ha.deleted_at IS NULL
            ) shared ON shared.account_id = a.id
            WHERE a.deleted_at IS NULL AND a.archived_at IS NULL
                AND (a.owner_id = ? OR shared.account_id IS NOT NULL)
            """,
            arguments: [ownerId, ownerId]
        )
        return ScopeAvailability(
            visibleCount: row?["visible_count"] ?? 0, sharedCount: row?["shared_count"] ?? 0
        )
    }

    // MARK: - households (read side only — create/share/unshare/invite/leave stay writes on Outbox/network)

    static func myHousehold(_ database: Database, userId: String) throws -> PublicSchema.HouseholdsSelect? {
        try PublicSchema.HouseholdsSelect.fetchOne(
            database,
            sql: """
            SELECT h.* FROM households h
            JOIN household_members hm ON hm.household_id = h.id
            WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND h.deleted_at IS NULL
            """,
            arguments: [userId]
        )
    }

    static func householdMembers(
        _ database: Database, householdId: String
    ) throws -> [PublicSchema.HouseholdMembersSelect] {
        try PublicSchema.HouseholdMembersSelect.fetchAll(
            database,
            sql: "SELECT * FROM household_members WHERE household_id = ? AND deleted_at IS NULL",
            arguments: [householdId]
        )
    }

    static func sharedAccountIds(_ database: Database, householdId: String) throws -> Set<String> {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT account_id FROM household_accounts WHERE household_id = ? AND deleted_at IS NULL",
            arguments: [householdId]
        )
        return Set(rows.map { $0["account_id"] as String })
    }

    /// How many live transactions one account still holds.
    ///
    /// Read before offering to delete an archived account, so the
    /// confirmation can name the number rather than let the server refuse
    /// and make the user decode the refusal. A count, not the rows: the
    /// screen needs the figure and nothing else, and an account's whole
    /// history can be thousands of rows.
    static func transactionCount(_ database: Database, accountId: String) throws -> Int {
        try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM transactions WHERE account_id = ? AND deleted_at IS NULL",
            arguments: [accountId]
        ) ?? 0
    }

    /// The single `household_accounts` row for one account, `shared_at`
    /// included — unlike `sharedAccountIds`, which only answers "is this
    /// shared" for a whole household's worth of accounts at once.
    static func sharedAccountRow(
        _ database: Database, householdId: String, accountId: String
    ) throws -> PublicSchema.HouseholdAccountsSelect? {
        try PublicSchema.HouseholdAccountsSelect.fetchOne(
            database,
            sql: """
            SELECT * FROM household_accounts
            WHERE household_id = ? AND account_id = ? AND deleted_at IS NULL
            """,
            arguments: [householdId, accountId]
        )
    }
}
