import Foundation
import GRDB
import Testing
@testable import Keepo

/// Repro + regression test for a real bug: a device that already had Keepo
/// installed before a `LocalSchemaV1` column change (card_identifier, the
/// nullable account_id/currency, ...) never picked it up, because GRDB
/// never re-runs a completed "v1" migration — every write touching a new
/// column then failed with "no such column", silently swallowed by
/// `Outbox.applyLocally`/`SyncEngine.pull`. `rebuildSyncableTables` is the
/// fix; this test builds the exact "old schema" shape by hand (pre-dating
/// this session's columns) and confirms it upgrades cleanly.
@Suite("LocalStore schema-drift migration")
struct LocalStoreMigrationTests {
    @Test("a pre-existing old-shape transactions table gains the new columns after rebuildSyncableTables")
    func rebuildAddsNewColumns() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { database in
            // The exact shape `transactions` had before card_identifier/
            // notes existed and before account_id/currency went nullable.
            try database.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, created_by TEXT NOT NULL,
                    account_id TEXT NOT NULL, category_id TEXT, amount_e4 INTEGER NOT NULL,
                    currency TEXT NOT NULL, occurred_at TEXT NOT NULL, source TEXT NOT NULL,
                    status TEXT NOT NULL, version INTEGER NOT NULL, created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL, sync_seq INTEGER NOT NULL
                )
                """)
        }

        try dbQueue.write { database in try LocalStore.rebuildSyncableTables(database) }

        let columns = try dbQueue.read { database in
            try database.columns(in: "transactions").map(\.name)
        }
        #expect(columns.contains("card_identifier"))
        #expect(columns.contains("notes"))

        // account_id must now accept NULL — the whole point of the rebuild.
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, account_id, amount_e4, occurred_at, source, status,
                    version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["t1", "owner1", "owner1", -4500, "2026-01-01T00:00:00Z", "capture", "pending", 1,
                            "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", 0]
            )
        }
    }

    /// C-07's local counterpart to the server's transactions_external_id_idx
    /// — without this, a re-fired automation minting the same deterministic
    /// id from `CaptureIdentity.transactionId(forExternalId:)` twice would
    /// still be caught by the primary key, but a bug that ever regressed the
    /// id derivation back to a random UUID would silently write two rows
    /// for the same purchase. This index is the same idempotency guarantee
    /// the server enforces, applied to the mirror too.
    @Test("rebuildSyncableTables adds the partial unique index on (owner_id, source, external_id)")
    func rebuildAddsExternalIdUniqueIndex() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { database in try LocalStore.rebuildSyncableTables(database) }

        let now = "2026-01-01T00:00:00.000000+00:00"
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, category_id, amount_e4, occurred_at, source, status,
                    external_id, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, ?, ?, 'capture', 'pending', 'ext-1', 1, ?, ?, 0)
                """,
                arguments: ["t1", "owner1", "owner1", "cat1", -4500, now, now, now]
            )
        }

        #expect(throws: (any Error).self) {
            try dbQueue.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO transactions (
                        id, owner_id, created_by, category_id, amount_e4, occurred_at, source, status,
                        external_id, version, created_at, updated_at, sync_seq
                    ) VALUES (?, ?, ?, ?, ?, ?, 'capture', 'pending', 'ext-1', 1, ?, ?, 0)
                    """,
                    arguments: ["t2", "owner1", "owner1", "cat1", -4500, now, now, now]
                )
            }
        }
    }

    @Test("resetAll clears every stored sync cursor/epoch, regardless of user")
    func resetAllClearsEveryUser() {
        SyncCursorStore.save(cursor: 42, globalCursor: 7, epoch: 1, for: "user-a")
        SyncCursorStore.save(cursor: 99, globalCursor: 3, epoch: 2, for: "user-b")

        SyncCursorStore.resetAll()

        #expect(SyncCursorStore.cursor(for: "user-a") == 0)
        #expect(SyncCursorStore.cursor(for: "user-b") == 0)
        #expect(SyncCursorStore.epoch(for: "user-a") == nil)
        #expect(SyncCursorStore.epoch(for: "user-b") == nil)
    }
}
