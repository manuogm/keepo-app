import Foundation
import GRDB
import KeepoCore

/// E: the detail `ConflictDetailSheet` needs beyond what `needs_review`'s
/// stable column contract carries for a `sync_conflict` row — `item.itemId`
/// there is the `sync_conflicts` audit row's own id (what `resolve_sync_conflict`
/// takes), not the transaction/account id that actually conflicted. A second,
/// narrow local read by that same id, straight off the table `LocalMoneyQueries`'
/// own `needsReview` query already reads.
struct SyncConflictDetail {
    let id: UUID
    let tableName: String
    let rowId: String
    let clientVersion: Int
    let serverVersion: Int
    /// The write the server rejected, when it kept one — every transaction
    /// RPC does since migration 20261008100000. `nil` for account conflicts
    /// and for anything recorded before then.
    let attemptedWrite: AttemptedTransactionWrite?
}

/// A rejected transaction write, exactly as the RPC received it, so "Keep
/// mine" can send it again with fresh versions. Before this existed "mine"
/// was rebuilt from whatever the local mirror still held, which could not
/// describe a transfer at all: a transfer has no category, the rebuild
/// required one, and the button silently kept the server's version.
///
/// One flat shape for every RPC rather than one type per RPC: the server
/// writes `{"rpc": <name>, ...arguments}` and each case below reads the
/// arguments it needs. Keys arrive snake_case.
struct AttemptedTransactionWrite: Decodable {
    let rpc: String
    let accountId: UUID?
    let categoryId: UUID?
    let amountE4: Int64?
    let currency: String?
    let occurredAt: String?
    let merchantRaw: String?
    let notes: String?
    let originalAmountE4: Int64?
    let originalCurrency: String?
    let title: String?
    let transferGroupId: UUID?
    let fromAmountE4: Int64?
    let toAmountE4: Int64?
    let fromAccountId: UUID?
    let toAccountId: UUID?

    static func decode(_ json: String?) -> AttemptedTransactionWrite? {
        guard let data = json?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(AttemptedTransactionWrite.self, from: data)
    }

    /// The signed amount this write would have left on the conflicted row —
    /// for a transfer, its sending leg — or `nil` when it was a delete or a
    /// confirm, which change no amount.
    var attemptedAmountE4: Int64? {
        switch rpc {
        case "update_transaction", "review_capture_transaction": return amountE4
        case "update_transfer": return fromAmountE4.map { -$0 }
        default: return nil
        }
    }

    var occurredAtDate: Date? {
        occurredAt.flatMap(PostgresDate.date(fromTimestamp:))
    }

    private var original: ForeignOriginal? {
        guard let originalAmountE4, let originalCurrency else { return nil }
        return ForeignOriginal(amountE4: originalAmountE4, currency: originalCurrency)
    }

    /// Sends this write again through the same outbox call that made it,
    /// against the versions the rows are at now — `rowVersion` for the
    /// conflicted row, `legVersions` for both halves of a transfer, both read
    /// by the caller after its pull. Returns `false` when the write can no
    /// longer be expressed: the row, or one half of the transfer, is gone.
    ///
    /// Waits for each write's delivery, as "Keep mine" always has, so the
    /// conflict is marked resolved only after the write it resolves in favour
    /// of has been sent (or queued).
    @MainActor
    func replay(rowId: UUID, rowVersion: Int?, legVersions: (from: Int, to: Int)?, outbox: Outbox) async -> Bool {
        switch rpc {
        case "update_transaction", "review_capture_transaction":
            return await replayLedgerEdit(rowId: rowId, version: rowVersion, outbox: outbox)
        case "confirm_capture_transaction", "delete_transaction":
            guard let version = rowVersion else { return false }
            if rpc == "delete_transaction" {
                _ = await outbox.submitDeleteTransaction(
                    DeleteTransactionPayload(id: rowId, expectedVersion: version)
                ).value
            } else {
                _ = await outbox.submitConfirmCaptureTransaction(
                    ConfirmCaptureTransactionPayload(id: rowId, expectedVersion: version)
                ).value
            }
            return true
        case "update_transfer", "delete_transfer":
            return await replayTransfer(legVersions: legVersions, outbox: outbox)
        default:
            return false
        }
    }

    @MainActor
    private func replayLedgerEdit(rowId: UUID, version: Int?, outbox: Outbox) async -> Bool {
        guard let version, let accountId, let categoryId, let amountE4, let currency, let occurredAtDate else {
            return false
        }
        if rpc == "update_transaction" {
            _ = await outbox.submitUpdateTransaction(UpdateTransactionPayload(
                id: rowId, expectedVersion: version, accountId: accountId, categoryId: categoryId,
                amountE4: amountE4, currency: currency, occurredAt: occurredAtDate, merchantRaw: merchantRaw,
                notes: notes, original: original, title: title
            )).value
        } else {
            _ = await outbox.submitReviewCaptureTransaction(ReviewCaptureTransactionPayload(
                id: rowId, expectedVersion: version, accountId: accountId, categoryId: categoryId,
                amountE4: amountE4, currency: currency, occurredAt: occurredAtDate, merchantRaw: merchantRaw,
                notes: notes, original: original, title: title
            )).value
        }
        return true
    }

    @MainActor
    private func replayTransfer(legVersions: (from: Int, to: Int)?, outbox: Outbox) async -> Bool {
        guard let transferGroupId, let legs = legVersions else { return false }
        if rpc == "delete_transfer" {
            _ = await outbox.submitDeleteTransfer(DeleteTransferPayload(
                transferGroupId: transferGroupId, fromExpectedVersion: legs.from, toExpectedVersion: legs.to
            )).value
            return true
        }
        guard let fromAmountE4, let toAmountE4, let occurredAtDate else { return false }
        _ = await outbox.submitUpdateTransfer(UpdateTransferPayload(
            transferGroupId: transferGroupId, fromExpectedVersion: legs.from, toExpectedVersion: legs.to,
            fromAmountE4: fromAmountE4, toAmountE4: toAmountE4, occurredAt: occurredAtDate, notes: notes,
            title: title, fromAccountId: fromAccountId, toAccountId: toAccountId
        )).value
        return true
    }
}

enum ConflictLocalQueries {
    static func detail(_ database: Database, id: String) throws -> SyncConflictDetail? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, table_name, row_id, client_version, server_version, attempted_payload
            FROM sync_conflicts WHERE id = ?
            """,
            arguments: [id]
        ) else { return nil }
        guard let idString: String = row["id"], let uuid = UUID(uuidString: idString) else { return nil }
        return SyncConflictDetail(
            id: uuid, tableName: row["table_name"], rowId: row["row_id"],
            clientVersion: row["client_version"], serverVersion: row["server_version"],
            attemptedWrite: AttemptedTransactionWrite.decode(row["attempted_payload"])
        )
    }

    /// `resolve_sync_conflict` is online-only and, like `delete_category_
    /// and_reassign`, needs a local echo right after it succeeds — without
    /// one, `needs_review`'s local query (`resolved_at IS NULL`) keeps
    /// showing the row until the next sync pull happens to land, which can
    /// be much later than the moment the user just resolved it.
    static func markResolved(id: String, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(sql: "UPDATE sync_conflicts SET resolved_at = ? WHERE id = ?", arguments: [now, id])
    }
}
