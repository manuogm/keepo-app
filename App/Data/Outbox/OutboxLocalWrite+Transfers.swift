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
        // A placeholder: the real group id is `gen_random_uuid()` inside the
        // function body, unknowable offline. Both legs share this one so
        // they pair up locally, and the next pull upserts each leg BY ITS
        // OWN id — those are client-supplied and stable — replacing the
        // placeholder in place rather than duplicating anything.
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

    /// Legs aren't identified by id here (the payload never carried one) —
    /// matched by their CURRENT sign instead, the same "negative outflow,
    /// positive inflow" convention money rule 1 fixes everywhere else in
    /// this codebase. A transfer edit never flips which side is the send
    /// side, so the sign a leg had before this edit is still the right key
    /// to find it by.
    static func updateTransfer(_ payload: UpdateTransferPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        let occurredAt = PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)
        try database.execute(
            sql: """
            UPDATE transactions SET amount_e4 = ?, occurred_at = ?, notes = ?, title = ?, updated_at = ?
            WHERE transfer_group_id = ? AND amount_e4 < 0
            """,
            arguments: [
                payload.fromAmountE4, occurredAt, payload.notes, payload.title, now, payload.transferGroupId.uuidString
            ]
        )
        try database.execute(
            sql: """
            UPDATE transactions SET amount_e4 = ?, occurred_at = ?, notes = ?, title = ?, updated_at = ?
            WHERE transfer_group_id = ? AND amount_e4 > 0
            """,
            arguments: [
                payload.toAmountE4, occurredAt, payload.notes, payload.title, now, payload.transferGroupId.uuidString
            ]
        )
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
