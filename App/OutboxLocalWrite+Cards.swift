import Foundation
import GRDB
import KeepoCore
import Supabase

// card_mappings local write-through, split out of OutboxLocalWrite.swift
// purely to keep that file under the project's type-body-length lint
// threshold — same precedent as Outbox+AccountsCategories.swift.

extension OutboxLocalWrite {
    /// Select-then-update-or-insert by the natural key `(owner_id,
    /// card_identifier)` — the local `card_mappings` table has no unique
    /// index over that pair (confirmed by reading `LocalStore.swift`),
    /// unlike Postgres's `unique (owner_id, card_identifier)`, so there's
    /// no `ON CONFLICT` to lean on here.
    static func linkCardLocally(
        ownerId: String, cardIdentifier: String, accountId: String, in database: Database
    ) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        if let existingId = try String.fetchOne(
            database, sql: "SELECT id FROM card_mappings WHERE owner_id = ? AND card_identifier = ?",
            arguments: [ownerId, cardIdentifier]
        ) {
            try database.execute(
                sql: "UPDATE card_mappings SET account_id = ?, updated_at = ? WHERE id = ?",
                arguments: [accountId, now, existingId]
            )
        } else {
            try SyncApply.upsertRow(
                [
                    "id": .string(UUID().uuidString), "owner_id": .string(ownerId),
                    "card_identifier": .string(cardIdentifier), "account_id": .string(accountId),
                    "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
                ],
                table: "card_mappings", in: database
            )
        }
    }

    /// The Account edit sheet's "manage mapped cards" writes — keyed by
    /// natural key (owner + the card's current identifier), matching the
    /// server RPCs (see `RenameCardMappingPayload`'s own header comment on
    /// why this changed from the mapping's row id: that id is
    /// server-generated, and a row created locally before its server
    /// counterpart ever synced down carries a client-invented id the
    /// server has never heard of — this `UPDATE` affects every local row
    /// sharing the natural key, so it also self-heals that exact case
    /// rather than silently missing the "wrong" one.
    static func renameCardMapping(_ payload: RenameCardMappingPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            UPDATE card_mappings SET card_identifier = ?, updated_at = ?
            WHERE owner_id = ? AND card_identifier = ? AND deleted_at IS NULL
            """,
            arguments: [payload.newCardIdentifier, now, payload.ownerId.uuidString, payload.oldCardIdentifier]
        )
    }

    static func unmapCard(_ payload: UnmapCardPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            UPDATE card_mappings SET deleted_at = ?, updated_at = ?
            WHERE owner_id = ? AND card_identifier = ? AND deleted_at IS NULL
            """,
            arguments: [now, now, payload.ownerId.uuidString, payload.cardIdentifier]
        )
    }
}
