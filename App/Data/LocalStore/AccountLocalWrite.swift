import Foundation
import GRDB
import KeepoCore

/// The local echo for `AccountRepository.delete`, called once the
/// online-only RPC has already succeeded — same reasoning as
/// `CategoryLocalWrite.deleteAndReassignToOther`'s own header comment:
/// delete needs a live "does this account still have transactions" check,
/// so it never goes through the offline outbox, but a successful call still
/// needs to be echoed into the local mirror immediately.
enum AccountLocalWrite {
    static func delete(accountId: UUID, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE accounts SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, accountId.uuidString]
        )
    }
}
