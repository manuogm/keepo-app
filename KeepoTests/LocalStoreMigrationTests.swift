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
