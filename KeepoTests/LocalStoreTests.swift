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
            "budgets", "fi_settings", "recurring_rules", "card_mappings", "merchant_category_map",
            "sync_conflicts", "households", "household_members", "household_accounts", "profiles",
            "outbox_items"
        ]
        let existing = try dbQueue.read { database in
            try expectedTables.filter { try database.tableExists($0) }
        }
        #expect(Set(existing) == Set(expectedTables))
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
}
