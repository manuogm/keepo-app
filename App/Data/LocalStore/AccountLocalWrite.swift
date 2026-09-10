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
    /// `cascade` mirrors what `delete_account(p_cascade => true)` just did
    /// on the server: the account's transactions are tombstoned here too.
    /// Without it the ledger keeps drawing rows against an account that no
    /// longer exists until the next pull lands, which is the window the
    /// user is looking at.
    static func delete(accountId: UUID, cascade: Bool, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        if cascade {
            try database.execute(
                sql: """
                UPDATE transactions SET deleted_at = ?, updated_at = ?
                WHERE account_id = ? AND deleted_at IS NULL
                """,
                arguments: [now, now, accountId.uuidString]
            )
        }
        try database.execute(
            sql: "UPDATE accounts SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, accountId.uuidString]
        )
    }
}
