import Foundation
import GRDB
import Testing
@testable import Keepo

/// Confirms the GRDB migrator (`LocalSchemaV1`) runs cleanly and that
/// `LocalStore.makeQueue()`'s file-protection call completes without
/// throwing — the same Simulator caveat as `OfflineStoreTests` applies (no
/// data-protection subsystem to read the attribute back from; see that
/// file's header comment).
@Suite("Local store schema")
struct LocalStoreTests {
    @Test("the v1 migration creates every syncable table plus outbox_items")
    func migrationCreatesAllTables() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)

        let expectedTables = [
            "accounts", "transactions", "balance_snapshots", "categories", "currencies", "fx_rates",
            "budgets", "recurring_rules", "card_mappings", "merchant_category_map",
            "sync_conflicts", "households", "household_members", "household_accounts", "profiles",
            "outbox_items"
        ]
        let existing = try dbQueue.read { database in
            try expectedTables.filter { try database.tableExists($0) }
        }
        #expect(Set(existing) == Set(expectedTables))
    }

    /// Postgres always renders `uuid` columns lowercase (`to_jsonb`), but
    /// Swift's `UUID.uuidString` is uppercase — every screen binds a
    /// `session.profile?.id.uuidString` (uppercase) against `owner_id`
    /// values that arrived from a sync pull (lowercase). SQLite's default
    /// `TEXT` equality is byte-for-byte case-sensitive, so without
    /// `.collate(.nocase)` on every id-shaped column, that comparison
    /// silently matches nothing — confirmed against a real device: accounts
    /// and transactions synced correctly (net worth, which doesn't do this
    /// comparison, computed the right total) yet both list screens stayed
    /// empty forever.
    @Test("owner_id comparisons match regardless of UUID case")
    func idColumnsAreCaseInsensitive() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)

        let lowercaseOwnerId = UUID().uuidString.lowercased()
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'ledger', 'checking', 'Checking', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [UUID().uuidString.lowercased(), lowercaseOwnerId, lowercaseOwnerId]
            )
        }

        let uppercaseOwnerId = lowercaseOwnerId.uppercased()
        let count = try dbQueue.read { database in
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM accounts WHERE owner_id = ?", arguments: [uppercaseOwnerId]
            )
        }
        #expect(count == 1)
    }

    @Test("makeQueue's file-protection call completes without throwing")
    func fileProtectionCallSucceeds() throws {
        _ = try LocalStore.makeQueue()

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let storeURL = directory.appendingPathComponent("Local.sqlite")

        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path
                )
            }
        }
    }

    /// `SessionStore.signOut()`'s own wipe (S-01, the security-review
    /// finding this fixes) — unlike `wipeServerDerivedTables` (an epoch
    /// mismatch, where unsent local writes must survive), sign-out is a
    /// genuine identity change: nothing from the outgoing identity,
    /// including a still-queued write, may remain for whoever signs in
    /// next on this device.
    @Test("wipeAllLocalData clears every syncable table AND outbox_items, unlike wipeServerDerivedTables")
    func wipeAllLocalDataClearsEverythingIncludingOutbox() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)

        let ownerId = UUID().uuidString
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Groceries', 0, 'cart', '#FF0000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [UUID().uuidString, ownerId]
            )
            try OutboxItemRecord(
                id: UUID(), kind: "createTransaction", payloadJSON: Data("{}".utf8), createdAt: Date(), attempts: 0
            ).insert(database)
        }

        try dbQueue.write { database in try SyncApply.wipeAllLocalData(database) }

        let counts = try dbQueue.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM categories") ?? -1,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM outbox_items") ?? -1
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }
}
