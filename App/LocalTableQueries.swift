import Foundation
import GRDB
import KeepoCore

/// Straight local reads of tables whose generated `PublicSchema.*Select`
/// type already matches the local mirror's columns 1:1 (Phase L6,
/// `keepo-local-first-plan.md`) — unlike `LocalMoneyQueries`/
/// `LocalMoneyConversion` (L4), which port *computed* views/functions and so
/// need their own result types, these are the plain-table screens (category
/// list, budget list, recurring rules, currencies, a single account or
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
extension PublicSchema.BudgetsSelect: @retroactive FetchableRecord {}
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
    static func categories(_ database: Database) throws -> [PublicSchema.CategoriesSelect] {
        try PublicSchema.CategoriesSelect.fetchAll(
            database, sql: "SELECT * FROM categories WHERE deleted_at IS NULL ORDER BY kind, name"
        )
    }

    static func budgets(_ database: Database, ownerId: String) throws -> [PublicSchema.BudgetsSelect] {
        try PublicSchema.BudgetsSelect.fetchAll(
            database,
            sql: """
            SELECT * FROM budgets WHERE owner_id = ? AND deleted_at IS NULL ORDER BY period_month DESC
            """,
            arguments: [ownerId]
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
}
