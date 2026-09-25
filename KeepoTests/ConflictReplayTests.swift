import Foundation
import GRDB
import KeepoCore
import Supabase
import Testing
@testable import Keepo

/// "Keep mine" replays the write the server kept on the conflict row
/// (migration 20261008100000). These pin the two halves the client owns: the
/// payload survives the trip into the local mirror as JSON, and a replay
/// queues the same kind of write against the versions the rows have now —
/// including a transfer, which the old rebuild-from-the-mirror path could not
/// express at all.
@Suite("Conflict replay")
@MainActor
struct ConflictReplayTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    /// `pull_changes` delivers `attempted_payload` as a nested JSON object.
    /// `SyncApply` used to turn every nested value into NULL, which would
    /// have left each conflict with nothing to replay.
    @Test("a pulled conflict keeps its attempted write, and it decodes")
    func pulledPayloadSurvivesTheMirror() async throws {
        let (_, dbQueue) = try makeOutboxAndDatabase()
        let conflictId = UUID()
        let groupId = UUID()
        let row: JSONObject = [
            "id": .string(conflictId.uuidString), "table_name": .string("transactions"),
            "row_id": .string(groupId.uuidString), "owner_id": .string(UUID().uuidString),
            "client_version": .integer(1), "server_version": .integer(2),
            "attempted_payload": .object([
                "rpc": .string("update_transfer"), "transfer_group_id": .string(groupId.uuidString),
                "from_amount_e4": .integer(120_000), "to_amount_e4": .integer(120_000),
                "occurred_at": .string("2026-10-06T12:00:00.000000+00:00"), "title": .string("Rent")
            ]),
            "created_at": .string("2026-10-06T12:00:00.000000+00:00"), "sync_seq": .integer(1)
        ]
        try await dbQueue.write { database in try SyncApply.upsertRow(row, table: "sync_conflicts", in: database) }

        let detail = try await dbQueue.read { database in
            try ConflictLocalQueries.detail(database, id: conflictId.uuidString)
        }
        let attempted = try #require(detail?.attemptedWrite)
        #expect(attempted.rpc == "update_transfer")
        #expect(attempted.transferGroupId == groupId)
        #expect(attempted.fromAmountE4 == 120_000)
        #expect(attempted.attemptedAmountE4 == -120_000, "the sending leg is the conflicted row, and it is negative")
        #expect(attempted.title == "Rent")
    }

    @Test("a transfer edit replays as a transfer edit, against both legs' current versions")
    func transferReplayQueuesAnUpdateTransfer() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let groupId = UUID()
        let attempted = try #require(AttemptedTransactionWrite.decode("""
            {"rpc": "update_transfer", "transfer_group_id": "\(groupId.uuidString.lowercased())",
             "from_amount_e4": 120000, "to_amount_e4": 130000,
             "occurred_at": "2026-10-06T12:00:00.000000+00:00", "notes": "rent share"}
            """))

        let replayed = await attempted.replay(
            rowId: groupId, rowVersion: 4, legVersions: (from: 4, to: 7), outbox: outbox
        )

        #expect(replayed)
        let queued = try await dbQueue.read { database in try OutboxItemRecord.fetchAll(database) }
        let item = try #require(queued.first)
        #expect(item.kind == OutboxKind.updateTransfer.rawValue)
        let payload = try JSONDecoder().decode(UpdateTransferPayload.self, from: item.payloadJSON)
        #expect(payload.fromExpectedVersion == 4)
        #expect(payload.toExpectedVersion == 7)
        #expect(payload.toAmountE4 == 130_000)
        #expect(payload.notes == "rent share")
    }

    /// A transfer whose other half is gone cannot be edited back into
    /// existence; saying so is better than queuing a write that fails forever.
    @Test("a transfer replay without both legs is refused, and queues nothing")
    func transferReplayNeedsBothLegs() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let attempted = try #require(AttemptedTransactionWrite.decode("""
            {"rpc": "delete_transfer", "transfer_group_id": "\(UUID().uuidString)"}
            """))

        let replayed = await attempted.replay(rowId: UUID(), rowVersion: nil, legVersions: nil, outbox: outbox)

        #expect(!replayed)
        let count = try await dbQueue.read { database in try OutboxItemRecord.fetchCount(database) }
        #expect(count == 0)
    }
}
