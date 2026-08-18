import Foundation
import GRDB
import KeepoCore
import Supabase

// The Needs Review "review, then confirm" and plain "confirm" local
// write-throughs, split out of OutboxLocalWrite.swift purely to keep that
// file under the project's type-body-length lint threshold — same
// precedent as OutboxLocalWrite+Cards.swift.

extension OutboxLocalWrite {
    /// Mirrors `review_capture_transaction`'s own body exactly: the same
    /// column set `updateTransaction` writes, plus `status = 'confirmed'`
    /// in the same write, plus the card auto-link
    /// `updateTransaction`'s own local counterpart already does, plus a
    /// `merchant_category_map` upsert — all four in the one optimistic
    /// write-through this payload gets, matching the single server
    /// statement it mirrors. Reads the row's pre-write `account_id`,
    /// `source`, `card_identifier`, `owner_id`, `merchant_normalized`
    /// first, since the upsert below overwrites `account_id` unconditionally.
    static func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload, in database: Database) throws {
        let previous = try Row.fetchOne(
            database,
            sql: """
            SELECT account_id, source, card_identifier, owner_id, merchant_normalized
            FROM transactions WHERE id = ?
            """,
            arguments: [payload.id.uuidString]
        )

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let categoryKind = try categoryKind(database, categoryId: payload.categoryId.uuidString)
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "account_id": .string(payload.accountId.uuidString),
                "category_id": .string(payload.categoryId.uuidString),
                "category_kind": categoryKind.map(AnyJSON.string) ?? .null,
                "amount_e4": .integer(Int(payload.amountE4)), "currency": .string(payload.currency),
                "occurred_at": .string(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)),
                "merchant_raw": payload.merchantRaw.map(AnyJSON.string) ?? .null,
                "notes": payload.notes.map(AnyJSON.string) ?? .null, "status": .string("confirmed"),
                "version": .integer(payload.expectedVersion + 1), "updated_at": .string(now)
            ],
            table: "transactions", in: database
        )

        guard let previous, let ownerId = previous["owner_id"] as String? else { return }

        if (previous["account_id"] as String?) == nil, (previous["source"] as String?) == "capture",
           let cardIdentifier = previous["card_identifier"] as String? {
            try linkCardLocally(
                ownerId: ownerId, cardIdentifier: cardIdentifier, accountId: payload.accountId.uuidString, in: database
            )
        }

        // Reuses SyncApply's generic update-then-insert upsert — its
        // update-first behavior is exactly "teach the existing mapping a
        // new category" when one exists, and its insert-on-conflict-do-
        // nothing fallback is exactly "create it" when this is the
        // merchant's first review. Matches the server RPC's own
        // `on conflict (owner_id, merchant_pattern) do update` precisely.
        if let merchantNormalized = previous["merchant_normalized"] as String? {
            try SyncApply.upsertRow(
                [
                    "owner_id": .string(ownerId), "merchant_pattern": .string(merchantNormalized),
                    "category_id": .string(payload.categoryId.uuidString), "updated_at": .string(now),
                    "sync_seq": .integer(0)
                ],
                table: "merchant_category_map", in: database
            )
        }
    }

    /// Version-checked, same as every other edit here — a stale
    /// `expectedVersion` just no-ops locally (the eventual server reply, or
    /// the next sync pull, is what surfaces the real conflict). Mirrors the
    /// server's own `account_id IS NOT NULL` guard (C-05) so this mirror
    /// can't reach a "confirmed, no account" state the server would refuse,
    /// and re-teaches `merchant_category_map` (C-01) so an offline confirm
    /// benefits the next offline capture before the pull comes back.
    static func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload, in database: Database) throws {
        let previous = try Row.fetchOne(
            database,
            sql: "SELECT account_id, category_id, owner_id, merchant_normalized FROM transactions WHERE id = ?",
            arguments: [payload.id.uuidString]
        )
        guard let previous, (previous["account_id"] as String?) != nil else { return }
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: """
            UPDATE transactions SET status = 'confirmed', version = ?, updated_at = ? WHERE id = ? AND version = ?
            """,
            arguments: [payload.expectedVersion + 1, now, payload.id.uuidString, payload.expectedVersion]
        )
        guard
            let ownerId = previous["owner_id"] as String?, let categoryId = previous["category_id"] as String?,
            let merchantNormalized = previous["merchant_normalized"] as String?
        else { return }
        try SyncApply.upsertRow(
            [
                "owner_id": .string(ownerId), "merchant_pattern": .string(merchantNormalized),
                "category_id": .string(categoryId), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "merchant_category_map", in: database
        )
    }
}
