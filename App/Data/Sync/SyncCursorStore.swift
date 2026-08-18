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

    /// Called once by `LocalStore`'s schema-drift migration, before any
    /// `userId` is known (it runs at `DatabaseQueue` open time) — every
    /// stored cursor/epoch, for whichever users have ever synced on this
    /// device, must drop together so the next pull for each of them is
    /// forced back to a full re-fetch against the just-rebuilt (empty)
    /// local tables. `lastSyncedAt` is left alone; it's purely informational
    /// and the next successful pull overwrites it anyway.
    static func resetAll() {
        let defaults = UserDefaults.standard
        let prefixes = [Field.cursor, .globalCursor, .epoch].map { "app.keepo.sync.\($0.rawValue)." }
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Field: String {
        case cursor, globalCursor, epoch, lastSyncedAt
    }

    private static func key(_ field: Field, _ userId: String) -> String {
        "app.keepo.sync.\(field.rawValue).\(userId)"
    }

    // MARK: - local data ownership

    /// The identity `SessionStore` last confirmed the local GRDB mirror
    /// belongs to — separate from any per-user cursor above, since this is
    /// checked *before* trusting anything already on disk, not after a
    /// pull. A single key, not namespaced (unlike every field above): there
    /// is only ever one local store on this device, owned by at most one
    /// identity at a time.
    private static let localOwnerKey = "app.keepo.sync.localOwnerUserId"

    static var localOwnerUserId: String? {
        UserDefaults.standard.string(forKey: localOwnerKey)
    }

    static func setLocalOwner(_ userId: String) {
        UserDefaults.standard.set(userId, forKey: localOwnerKey)
    }

    /// Called by `signOut()` alongside its own wipe — belt and suspenders
    /// with `SessionStore.ensureLocalDataBelongsTo`, which independently
    /// catches the case this miss (a crash or force-quit between the wipe
    /// and the next sign-in) would otherwise let through.
    static func clearLocalOwner() {
        UserDefaults.standard.removeObject(forKey: localOwnerKey)
    }
}
