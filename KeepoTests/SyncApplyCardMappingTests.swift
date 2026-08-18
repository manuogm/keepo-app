import Foundation
import GRDB
import KeepoCore
import Supabase
import Testing
@testable import Keepo

/// Items 2/3 — regression coverage for the exact duplicate-row bug: a
/// locally-invented `card_mappings` id and the server's own id for the
/// identical `(owner_id, card_identifier)` used to both survive once a
/// pull applied the server's row, because `SyncApply`'s generic upsert
/// only ever matched by primary key. Split out of `SyncEngineTests.swift`
/// since this exercises `SyncApply.apply` directly, not the pull loop.
@Suite("SyncApply card_mappings natural-key reconciliation")
struct SyncApplyCardMappingTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    @Test("a pulled row replaces a locally-invented duplicate under the same natural key")
    func pullReconcilesDuplicateByNaturalKey() throws {
        let dbQueue = try makeDatabase()
        let now = "2026-01-01T00:00:00.000000+00:00"

        // Simulates `OutboxLocalWrite.linkCardLocally`'s insert branch,
        // made while offline before this card's server row ever synced
        // down — a client-invented id under the real natural key.
        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES ('local-1', 'owner-1', 'Revolut', 'acc-1', ?, ?, 0)
                """,
                arguments: [now, now]
            )
        }

        // The server's own row for the identical card, arriving via a
        // pull — a different id, since map_card/capture_transaction never
        // accept a client-chosen one.
        let payload: AnyJSON = .object([
            "card_mappings": .array([
                .object([
                    "id": .string("server-1"), "owner_id": .string("owner-1"), "card_identifier": .string("Revolut"),
                    "account_id": .string("acc-1"), "created_at": .string(now), "updated_at": .string(now),
                    "deleted_at": .null, "sync_seq": .integer(1)
                ])
            ])
        ])

        try dbQueue.write { database in try SyncApply.apply(payload, in: database) }

        let rows = try dbQueue.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id FROM card_mappings WHERE owner_id = 'owner-1' AND card_identifier = 'Revolut'"
            )
        }
        #expect(rows.map { $0["id"] as String } == ["server-1"])
    }

    @Test("a pulled row for a different card never touches an unrelated local mapping")
    func pullLeavesUnrelatedMappingsAlone() throws {
        let dbQueue = try makeDatabase()
        let now = "2026-01-01T00:00:00.000000+00:00"

        try dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES ('amex-1', 'owner-1', 'Amex', 'acc-2', ?, ?, 0)
                """,
                arguments: [now, now]
            )
        }

        let payload: AnyJSON = .object([
            "card_mappings": .array([
                .object([
                    "id": .string("server-1"), "owner_id": .string("owner-1"), "card_identifier": .string("Revolut"),
                    "account_id": .string("acc-1"), "created_at": .string(now), "updated_at": .string(now),
                    "deleted_at": .null, "sync_seq": .integer(1)
                ])
            ])
        ])

        try dbQueue.write { database in try SyncApply.apply(payload, in: database) }

        let ids = try dbQueue.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM card_mappings ORDER BY id")
        }
        #expect(ids == ["amex-1", "server-1"])
    }
}
