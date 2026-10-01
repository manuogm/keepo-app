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
    ///
    /// Transfer halves follow the server's rule (migration 20261007100000):
    /// one whose partner is on a live account stays, as the anchor that
    /// keeps the transfer whole; one whose partner's account is also deleted
    /// goes, together with that partner.
    static func delete(accountId: UUID, cascade: Bool, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE accounts SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, accountId.uuidString]
        )
        guard cascade else { return }
        try database.execute(
            sql: """
            UPDATE transactions SET deleted_at = ?, updated_at = ?
            WHERE account_id = ? AND deleted_at IS NULL AND transfer_group_id IS NULL
            """,
            arguments: [now, now, accountId.uuidString]
        )
        try database.execute(
            sql: """
            UPDATE transactions SET deleted_at = ?, updated_at = ?
            WHERE deleted_at IS NULL AND transfer_group_id IN (
                SELECT mine.transfer_group_id FROM transactions mine
                JOIN transactions other ON other.transfer_group_id = mine.transfer_group_id
                    AND other.id <> mine.id AND other.deleted_at IS NULL
                JOIN accounts other_account ON other_account.id = other.account_id
                WHERE mine.account_id = ? AND mine.deleted_at IS NULL AND mine.transfer_group_id IS NOT NULL
                    AND other_account.deleted_at IS NOT NULL
            )
            """,
            arguments: [now, now, accountId.uuidString]
        )
    }
}
