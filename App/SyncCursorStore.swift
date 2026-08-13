import Foundation

/// The pull loop's own bookkeeping (Phase L5, `keepo-local-first-plan.md`)
/// — never synced, never read by any money query, exactly the same
/// "pure local state" category `Outbox`'s `created_at` column already
/// occupies. `UserDefaults`, not a GRDB table: a cursor is meaningless
/// without also knowing which user it belongs to (each user's `sync_seq`
/// numbering is that user's own domain), so every key is namespaced by
/// user id — a sign-out/sign-in as a different identity on the same device
/// must never resume from a stranger's cursor.
enum SyncCursorStore {
    static func cursor(for userId: String) -> Int64 {
        Int64(UserDefaults.standard.integer(forKey: key(.cursor, userId)))
    }

    static func globalCursor(for userId: String) -> Int64 {
        Int64(UserDefaults.standard.integer(forKey: key(.globalCursor, userId)))
    }

    /// `nil` before this device has ever completed a pull for this user —
    /// distinct from `0`, which is a real epoch value `profiles.sync_epoch`
    /// starts at. Only a genuine "we've seen an epoch before, and it just
    /// changed" comparison should trigger the drop-and-re-pull path; a
    /// first-ever pull is not a mismatch.
    static func epoch(for userId: String) -> Int64? {
        guard UserDefaults.standard.object(forKey: key(.epoch, userId)) != nil else { return nil }
        return Int64(UserDefaults.standard.integer(forKey: key(.epoch, userId)))
    }

    static func save(cursor: Int64, globalCursor: Int64, epoch: Int64, for userId: String) {
        let defaults = UserDefaults.standard
        defaults.set(Int(cursor), forKey: key(.cursor, userId))
        defaults.set(Int(globalCursor), forKey: key(.globalCursor, userId))
        defaults.set(Int(epoch), forKey: key(.epoch, userId))
        defaults.set(Date(), forKey: key(.lastSyncedAt, userId))
    }

    /// The `OfflineStatusBar`'s "Last synced …" — persisted (unlike
    /// `SyncEngine.isSyncing`/`lastErrorMessage`, which are session-only)
    /// so a relaunch right after a successful pull still shows a real
    /// timestamp instead of nothing until the next pull completes.
    static func lastSyncedAt(for userId: String) -> Date? {
        UserDefaults.standard.object(forKey: key(.lastSyncedAt, userId)) as? Date
    }

    /// Called on an epoch mismatch, before the forced re-pull from 0 — the
    /// stored cursor/global cursor must not linger at their old (now
    /// meaningless) values while the re-pull is in flight.
    static func reset(for userId: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key(.cursor, userId))
        defaults.removeObject(forKey: key(.globalCursor, userId))
    }

    private enum Field: String {
        case cursor, globalCursor, epoch, lastSyncedAt
    }

    private static func key(_ field: Field, _ userId: String) -> String {
        "app.keepo.sync.\(field.rawValue).\(userId)"
    }
}
