import Foundation
import GRDB
import SwiftData

/// One-time storage migration (LH11, Phase L3): moves every row already
/// queued in the pre-L3 SwiftData `OutboxItem` store into GRDB's
/// `outbox_items` table, so upgrading mid-flight — with writes still queued
/// from being offline — doesn't lose them and doesn't require the device to
/// be online to upgrade. `OutboxItem`'s SwiftData model type is kept in
/// `OfflineStore`'s schema solely so this migration can still open and read
/// the old store; nothing else in the app writes to it anymore.
///
/// Idempotent by construction: migrated rows are deleted from the SwiftData
/// side as part of the same pass, so a second run (a second cold start, a
/// crash mid-migration) finds nothing left to move and is a no-op. A row
/// that already exists in GRDB under the same id (shouldn't happen — ids
/// are the write's own client-generated UUID, never reused — but the outbox
/// already treats a same-id `enqueue` as an update elsewhere) is left as-is
/// rather than duplicated.
enum OutboxMigration {
    /// X-10/X-03: `isDone` lets a caller skip opening `OfflineStore`'s
    /// `ModelContainer` at all once the legacy store is confirmed empty —
    /// the container itself, not this fetch, is the expensive part, and
    /// `CaptureIntent` was paying it on every single capture (every Apple
    /// Pay tap) since it has no persisted state of its own to short-circuit
    /// on. Only ever set once this method observes zero legacy rows left.
    /// `defaults` is injectable (default `.standard`) so tests can pass an
    /// isolated suite instead of polluting the shared one across runs.
    private static let doneKey = "app.keepo.outboxMigration.done"

    static func isDone(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    @MainActor
    static func migrateIfNeeded(
        swiftDataContext: ModelContext, to dbQueue: DatabaseQueue, defaults: UserDefaults = .standard
    ) {
        guard !isDone(in: defaults) else { return }
        let descriptor = FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt)])
        guard let legacyItems = try? swiftDataContext.fetch(descriptor) else { return }
        guard !legacyItems.isEmpty else {
            defaults.set(true, forKey: doneKey)
            return
        }

        for legacy in legacyItems {
            do {
                try dbQueue.write { database in
                    if try OutboxItemRecord.fetchOne(database, key: legacy.id) != nil { return }
                    try OutboxItemRecord(
                        id: legacy.id, kind: legacy.kind, payloadJSON: legacy.payloadJSON,
                        expectedVersion: legacy.expectedVersion, createdAt: legacy.createdAt,
                        attempts: legacy.attempts, lastError: legacy.lastError
                    ).insert(database)
                }
                swiftDataContext.delete(legacy)
            } catch {
                continue
            }
        }
        try? swiftDataContext.save()

        // A row that hit the `continue` above is still legacy-side and must
        // be retried next launch — only mark done once genuinely empty.
        if let remaining = try? swiftDataContext.fetch(descriptor), remaining.isEmpty {
            defaults.set(true, forKey: doneKey)
        }
    }
}
