import Foundation
import GRDB
import KeepoCore
import Supabase

/// Builds `PublicSchema.TransactionsWithDetailsSelect` rows from the local
/// mirror (Phase L6) — the same type `TransactionRow`/`TransactionFormView`/
/// `MapCardSheet`/every other consumer already renders, so nothing
/// downstream of this file changes. That type has no public initializer
/// reachable from the App target (it's a plain `Codable` struct in the
/// `KeepoCore` package with no custom `init`, so only its synthesized,
/// public `init(from decoder:)` is usable cross-module) — so a row is built
/// as an `AnyJSON` object with the view's own snake_case column names and
/// decoded through that, rather than duplicating its ~20 fields into a
/// second, parallel struct the way `LocalMoneyQueries`'s other result types
/// do (those exist because their source isn't a straight table mirror
/// either, but nothing else already consumes their shape the way half the
/// app already consumes this one).
///
/// Mirrors `transactions_with_details`'s own view definition exactly
/// (`supabase/migrations/20260815100000_money_as_integers.sql`): `kind` is
/// `'transfer'` when `transfer_group_id` is set, else `'expense'`/`'income'`
/// by sign; `amount_base_e4`/`has_missing_rate` come from the same
/// `LocalMoneyConversion.convert` every other screen's FX conversion goes
/// through, at the transaction's own `occurred_at` date, exactly like the
/// view's `fx_convert(..., t.occurred_at::date)`.
enum LocalTransactionRow {
    /// Every local read here is scoped to accounts the signed-in user can
    /// currently see (owned, or shared into one of their households) — the
    /// same visibility rule `LocalAccountRow.fetchAll` already applies.
    /// Without it, a transaction whose account belongs to a different (e.g.
    /// stale, no-longer-current) identity still satisfies the plain
    /// `JOIN accounts` and stays visible forever with no way to delete it,
    /// since the server correctly refuses a write against an account this
    /// user can't write to.
    private static let visibleAccountClause = """
    (a.owner_id = ? OR a.id IN (
        SELECT ha.account_id FROM household_accounts ha
        JOIN household_members hm ON hm.household_id = ha.household_id
        WHERE hm.user_id = ? AND hm.deleted_at IS NULL AND ha.deleted_at IS NULL
    ))
    """

    /// Archiving an account (`archived_at`) hides its transactions from
    /// this list too — same "no physical flag on the row" approach the
    /// exclusion has everywhere else: visibility is derived live from the
    /// account's own archived state, not copied onto every transaction, so
    /// unarchiving makes them reappear with no backfill needed. The FK
    /// itself is untouched either way.
    static func fetchFiltered(
        _ database: Database, filter: TransactionFilter, baseCurrency: String, ownerId: String
    ) throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        var sql = """
        SELECT t.id, t.account_id, a.name AS account_name, t.category_id, c.name AS category_name,
               t.amount_e4, t.currency, cur.minor_unit, t.occurred_at, t.merchant_raw, t.merchant_normalized,
               t.transfer_group_id, t.source, t.status, t.created_by, t.created_at, t.version, t.recurring_rule_id,
               CASE WHEN t.transfer_group_id IS NOT NULL THEN 'transfer'
                    WHEN t.amount_e4 < 0 THEN 'expense' ELSE 'income' END AS kind
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
            AND a.deleted_at IS NULL AND a.archived_at IS NULL AND \(visibleAccountClause)
        LEFT JOIN categories c ON c.id = t.category_id
        JOIN currencies cur ON cur.code = t.currency
        WHERE t.deleted_at IS NULL
        """
        var arguments: [DatabaseValueConvertible] = [ownerId, ownerId]
        if let accountId = filter.accountId {
            sql += " AND t.account_id = ?"
            arguments.append(accountId.uuidString)
        }
        if let categoryId = filter.categoryId {
            sql += " AND t.category_id = ?"
            arguments.append(categoryId.uuidString)
        }
        if let kind = filter.kind {
            sql += """
             AND (CASE WHEN t.transfer_group_id IS NOT NULL THEN 'transfer'
                       WHEN t.amount_e4 < 0 THEN 'expense' ELSE 'income' END) = ?
            """
            arguments.append(kind)
        }
        if let from = filter.from {
            sql += " AND t.occurred_at >= ?"
            arguments.append(PostgresDate.sqliteTimestampBoundaryString(from))
        }
        if let through = filter.through {
            sql += " AND t.occurred_at <= ?"
            arguments.append(PostgresDate.sqliteTimestampBoundaryString(through))
        }
        if let search = filter.search, !search.isEmpty {
            sql += """
             AND (t.merchant_raw LIKE ? OR t.merchant_normalized LIKE ? OR c.name LIKE ? OR a.name LIKE ?)
            """
            let pattern = "%\(search)%"
            arguments.append(contentsOf: [pattern, pattern, pattern, pattern])
        }
        sql += " ORDER BY t.occurred_at DESC, t.id DESC"

        let rows = try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments))
        return try rows.map { try build($0, database: database, baseCurrency: baseCurrency) }
    }

    /// Both legs of a transfer, by group id — `TransactionFormView`'s
    /// post-conflict reload needs both sides re-fetched together, the same
    /// way it originally opened via `sibling(of:)`.
    static func fetchByTransferGroup(
        _ database: Database, transferGroupId: String, baseCurrency: String, ownerId: String
    ) throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT t.id, t.account_id, a.name AS account_name, t.category_id, c.name AS category_name,
                   t.amount_e4, t.currency, cur.minor_unit, t.occurred_at, t.merchant_raw, t.merchant_normalized,
                   t.transfer_group_id, t.source, t.status, t.created_by, t.created_at, t.version, t.recurring_rule_id,
                   CASE WHEN t.transfer_group_id IS NOT NULL THEN 'transfer'
                        WHEN t.amount_e4 < 0 THEN 'expense' ELSE 'income' END AS kind
            FROM transactions t
            JOIN accounts a ON a.id = t.account_id AND a.deleted_at IS NULL AND \(visibleAccountClause)
            LEFT JOIN categories c ON c.id = t.category_id
            JOIN currencies cur ON cur.code = t.currency
            WHERE t.deleted_at IS NULL AND t.transfer_group_id = ?
            """,
            arguments: [ownerId, ownerId, transferGroupId]
        )
        return try rows.map { try build($0, database: database, baseCurrency: baseCurrency) }
    }

    static func fetchOne(
        _ database: Database, id: String, baseCurrency: String, ownerId: String
    ) throws -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT t.id, t.account_id, a.name AS account_name, t.category_id, c.name AS category_name,
                   t.amount_e4, t.currency, cur.minor_unit, t.occurred_at, t.merchant_raw, t.merchant_normalized,
                   t.transfer_group_id, t.source, t.status, t.created_by, t.created_at, t.version, t.recurring_rule_id,
                   CASE WHEN t.transfer_group_id IS NOT NULL THEN 'transfer'
                        WHEN t.amount_e4 < 0 THEN 'expense' ELSE 'income' END AS kind
            FROM transactions t
            JOIN accounts a ON a.id = t.account_id AND a.deleted_at IS NULL AND \(visibleAccountClause)
            LEFT JOIN categories c ON c.id = t.category_id
            JOIN currencies cur ON cur.code = t.currency
            WHERE t.deleted_at IS NULL AND t.id = ?
            """,
            arguments: [ownerId, ownerId, id]
        ) else { return nil }
        return try build(row, database: database, baseCurrency: baseCurrency)
    }

    private static func build(
        _ row: Row, database: Database, baseCurrency: String
    ) throws -> PublicSchema.TransactionsWithDetailsSelect {
        let amountE4: Int64 = row["amount_e4"]
        let currency: String = row["currency"]
        let occurredAt: String = row["occurred_at"]
        let occurredDate = String(occurredAt.prefix(10))
        let amountBaseE4 = try LocalMoneyConversion.convert(
            database, amountE4: amountE4, from: currency, toCurrency: baseCurrency, date: occurredDate
        )
        let baseMinorUnit = try Int16.fetchOne(
            database, sql: "SELECT minor_unit FROM currencies WHERE code = ?", arguments: [baseCurrency]
        )

        let json: JSONObject = [
            "transaction_id": .string(row["id"]), "account_id": .string(row["account_id"]),
            "account_name": .string(row["account_name"]),
            "category_id": (row["category_id"] as String?).map(AnyJSON.string) ?? .null,
            "category_name": (row["category_name"] as String?).map(AnyJSON.string) ?? .null,
            "amount_e4": .integer(Int(amountE4)), "currency": .string(currency),
            "minor_unit": .integer(row["minor_unit"]), "occurred_at": .string(occurredAt),
            "merchant_raw": (row["merchant_raw"] as String?).map(AnyJSON.string) ?? .null,
            "merchant_normalized": (row["merchant_normalized"] as String?).map(AnyJSON.string) ?? .null,
            "transfer_group_id": (row["transfer_group_id"] as String?).map(AnyJSON.string) ?? .null,
            "source": .string(row["source"]), "status": .string(row["status"]), "kind": .string(row["kind"]),
            "created_by": .string(row["created_by"]), "created_at": .string(row["created_at"]),
            "version": .integer(row["version"]),
            "recurring_rule_id": (row["recurring_rule_id"] as String?).map(AnyJSON.string) ?? .null,
            "base_currency": .string(baseCurrency),
            "base_minor_unit": baseMinorUnit.map { .integer(Int($0)) } ?? .null,
            "amount_base_e4": amountBaseE4.map { .integer(Int($0)) } ?? .null,
            "has_missing_rate": .bool(amountBaseE4 == nil)
        ]
        let data = try JSONEncoder().encode(AnyJSON.object(json))
        return try JSONDecoder().decode(PublicSchema.TransactionsWithDetailsSelect.self, from: data)
    }

    /// Same reuse rationale as `build` above, for `needs_review`'s stable
    /// column contract — `LocalMoneyQueries.needsReview` already computes
    /// the three locally-derivable branches (`sync_conflict`,
    /// `pending_capture`, `ambiguous_card`); this just re-shapes each row
    /// into the exact type `NeedsReviewRow`/`MapCardSheet` already render.
    /// The server view's fourth branch, `csv_import_candidate`, never
    /// appears here — CSV import stays server-side entirely (the plan's own
    /// documented scope), so a local-only read has nothing to derive it
    /// from.
    static func needsReviewSelect(from row: NeedsReviewLocalRow) throws -> PublicSchema.NeedsReviewSelect {
        let json: JSONObject = [
            "kind": .string(row.kind), "item_id": .string(row.itemId),
            "account_id": row.accountId.map(AnyJSON.string) ?? .null, "occurred_at": .string(row.occurredAt),
            "title": .string(row.title), "subtitle": row.subtitle.map(AnyJSON.string) ?? .null,
            "amount_e4": row.amountE4.map { .integer(Int($0)) } ?? .null,
            "currency": row.currency.map(AnyJSON.string) ?? .null
        ]
        let data = try JSONEncoder().encode(AnyJSON.object(json))
        return try JSONDecoder().decode(PublicSchema.NeedsReviewSelect.self, from: data)
    }
}
