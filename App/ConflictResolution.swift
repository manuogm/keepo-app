import Foundation
import GRDB
import KeepoCore

/// E: the detail `ConflictDetailSheet` needs beyond what `needs_review`'s
/// stable column contract carries for a `sync_conflict` row — `item.itemId`
/// there is the `sync_conflicts` audit row's own id (what `resolve_sync_conflict`
/// takes), not the transaction/account id that actually conflicted. A second,
/// narrow local read by that same id, straight off the table `LocalMoneyQueries`'
/// own `needsReview` query already reads.
struct SyncConflictDetail {
    let id: UUID
    let tableName: String
    let rowId: String
    let clientVersion: Int
    let serverVersion: Int
}

enum ConflictLocalQueries {
    static func detail(_ database: Database, id: String) throws -> SyncConflictDetail? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, table_name, row_id, client_version, server_version
            FROM sync_conflicts WHERE id = ?
            """,
            arguments: [id]
        ) else { return nil }
        guard let idString: String = row["id"], let uuid = UUID(uuidString: idString) else { return nil }
        return SyncConflictDetail(
            id: uuid, tableName: row["table_name"], rowId: row["row_id"],
            clientVersion: row["client_version"], serverVersion: row["server_version"]
        )
    }
}
