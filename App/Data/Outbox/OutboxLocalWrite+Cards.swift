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
            // `deleted_at = NULL` too (item 1 fix) — the SELECT above
            // finds a row regardless of its deleted state, and a card
            // that was ever unmapped must be resurrected on re-map, not
            // silently updated-while-still-soft-deleted: every read here
            // (`LocalTableQueries.cardMappings`, `CaptureLocalWrite`'s own
            // account resolution) filters `deleted_at IS NULL`, so leaving
            // it set made a successful re-map invisible forever. Mirrors
            // `link_card_to_account`'s server-side fix exactly.
            try database.execute(
                sql: "UPDATE card_mappings SET account_id = ?, deleted_at = NULL, updated_at = ? WHERE id = ?",
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

    /// Mirrors `delete_transaction`'s own fix (item B, 2026-08
    /// device-testing batch): called by `OutboxLocalWrite.deleteTransaction`
    /// after a `source = 'capture'` row is soft-deleted — placeholders only
    /// (`account_id IS NULL`; a card genuinely mapped to an account is a
    /// deliberate user choice and is never touched here), and only once no
    /// other live pending capture still needs it. Without this, deleting
    /// the one purchase that ever referenced an unmapped card left its
    /// placeholder row behind, surfacing on its own as a bare "Unmapped
    /// card" Needs Review item with no transaction left to explain it.
    static func retireOrphanedCardMappingIfNeeded(
        ownerId: String, cardIdentifier: String, in database: Database
    ) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            UPDATE card_mappings AS cm SET deleted_at = ?, updated_at = ?
            WHERE cm.owner_id = ? AND cm.card_identifier = ? AND cm.account_id IS NULL AND cm.deleted_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM transactions t2
                WHERE t2.owner_id = cm.owner_id AND t2.card_identifier = cm.card_identifier
                  AND t2.source = 'capture' AND t2.status = 'pending' AND t2.deleted_at IS NULL
              )
            """,
            arguments: [now, now, ownerId, cardIdentifier]
        )
    }
}
