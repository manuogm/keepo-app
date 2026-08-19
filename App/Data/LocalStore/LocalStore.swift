import Foundation
import GRDB

/// The on-device SQLite store (Phase L3, `keepo-local-first-plan.md`). Two
/// tenants today: the syncable-table mirror (schema only — nothing writes
/// into it until L5's pull loop lands) and `outbox_items`, which fully
/// replaces the SwiftData-backed queue `Outbox` used through Phase 11–L2.
///
/// Column names and types mirror the server 1:1 — `snake_case`, `sync_seq`/
/// `deleted_at`/`version` present wherever the server has them, money as
/// `INTEGER` (the same `_e4` bigint columns L1 converted the server to,
/// never `REAL` — money rule 3 in spirit even though this file has no
/// arithmetic of its own yet). Dates/timestamps stay `TEXT` — the exact
/// ISO 8601 string Postgres/PostgREST already produced, decoded with
/// `KeepoCore`'s `DateFormatting` at the read boundary, never reparsed here.
/// `fx_rates.rate_to_eur` stays `TEXT` too: a decimal string, not a REAL —
/// this store does no FX arithmetic (that's the referee in L4), so nothing
/// here needs it as anything but an opaque value to carry until the day it
/// does.
public enum LocalSchemaV1 {
    /// Every table a fresh pull can eventually populate (L5), defined now so
    /// the schema and the sync design are locked together — plus
    /// `outbox_items`, whose data this migration also inherits from the
    /// pre-L3 SwiftData store (see `OutboxMigration`). Split into per-domain
    /// helpers purely to stay under the project's function-length lint —
    /// there's no ordering dependency between them.
    static func migrate(_ database: Database) throws {
        try createSyncableTables(database)
        try createOutboxTable(database)
    }

    /// Every table a sync pull can populate — everything `migrate` creates
    /// except `outbox_items`, which holds unsent local writes and must
    /// never be touched by a schema rebuild. Split out so
    /// `LocalStore.makeQueue()`'s schema-drift migration can drop and
    /// recreate exactly this set.
    static func createSyncableTables(_ database: Database) throws {
        try createAccountAndTransactionTables(database)
        try createCategoryTables(database)
        try createPlanningTables(database)
        try createReferenceTables(database)
        try createHouseholdTables(database)
    }

    private static func createAccountAndTransactionTables(_ database: Database) throws {
        try database.create(table: "accounts") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("created_by", .text).notNull().collate(.nocase)
            table.column("kind", .text).notNull()
            table.column("name", .text).notNull()
            table.column("currency", .text).notNull()
            table.column("opening_balance_e4", .integer).notNull()
            table.column("opening_balance_at", .text).notNull()
            table.column("include_in_total", .boolean).notNull()
            table.column("icon", .text).notNull()
            table.column("color", .text).notNull()
            table.column("archived_at", .text)
            table.column("version", .integer).notNull()
            table.column("deleted_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }

        try database.create(table: "transactions") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("created_by", .text).notNull().collate(.nocase)
            // Nullable — only ever null for a pending capture whose card
            // isn't resolved to an account yet (server enforces this with
            // a CHECK: a confirmed row can never have either null).
            table.column("account_id", .text).collate(.nocase)
            table.column("category_id", .text).collate(.nocase)
            table.column("category_kind", .text)
            table.column("amount_e4", .integer).notNull()
            table.column("currency", .text)
            table.column("occurred_at", .text).notNull()
            table.column("merchant_raw", .text)
            table.column("merchant_normalized", .text)
            table.column("notes", .text)
            // Only ever set for source='capture' rows — remembers which
            // card produced this row so resolving its account later (via
            // OutboxLocalWrite.updateTransaction) can auto-link the card.
            table.column("card_identifier", .text)
            table.column("transfer_group_id", .text).collate(.nocase)
            table.column("source", .text).notNull()
            table.column("status", .text).notNull()
            table.column("external_id", .text)
            table.column("recurring_rule_id", .text).collate(.nocase)
            table.column("version", .integer).notNull()
            table.column("deleted_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }
        try createTransactionIndexes(database)
    }

    private static func createTransactionIndexes(_ database: Database) throws {
        try database.create(index: "idx_transactions_account_id", on: "transactions", columns: ["account_id"])
        try database.create(index: "idx_transactions_owner_id", on: "transactions", columns: ["owner_id"])
        // Mirrors the server's own transactions_external_id_idx (C-07) —
        // without it, a re-fired automation that mints its id from
        // CaptureIdentity.transactionId(forExternalId:) the same way twice
        // writes two local rows before the server's 23505 ever comes back,
        // leaving an orphaned duplicate no local write can clean up.
        try database.create(
            index: "idx_transactions_external_id", on: "transactions", columns: ["owner_id", "source", "external_id"],
            options: .unique, condition: Column("external_id") != nil
        )
    }

    private static func createCategoryTables(_ database: Database) throws {
        try database.create(table: "categories") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("kind", .text).notNull()
            table.column("name", .text).notNull()
            table.column("is_default", .boolean).notNull()
            table.column("icon", .text).notNull()
            table.column("color", .text).notNull()
            table.column("version", .integer).notNull()
            table.column("deleted_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }
    }

    private static func createPlanningTables(_ database: Database) throws {
        try database.create(table: "recurring_rules") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("created_by", .text).notNull().collate(.nocase)
            table.column("account_id", .text).notNull().collate(.nocase)
            table.column("category_id", .text).notNull().collate(.nocase)
            table.column("amount_e4", .integer).notNull()
            table.column("currency", .text).notNull()
            table.column("frequency", .text).notNull()
            table.column("next_due_at", .text).notNull()
            table.column("last_materialized_at", .text)
            table.column("active", .boolean).notNull()
            table.column("version", .integer).notNull()
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }

        try database.create(table: "budgets") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("category_id", .text).collate(.nocase)
            table.column("period_month", .text).notNull()
            table.column("amount_e4", .integer).notNull()
            table.column("currency", .text).notNull()
            table.column("version", .integer).notNull()
            table.column("deleted_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }
    }

    private static func createReferenceTables(_ database: Database) throws {
        try database.create(table: "currencies") { table in
            table.column("code", .text).primaryKey()
            table.column("minor_unit", .integer).notNull()
            table.column("sync_seq", .integer).notNull()
        }

        try database.create(table: "fx_rates") { table in
            table.column("currency", .text).notNull()
            table.column("rate_date", .text).notNull()
            table.column("rate_to_eur", .text).notNull()
            table.column("source", .text).notNull()
            table.column("fetched_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
            table.primaryKey(["currency", "rate_date"])
        }

        try database.create(table: "card_mappings") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("card_identifier", .text).notNull()
            table.column("account_id", .text).collate(.nocase)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
        }
        // Mirrors the server's own unique(owner_id, card_identifier) —
        // not partial there either. Items 2/3 fix: without it, a
        // locally-invented mapping id and the server's own row for the
        // identical card could both exist; `SyncApply
        // .reconcileCardMappingDuplicate` is the other half — it deletes
        // the stale duplicate by natural key before a pull lands.
        try database.create(
            index: "idx_card_mappings_owner_card", on: "card_mappings", columns: ["owner_id", "card_identifier"],
            options: .unique
        )

        try database.create(table: "merchant_category_map") { table in
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("merchant_pattern", .text).notNull()
            table.column("category_id", .text).notNull().collate(.nocase)
            table.column("updated_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
            table.primaryKey(["owner_id", "merchant_pattern"])
        }

        try database.create(table: "sync_conflicts") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("table_name", .text).notNull()
            table.column("row_id", .text).notNull().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("client_version", .integer).notNull()
            table.column("server_version", .integer).notNull()
            table.column("created_at", .text).notNull()
            table.column("resolved_at", .text)
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
        }
    }

    private static func createHouseholdTables(_ database: Database) throws {
        try database.create(table: "households") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("created_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
        }

        try database.create(table: "household_members") { table in
            table.column("household_id", .text).notNull().collate(.nocase)
            table.column("user_id", .text).notNull().collate(.nocase)
            table.column("joined_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
            table.primaryKey(["household_id", "user_id"])
        }

        try database.create(table: "household_accounts") { table in
            table.column("household_id", .text).notNull().collate(.nocase)
            table.column("account_id", .text).notNull().collate(.nocase)
            table.column("shared_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
            table.primaryKey(["household_id", "account_id"])
        }

        try database.create(table: "profiles") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("base_currency", .text)
            table.column("onboarded_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_epoch", .integer).notNull()
            table.column("sync_seq", .integer).notNull()
        }
    }

    /// The GRDB-native replacement for SwiftData's `OutboxItem` — same
    /// shape, same semantics (FIFO by `created_at`, one row per queued
    /// write keyed by the write's own client-generated id). See
    /// `Outbox.swift` and `OutboxMigration.swift`.
    private static func createOutboxTable(_ database: Database) throws {
        try database.create(table: "outbox_items") { table in
            table.column("id", .text).primaryKey()
            table.column("kind", .text).notNull()
            table.column("payload_json", .blob).notNull()
            table.column("expected_version", .integer)
            // `.double`, not `.text` — this column carries a `timeIntervalSince1970`
            // (see `OutboxItemRecord`'s own comment), and TEXT column affinity
            // would round-trip that Double through a 15-significant-digit
            // text cast, occasionally rounding it forward past a `Date()`
            // read a moment later (confirmed empirically — flaked
            // `hasStalePending(threshold: 0)` roughly 1 run in 5). `.double`
            // stores the exact IEEE 754 bits, no cast involved.
            table.column("created_at", .double).notNull()
            table.column("attempts", .integer).notNull()
            table.column("last_error", .text)
        }
    }
}

/// The GRDB row backing `outbox_items` — the storage `Outbox` (App/Outbox.swift)
/// reads and writes. `id` is the queued write's own client-generated UUID
/// (see `Outbox`'s own doc comment on why), stored as `TEXT`, matching every
/// other id column across this store.
struct OutboxItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox_items"
    // `created_at` here is purely local bookkeeping (FIFO ordering,
    // staleness checks) — never compared against a server-issued timestamp —
    // so unlike every synced table's `TEXT` date columns, this one is
    // encoded as a `timeIntervalSince1970` numeric string: full sub-second
    // precision, no ISO 8601 whole-second truncation that could round a
    // just-inserted row's timestamp into the future relative to `Date()`
    // read a moment later (confirmed empirically — `.iso8601`'s truncation
    // made `hasStalePending(threshold: 0)` flaky immediately after `enqueue`).
    static let databaseDateEncodingStrategy: DatabaseDateEncodingStrategy = .timeIntervalSince1970
    static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970

    var id: UUID
    var kind: String
    var payloadJSON: Data
    var expectedVersion: Int?
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case payloadJSON = "payload_json"
        case expectedVersion = "expected_version"
        case createdAt = "created_at"
        case attempts
        case lastError = "last_error"
    }
}

public enum LocalStore {
    /// Same one-process, one-container reasoning as `OfflineStore` — the
    /// App target (not an extension) is exactly why `CaptureIntent` can
    /// reach this directly, and two independent `DatabaseQueue`s opening the
    /// same SQLite file in one process is a hazard GRDB doesn't paper over
    /// either.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: DatabaseQueue?

    public static func makeQueue() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let storeURL = try storeDirectory().appendingPathComponent("Local.sqlite")
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        // Recovers a device whose local schema predates a `LocalSchemaV1`
        // column change — see `rebuildSyncableTables`'s own header comment
        // (`LocalStore+SchemaMigration.swift`) for why this is needed.
        migrator.registerMigration("v2_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild, re-run under a new name so a device that already
        // completed v2 still picks up C-07's new partial unique index on
        // transactions(owner_id, source, external_id) — GRDB never re-runs
        // a migration name that already succeeded.
        migrator.registerMigration("v3_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — items 2/3's new unique index on
        // card_mappings(owner_id, card_identifier); also purges any
        // duplicate row already on disk, since the fresh re-pull runs
        // through `SyncApply`'s new natural-key reconciliation.
        migrator.registerMigration("v4_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — the unify-account-kinds migration dropped
        // accounts.subtype, transactions.account_kind, and balance_snapshots
        // entirely server-side; a device that already completed v4 needs
        // this rebuild to drop them locally too, or every pull row omitting
        // those columns hits an INSERT NOT NULL violation.
        migrator.registerMigration("v5_rebuild_syncable_tables", migrate: rebuildSyncableTables)

        let queue = try DatabaseQueue(path: storeURL.path)
        try migrator.migrate(queue)
        protectStoreFiles(at: storeURL)
        cached = queue
        return queue
    }

    private static func storeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
    }

    /// Same rationale and same confirmed Simulator limitation as
    /// `OfflineStore.protectStoreFiles` — see that file's header comment.
    private static func protectStoreFiles(at storeURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path
            )
        }
    }
}
