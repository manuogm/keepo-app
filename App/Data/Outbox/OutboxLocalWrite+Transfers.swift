import Foundation
import GRDB
import KeepoCore
import Supabase

// The transfer write-throughs — create, edit and delete, both legs at once —
// split out of OutboxLocalWrite.swift for the project's type-body-length lint,
// same precedent as OutboxLocalWrite+Capture.swift. The helpers moved with
// them because nothing else in that file used them.

extension OutboxLocalWrite {
    /// Both legs get an explicit id from the payload (`fromId`/`toId`) —
    /// unlike edit/delete, a create never has to guess which existing row is
    /// which.
    ///
    /// **`fromAmountE4` is a positive magnitude**, exactly as the server
    /// declares it ("from_amount must be a positive magnitude"). The signs
    /// belong to the write path, and this one has to apply the same ones
    /// `create_transfer` will or the mirror contradicts the row it stands
    /// in for: it used to store the magnitude verbatim, so until the next
    /// pull corrected it a brand-new transfer read as **income** on the
    /// account the money had just left, green `+` and all, and moved that
    /// balance the wrong way.
    ///
    /// **Both legs or neither.** `toAmountE4` is `nil` for a same-currency
    /// transfer — the form does not ask for a figure the two accounts
    /// already agree on — and the server coalesces it to `p_from_amount` in
    /// exactly that case, raising when the currencies differ. This mirrors
    /// that `coalesce`. It previously wrote the sending leg and then bailed
    /// out of the receiving one, which is what left every same-currency
    /// transfer as a lone half until it synced; and where the server would
    /// have raised, that half described a transfer the server never made.
    static func createTransfer(_ payload: CreateTransferPayload, in database: Database) throws {
        guard
            let ownerId = try accountOwnerId(database, accountId: payload.fromAccountId.uuidString),
            let fromCurrency = try accountCurrency(database, accountId: payload.fromAccountId.uuidString),
            let toCurrency = try accountCurrency(database, accountId: payload.toAccountId.uuidString)
        else { return }
        let mirroredAmountE4: Int64? = fromCurrency == toCurrency ? payload.fromAmountE4 : nil
        // Non-positive magnitudes are rejected rather than corrected: the
        // server raises on them, and a mirror that quietly fixed up a
        // payload would be describing a transfer that is about to fail.
        guard let toAmountE4 = payload.toAmountE4 ?? mirroredAmountE4,
              payload.fromAmountE4 > 0, toAmountE4 > 0
        else { return }

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let occurredAt = PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)
        // The group id `create_transfer` itself uses: the sending leg's id
        // (migration 20261006100000). It used to mint a random one, so this
        // was a placeholder — and an edit or delete made before the next
        // pull addressed a group the server had never heard of, failing
        // forever. Now both sides derive the same value from the same id.
        let groupId = payload.fromId.uuidString

        try SyncApply.upsertRow(
            transferLegRow(
                id: payload.fromId, ownerId: ownerId, accountId: payload.fromAccountId,
                amountE4: -payload.fromAmountE4,
                currency: fromCurrency, occurredAt: occurredAt, groupId: groupId, now: now,
                prose: (payload.notes, payload.title)
            ),
            table: "transactions", in: database
        )
        try SyncApply.upsertRow(
            transferLegRow(
                id: payload.toId, ownerId: ownerId, accountId: payload.toAccountId, amountE4: toAmountE4,
                currency: toCurrency, occurredAt: occurredAt, groupId: groupId, now: now,
                prose: (payload.notes, payload.title)
            ),
            table: "transactions", in: database
        )
    }

    /// Does what `update_transfer` does, in the order it does it: find each
    /// leg by its CURRENT sign, then write each one **by id**, with the
    /// server's signs — the payload carries two positive magnitudes and the
    /// sending leg is stored as `-fromAmountE4`.
    ///
    /// Both halves of that are load-bearing, and the version before this
    /// got both wrong. It wrote the sending leg as the positive magnitude,
    /// and it matched legs by sign statement by statement — so the second
    /// statement's `amount_e4 > 0` matched the leg the first had just turned
    /// positive, and wrote the received amount onto **both** halves. Until a
    /// pull corrected it, an edited transfer read as two inflows: the
    /// account the money left rose instead of falling, and reopening the
    /// transfer found no outflow leg to prefill from.
    ///
    /// `version` goes up by one per leg, exactly as `bump_version` does
    /// server-side — the same thing `updateTransaction` does — so a second
    /// edit made before the next pull sends the version the server now has
    /// instead of conflicting with its own previous save.
    ///
    /// A leg moved to another account (`fromAccountId`/`toAccountId`) takes
    /// that account's currency, as `update_transfer` makes it — a row's
    /// currency is always its account's.
    static func updateTransfer(_ payload: UpdateTransferPayload, in database: Database) throws {
        let legs = try Row.fetchAll(
            database,
            sql: """
            SELECT id, amount_e4, account_id, currency FROM transactions
            WHERE transfer_group_id = ? AND deleted_at IS NULL
            """,
            arguments: [payload.transferGroupId.uuidString]
        )
        guard
            let outflow = legs.first(where: { ($0["amount_e4"] as Int64) < 0 }),
            let inflow = legs.first(where: { ($0["amount_e4"] as Int64) > 0 })
        else { return }

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let occurredAt = PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)
        for (leg, movedTo, amountE4, version) in [
            (outflow, payload.fromAccountId, -payload.fromAmountE4, payload.fromExpectedVersion + 1),
            (inflow, payload.toAccountId, payload.toAmountE4, payload.toExpectedVersion + 1)
        ] {
            let legId: String = leg["id"]
            let currentAccountId: String? = leg["account_id"]
            let currentCurrency: String? = leg["currency"]
            let accountId = movedTo?.uuidString ?? currentAccountId
            let currency = try accountId.flatMap { try accountCurrency(database, accountId: $0) } ?? currentCurrency
            try database.execute(
                sql: """
                UPDATE transactions
                SET account_id = ?, currency = ?, amount_e4 = ?, occurred_at = ?, notes = ?, title = ?,
                    version = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    accountId, currency, amountE4, occurredAt, payload.notes, payload.title, version, now, legId
                ]
            )
        }
    }

    static func deleteTransfer(_ payload: DeleteTransferPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE transfer_group_id = ?",
            arguments: [now, now, payload.transferGroupId.uuidString]
        )
    }

    // MARK: - helpers

    private static func accountOwnerId(_ database: Database, accountId: String) throws -> String? {
        try String.fetchOne(database, sql: "SELECT owner_id FROM accounts WHERE id = ?", arguments: [accountId])
    }

    private static func accountCurrency(_ database: Database, accountId: String) throws -> String? {
        try String.fetchOne(database, sql: "SELECT currency FROM accounts WHERE id = ?", arguments: [accountId])
    }

    // `prose` is the note and the title together: the two things a user
    // writes about a transfer, both of which go on both legs.
    // swiftlint:disable:next function_parameter_count
    private static func transferLegRow(
        id: UUID, ownerId: String, accountId: UUID, amountE4: Int64, currency: String, occurredAt: String,
        groupId: String, now: String, prose: (notes: String?, title: String?)
    ) -> JSONObject {
        [
            "id": .string(id.uuidString), "owner_id": .string(ownerId), "created_by": .string(ownerId),
            "account_id": .string(accountId.uuidString), "category_id": .null,
            "amount_e4": .integer(Int(amountE4)), "currency": .string(currency),
            "occurred_at": .string(occurredAt), "transfer_group_id": .string(groupId), "source": .string("manual"),
            "status": .string("confirmed"),
            // Both legs, matching `create_transfer` server-side — see
            // `CreateTransferPayload.notes` for why.
            "notes": prose.notes.map(AnyJSON.string) ?? .null,
            "title": prose.title.map(AnyJSON.string) ?? .null,
            "version": .integer(1), "created_at": .string(now),
            "updated_at": .string(now), "sync_seq": .integer(0)
        ]
    }
}
