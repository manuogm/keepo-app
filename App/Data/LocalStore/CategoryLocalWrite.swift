import Foundation
import GRDB
import KeepoCore

/// B: the local echo for `CategoryRepository.deleteWithReassign`, called
/// once the online-only RPC has already succeeded (see that function's own
/// header comment for why category delete is never routed through the
/// offline outbox). Mirrors the server's own two-statement effect —
/// reassign every local transaction off this category, then soft-delete it
/// — so the screen doesn't have to wait for the next sync pull to see it.
enum CategoryLocalWrite {
    static func deleteAndReassignToOther(
        categoryId: UUID, kind: PublicSchema.CategoryKind, ownerId: UUID, in database: Database
    ) throws {
        guard let otherId = try String.fetchOne(
            database,
            sql: """
            SELECT id FROM categories
            WHERE owner_id = ? AND kind = ? AND is_default = 1 AND deleted_at IS NULL
            """,
            arguments: [ownerId.uuidString, kind.rawValue]
        ) else { return }

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            UPDATE transactions SET category_id = ?, updated_at = ?
            WHERE category_id = ? AND deleted_at IS NULL
            """,
            arguments: [otherId, now, categoryId.uuidString]
        )
        try database.execute(
            sql: "UPDATE categories SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, categoryId.uuidString]
        )
    }
}
