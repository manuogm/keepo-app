import GRDB

// Split out of LocalStore.swift purely to keep that file under the
// project's file-length lint threshold — same precedent as
// Outbox+Capture.swift.

extension LocalStore {
    /// Found chasing a real bug: a device that already had Keepo installed
    /// before a `LocalSchemaV1` column change (card_identifier, the notes
    /// column, nullable account_id/currency, ...) never picked it up — `v1`
    /// already ran, and GRDB never re-runs a completed migration, so the
    /// on-disk table kept its old columns forever. Every write touching a
    /// new column then failed with "no such column" — silently, since
    /// `Outbox.applyLocally`/`SyncEngine.pull` both swallow errors into
    /// state nothing reads — which looked exactly like a sync bug (a
    /// captured transaction that never shows up) but was actually a stale
    /// local schema. These tables are a pure server mirror, never a source
    /// of truth, so the fix is the same one `SyncEngine`'s own
    /// epoch-mismatch path already uses: drop and recreate them from the
    /// current schema, reset every stored cursor, and let the next pull
    /// fully repopulate — never touches `outbox_items`, so an unsent local
    /// write survives. Exposed (not a closure literal in `makeQueue()`) so
    /// `LocalStoreMigrationTests` can drive it directly against a
    /// hand-built "old schema" database.
    static func rebuildSyncableTables(_ database: Database) throws {
        for table in SyncApply.syncableTables {
            try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try LocalSchemaV1.createSyncableTables(database)
        SyncCursorStore.resetAll()
    }
}
