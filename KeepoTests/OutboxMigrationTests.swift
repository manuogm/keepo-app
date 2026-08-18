import Foundation
import GRDB
import SwiftData
import Testing
@testable import Keepo

/// Exercises LH11 — the one-time move of queued writes from the pre-L3
/// SwiftData `OutboxItem` store into GRDB's `outbox_items` table — against
/// in-memory stores on both sides, no disk involved.
@Suite("Outbox SwiftData -> GRDB migration")
@MainActor
struct OutboxMigrationTests {
    private func makeSwiftDataContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: OfflineSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema, migrationPlan: OfflineMigrationPlan.self, configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeDbQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// A fresh suite per test, not `.standard` — `migrateIfNeeded` now
    /// short-circuits once it has ever seen the legacy store empty (X-03,
    /// to skip opening `OfflineStore`'s `ModelContainer` on every capture),
    /// and `.standard` persists across test runs on the same simulator.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "OutboxMigrationTests-\(UUID().uuidString)"))
    }

    @Test("upgrade with three queued items while offline moves all three, exactly once")
    func migratesThreeQueuedItemsExactlyOnce() throws {
        let swiftDataContext = try makeSwiftDataContext()
        let dbQueue = try makeDbQueue()

        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            swiftDataContext.insert(
                OutboxItem(
                    id: id, kind: "createTransaction", payloadJSON: Data("payload-\(index)".utf8),
                    expectedVersion: nil, attempts: 1, lastError: "offline"
                )
            )
        }
        try swiftDataContext.save()

        let defaults = try makeDefaults()
        OutboxMigration.migrateIfNeeded(swiftDataContext: swiftDataContext, to: dbQueue, defaults: defaults)

        let migratedIds = try dbQueue.read { database in
            try OutboxItemRecord.fetchAll(database).map(\.id)
        }
        #expect(Set(migratedIds) == Set(ids))

        let remainingLegacy = try swiftDataContext.fetch(FetchDescriptor<OutboxItem>())
        #expect(remainingLegacy.isEmpty)
        #expect(OutboxMigration.isDone(in: defaults))

        // Idempotent: nothing left in SwiftData, so a second cold start's
        // migration pass is a no-op — no duplicate rows, no error.
        OutboxMigration.migrateIfNeeded(swiftDataContext: swiftDataContext, to: dbQueue, defaults: defaults)
        let countAfterSecondRun = try dbQueue.read { database in try OutboxItemRecord.fetchCount(database) }
        #expect(countAfterSecondRun == 3)
    }

    @Test("an empty legacy store is a no-op")
    func emptyLegacyStoreIsNoop() throws {
        let swiftDataContext = try makeSwiftDataContext()
        let dbQueue = try makeDbQueue()
        let defaults = try makeDefaults()

        OutboxMigration.migrateIfNeeded(swiftDataContext: swiftDataContext, to: dbQueue, defaults: defaults)

        let count = try dbQueue.read { database in try OutboxItemRecord.fetchCount(database) }
        #expect(count == 0)
        #expect(OutboxMigration.isDone(in: defaults))
    }
}
