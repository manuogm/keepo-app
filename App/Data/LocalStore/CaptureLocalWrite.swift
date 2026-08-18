import Foundation
import GRDB
import KeepoCore
import Supabase

/// The capture write's local-first counterpart to `capture_transaction`
/// (SQL) — mirrors its exact resolution order (mapped card → merchant
/// learning → the owner's `is_default` category) so a captured purchase is
/// visible in Needs Review the instant Apple Pay fires, offline included,
/// without waiting on the round trip `Outbox`'s background attempt still
/// makes separately. `resolveAndWrite` writes under the payload's own `id`
/// — the exact id the background RPC attempt (or a queued retry) also
/// sends — so the eventual server row lands on the identical primary key
/// and the later sync pull simply confirms this guess, never disagrees
/// with it.
///
/// Unlike account resolution, category resolution is a hard requirement —
/// `transactions.category_id` stays `NOT NULL` even for an unresolved
/// capture (only `account_id`/`currency` are nullable, and only ever for
/// this exact case). The only way this fails is if the local mirror hasn't
/// synced the owner's `is_default` "Other" category yet, which returns
/// `nil` here — the caller (`Outbox.submitCaptureTransaction`) falls back
/// to its RPC-or-queue path in that rare case, same as before local-first
/// capture existed at all.
///
/// Account resolution is optional and never blocks the write: an unmapped
/// card (or one whose mapping hasn't synced down locally yet) just writes
/// `account_id`/`currency` as null — the local mirror's own counterpart to
/// what `capture_transaction` now does server-side. This file deliberately
/// never creates the `card_mappings` placeholder row an unmapped card gets
/// server-side (that row's id is server-generated — `gen_random_uuid()` —
/// so a client guess here would permanently fork into a duplicate
/// `ambiguous_card` Needs Review entry the real mapping never resolves);
/// it only ever reads that table, never writes to it.
/// `public` — `Resolution` is carried whole by `OutboxCaptureResult
/// .appliedLocally` (`Outbox.swift`), itself a `public` type, and a nested
/// type's effective access can never exceed its container's.
public enum CaptureLocalWrite {
    public struct Resolution: Equatable, Sendable {
        public let accountName: String?
        public let categoryName: String
        /// True when nothing was actually learned for this merchant and
        /// resolution fell back to the owner's generic `is_default`
        /// category — the same signal `needs_review`'s own subtitle
        /// (`'Other'` vs `'Suggested: ' || c.name`) already uses to mean
        /// "not really known." Drives the notification copy's "category
        /// unknown" branch (`CaptureNotificationCopy`).
        public let categoryIsDefault: Bool
        public let currency: String?
        public let minorUnit: Int?
    }

    static func resolveAndWrite(
        _ payload: CaptureTransactionPayload, ownerId: String, in database: Database
    ) throws -> Resolution? {
        guard let category = try resolveCategory(
            database, ownerId: ownerId, merchantNormalized: payload.merchantNormalized
        ) else { return nil }
        let categoryId: String = category["id"]
        let categoryName: String = category["name"]
        let categoryIsDefault: Bool = category["is_default"]

        // `cm.deleted_at IS NULL` (fix A) — an unmapped card must resolve
        // to no account locally too, matching capture_transaction's own
        // fix; without it, a card the user had unmapped kept silently
        // auto-filing new captures into the account it used to belong to.
        let account = try Row.fetchOne(
            database,
            sql: """
            SELECT a.id, a.name, a.currency FROM card_mappings cm
            JOIN accounts a ON a.id = cm.account_id
            WHERE cm.owner_id = ? AND cm.card_identifier = ? AND cm.account_id IS NOT NULL
              AND cm.deleted_at IS NULL AND a.deleted_at IS NULL
            """,
            arguments: [ownerId, payload.cardIdentifier]
        )
        let accountId: String? = account?["id"]
        let accountName: String? = account?["name"]
        let currency: String? = account?["currency"]
        let minorUnit: Int? = try currency.flatMap {
            try Int.fetchOne(database, sql: "SELECT minor_unit FROM currencies WHERE code = ?", arguments: [$0])
        }

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(ownerId), "created_by": .string(ownerId),
                "account_id": accountId.map(AnyJSON.string) ?? .null, "category_id": .string(categoryId),
                "amount_e4": .integer(Int(-abs(payload.amountE4))), "currency": currency.map(AnyJSON.string) ?? .null,
                "occurred_at": .string(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)),
                "merchant_raw": .string(payload.merchantRaw),
                "merchant_normalized": .string(payload.merchantNormalized),
                "notes": payload.notes.map(AnyJSON.string) ?? .null, "card_identifier": .string(payload.cardIdentifier),
                "source": .string("capture"), "status": .string("pending"), "external_id": .string(payload.externalId),
                "version": .integer(1), "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "transactions", in: database
        )

        return Resolution(
            accountName: accountName, categoryName: categoryName, categoryIsDefault: categoryIsDefault,
            currency: currency, minorUnit: minorUnit
        )
    }

    private static func resolveCategory(
        _ database: Database, ownerId: String, merchantNormalized: String
    ) throws -> Row? {
        if let learned = try Row.fetchOne(
            database,
            sql: """
            SELECT c.id, c.name, c.is_default FROM merchant_category_map m
            JOIN categories c ON c.id = m.category_id
            WHERE m.owner_id = ? AND m.merchant_pattern = ? AND c.kind = 'expense' AND c.deleted_at IS NULL
            """,
            arguments: [ownerId, merchantNormalized]
        ) {
            return learned
        }
        return try Row.fetchOne(
            database,
            sql: """
            SELECT id, name, is_default FROM categories
            WHERE owner_id = ? AND kind = 'expense' AND is_default = 1 AND deleted_at IS NULL
            LIMIT 1
            """,
            arguments: [ownerId]
        )
    }
}
