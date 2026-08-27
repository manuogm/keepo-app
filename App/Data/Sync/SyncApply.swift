import Foundation
import GRDB
import KeepoCore
import Supabase

/// Applies one `pull_changes` payload to the local GRDB mirror (Phase L5,
/// `keepo-local-first-plan.md`). One generic upsert routine driven by the
/// JSON row's own keys, rather than sixteen hand-written per-table
/// functions — every syncable table's local columns are already named to
/// match the server 1:1 (`LocalStore.swift`'s own design), so there is
/// nothing table-specific left to write once the primary key is known.
///
/// A "tombstone" needs no special DELETE path: a soft-deleted server row
/// still has a payload (its `deleted_at` is simply non-null), so upserting
/// it normally is already correct — every local money query already
/// filters `deleted_at IS NULL` itself (`LocalMoneyQueries`'s own design).
enum SyncApply {
    /// Every column the JSON row is allowed to write, matching
    /// `LocalSchemaV1` exactly — a whitelist, not a blind pass-through, so
    /// an unexpected key in the payload (a schema drift the client hasn't
    /// caught up to yet) is silently ignored rather than reaching raw SQL
    /// string interpolation as a column name.
    private static let tableColumns: [String: Set<String>] = [
        "accounts": [
            "id", "owner_id", "created_by", "kind", "name", "currency", "opening_balance_e4",
            "opening_balance_at", "include_in_total", "icon", "color", "sort_order", "archived_at", "version",
            "deleted_at", "created_at", "updated_at", "sync_seq"
        ],
        "transactions": [
            "id", "owner_id", "created_by", "account_id", "category_id", "category_kind",
            "amount_e4", "currency", "occurred_at", "merchant_raw", "merchant_normalized", "notes",
            "card_identifier", "transfer_group_id", "source", "status", "external_id", "recurring_rule_id",
            "version", "deleted_at", "created_at", "updated_at", "sync_seq"
        ],
        "categories": [
            "id", "owner_id", "kind", "name", "is_default", "icon", "color", "version", "deleted_at", "created_at",
            "updated_at", "sync_seq"
        ],
        "recurring_rules": [
            "id", "owner_id", "created_by", "account_id", "category_id", "amount_e4", "currency", "frequency",
            "next_due_at", "last_materialized_at", "active", "version", "created_at", "updated_at", "sync_seq"
        ],
        "budgets": [
            "id", "owner_id", "category_id", "period_month", "amount_e4", "currency", "version", "deleted_at",
            "created_at", "updated_at", "sync_seq"
        ],
        "currencies": ["code", "minor_unit", "sync_seq"],
        "fx_rates": ["currency", "rate_date", "units_per_eur", "source", "fetched_at", "sync_seq"],
        "card_mappings": [
            "id", "owner_id", "card_identifier", "account_id", "source", "created_at", "updated_at", "deleted_at",
            "sync_seq"
        ],
        "merchant_category_map": [
            "owner_id", "merchant_pattern", "category_id", "updated_at", "deleted_at", "sync_seq"
        ],
        "sync_conflicts": [
            "id", "table_name", "row_id", "owner_id", "client_version", "server_version", "created_at",
            "resolved_at", "deleted_at", "sync_seq"
        ],
        "households": ["id", "created_at", "deleted_at", "sync_seq"],
        "household_members": ["household_id", "user_id", "joined_at", "deleted_at", "sync_seq"],
        "household_accounts": ["household_id", "account_id", "shared_at", "deleted_at", "sync_seq"],
        "profiles": [
            "id", "base_currency", "onboarded_at", "created_at", "updated_at", "deleted_at", "sync_epoch", "sync_seq"
        ]
    ]

    private static let primaryKeys: [String: [String]] = [
        "accounts": ["id"], "transactions": ["id"], "categories": ["id"],
        "recurring_rules": ["id"], "budgets": ["id"], "currencies": ["code"],
        "fx_rates": ["currency", "rate_date"], "card_mappings": ["id"],
        "merchant_category_map": ["owner_id", "merchant_pattern"], "sync_conflicts": ["id"], "households": ["id"],
        "household_members": ["household_id", "user_id"], "household_accounts": ["household_id", "account_id"],
        "profiles": ["id"]
    ]

    /// Every table `SyncCursorStore`'s epoch-mismatch wipe clears, keeping
    /// `outbox_items` untouched — the exact same table set `tableColumns`
    /// covers, kept as its own list so a caller doesn't need to import GRDB
    /// just to enumerate `tableColumns.keys`.
    static let syncableTables = Array(tableColumns.keys)

    /// Applies every table's array of rows from one `pull_changes` payload,
    /// in a single caller-supplied transaction (the caller — `SyncEngine` —
    /// wraps this in `dbQueue.write`, so a batch is atomic: never half-applied).
    static func apply(_ payload: AnyJSON, in database: Database) throws {
        guard let tables = payload.objectValue else { return }
        for (tableName, rows) in tables {
            guard let columns = tableColumns[tableName], let rowArray = rows.arrayValue else { continue }
            for row in rowArray {
                guard let rowObject = row.objectValue else { continue }
                try upsert(rowObject, table: tableName, allowedColumns: columns, database)
            }
        }
    }

    /// Single-row entry point for `Outbox`'s optimistic local write-through
    /// (Phase L6) — the same whitelist-guarded upsert `apply` uses per pull
    /// row, callable directly for one table without a full `pull_changes`
    /// payload shape. Silently no-ops on an unknown table or a row missing
    /// its primary key, exactly like `apply`'s own per-row handling.
    static func upsertRow(_ row: JSONObject, table: String, in database: Database) throws {
        guard let columns = tableColumns[table] else { return }
        try upsert(row, table: table, allowedColumns: columns, database)
    }

    /// UPDATE-then-INSERT, never a single `INSERT ... ON CONFLICT DO UPDATE`
    /// (B, found chasing a real bug: `archiveAccount`'s local echo silently
    /// no-op'd every time). SQLite validates NOT NULL on the INSERT's
    /// candidate row before it even checks for a conflict — so a partial
    /// payload (an update/archive echo naming only its own changed columns)
    /// throws a NOT NULL violation on every OTHER not-null column the
    /// candidate row doesn't mention, even though the row was always going
    /// to take the DO UPDATE branch and never actually insert those missing
    /// values. A plain UPDATE has no such pre-check — it only touches the
    /// columns named — so it's correct for the (overwhelmingly common) case
    /// where the row already exists; INSERT only runs when UPDATE touched
    /// nothing, which requires the caller to have supplied every column (a
    /// full pull-changes row, or a local `createX` write always does).
    private static func upsert(
        _ row: JSONObject, table: String, allowedColumns: Set<String>, _ database: Database
    ) throws {
        guard let primaryKey = primaryKeys[table] else { return }
        let columns = row.keys.filter { allowedColumns.contains($0) }.sorted()
        guard !columns.isEmpty, primaryKey.allSatisfy(columns.contains) else { return }

        if table == "card_mappings" {
            try reconcileCardMappingDuplicate(row, database)
        }

        let updateColumns = columns.filter { !primaryKey.contains($0) }
        if !updateColumns.isEmpty {
            let setClause = updateColumns.map { "\($0) = ?" }.joined(separator: ", ")
            let whereClause = primaryKey.map { "\($0) = ?" }.joined(separator: " AND ")
            let updateArguments = updateColumns.map { databaseValue(row[$0] ?? .null) }
                + primaryKey.map { databaseValue(row[$0] ?? .null) }
            try database.execute(
                sql: "UPDATE \(table) SET \(setClause) WHERE \(whereClause)",
                arguments: StatementArguments(updateArguments)
            )
            if database.changesCount > 0 { return }
        }

        let insertSQL = """
        INSERT INTO \(table) (\(columns.joined(separator: ", ")))
        VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
        ON CONFLICT(\(primaryKey.joined(separator: ", "))) DO NOTHING
        """
        let insertArguments = columns.map { databaseValue(row[$0] ?? .null) }
        try database.execute(sql: insertSQL, arguments: StatementArguments(insertArguments))
    }

    /// `card_mappings`' real identity is `(owner_id, card_identifier)`, not
    /// `id` — the server enforces that with its own `unique (owner_id,
    /// card_identifier)`, mirrored locally by a matching index
    /// (`LocalStore.swift`'s `v4_rebuild_syncable_tables` migration). This
    /// generic upsert otherwise only ever matches by primary key, and a
    /// locally-invented mapping (an offline `OutboxLocalWrite
    /// .linkCardLocally` insert, made before this card's own server row
    /// had ever been pulled down) can carry a different id than the
    /// server's row for the identical card — left to the PK-only upsert
    /// below, the incoming row would land as a second row instead of
    /// replacing the first (confirmed: this is exactly how a real device
    /// ended up with the same card mapped twice). Delete any local row
    /// sharing this natural key under a different id first, so the
    /// incoming row becomes the sole survivor either way.
    private static func reconcileCardMappingDuplicate(_ row: JSONObject, _ database: Database) throws {
        guard case .string(let ownerId) = row["owner_id"], case .string(let cardIdentifier) = row["card_identifier"],
            case .string(let id) = row["id"]
        else { return }
        try database.execute(
            sql: "DELETE FROM card_mappings WHERE owner_id = ? AND card_identifier = ? AND id != ?",
            arguments: [ownerId, cardIdentifier, id]
        )
    }

    private static func databaseValue(_ json: AnyJSON) -> DatabaseValueConvertible? {
        switch json {
        case .null: return nil
        case .bool(let value): return value
        case .integer(let value): return Int64(value)
        case .double(let value): return value
        case .string(let value): return value
        case .object, .array: return nil
        }
    }

    /// The epoch-mismatch response the plan calls for: drop every
    /// server-derived table, keep the outbox untouched, and let the caller
    /// re-pull from cursor 0 against the fresh epoch.
    static func wipeServerDerivedTables(_ database: Database) throws {
        for table in syncableTables {
            try database.execute(sql: "DELETE FROM \(table)")
        }
    }

    /// Sign-out's own wipe — everything `wipeServerDerivedTables` drops,
    /// plus `outbox_items` too. An epoch mismatch keeps the outbox on
    /// purpose (unsent local writes are not what changed), but sign-out is
    /// a genuine identity change: a write still queued under the outgoing
    /// identity must never drain into whichever identity signs in next on
    /// this device. Found chasing a real gap — `signOut()` used to clear
    /// only `SessionStore`'s in-memory properties, leaving the entire local
    /// mirror (every account, transaction, category — a full financial
    /// history) resident on disk for the next person to sign in and see.
    static func wipeAllLocalData(_ database: Database) throws {
        try wipeServerDerivedTables(database)
        try database.execute(sql: "DELETE FROM outbox_items")
    }
}
