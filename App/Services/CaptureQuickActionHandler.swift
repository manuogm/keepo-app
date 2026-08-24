import Foundation
import GRDB
import KeepoCore

/// Routes a tap on one of `CaptureQuickActions`' buttons to the same
/// `Outbox` writes `NeedsReviewView`/`TransactionFormView` already use for
/// resolving a capture — called from `AppDelegate.didReceive response:` for
/// every action identifier other than the default tap / "More options"
/// (those just deep-link into the app, exactly as before). Reuses
/// `CaptureEnvironment.makeOutbox()` rather than re-bootstrapping a client.
enum CaptureQuickActionHandler {
    /// `UNNotificationResponse` isn't `Sendable`, so `AppDelegate` extracts
    /// the handful of plain values this needs out of it synchronously,
    /// before ever crossing into the `Task` that calls `handle` — this
    /// struct is what actually gets captured across that boundary.
    struct Request: Sendable {
        let actionIdentifier: String
        let categoryIdentifier: String
        let transactionId: UUID
        let pickKind: String?
        let pickIds: [String]?
    }

    static func handle(_ request: Request) async {
        guard let environment = try? await CaptureEnvironment.makeOutbox() else { return }
        let outbox = environment.outbox
        let dbQueue = environment.dbQueue

        switch request.actionIdentifier {
        case CaptureQuickActions.confirmActionId:
            await confirm(transactionId: request.transactionId, outbox: outbox, dbQueue: dbQueue)
        case CaptureQuickActions.deleteActionId:
            await delete(transactionId: request.transactionId, outbox: outbox, dbQueue: dbQueue)
        default:
            guard let index = pickIndex(from: request.actionIdentifier), let kind = request.pickKind,
                  let ids = request.pickIds, index < ids.count, let pickedId = UUID(uuidString: ids[index])
            else { return }
            await review(
                transactionId: request.transactionId, kind: kind, pickedId: pickedId, outbox: outbox,
                dbQueue: dbQueue
            )
        }

        // A foregrounded RootView only refreshes on an explicit signal
        // (CaptureIntent.swift's own header explains why) — without this,
        // a quick-action write while Keepo happens to already be open would
        // apply locally but leave the visible Needs Review badge/list stale.
        CaptureNotify.post()
        CaptureQuickActionRegistry.unregister(identifier: request.categoryIdentifier)
    }

    private static func pickIndex(from actionIdentifier: String) -> Int? {
        let prefix = "capture.pick."
        guard actionIdentifier.hasPrefix(prefix) else { return nil }
        return Int(actionIdentifier.dropFirst(prefix.count))
    }

    private static func confirm(transactionId: UUID, outbox: Outbox, dbQueue: DatabaseQueue) async {
        guard let version = try? await currentVersion(transactionId, dbQueue) else { return }
        await outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: transactionId, expectedVersion: version)
        )
    }

    private static func delete(transactionId: UUID, outbox: Outbox, dbQueue: DatabaseQueue) async {
        guard let version = try? await currentVersion(transactionId, dbQueue) else { return }
        await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: transactionId, expectedVersion: version))
    }

    /// `reviewCaptureTransaction` takes the whole row, not a per-field
    /// patch (`ReviewCaptureTransactionPayload`'s own header explains why:
    /// a separate confirm/edit pair used to race and could silently drop an
    /// offline edit) — so a category pick needs the row's already-known
    /// account, and an account pick needs the *picked* account's currency,
    /// since the row's own `currency` is still null in that branch (money
    /// rule: currency comes from the account, never guessed).
    private static func review(
        transactionId: UUID, kind: String, pickedId: UUID, outbox: Outbox, dbQueue: DatabaseQueue
    ) async {
        guard let row = try? await currentRow(transactionId, dbQueue),
              let version = row["version"] as Int?, let amountE4 = row["amount_e4"] as Int64?,
              let occurredAtString = row["occurred_at"] as String?,
              let occurredAt = PostgresDate.date(fromTimestamp: occurredAtString)
        else { return }

        let existingAccountId = (row["account_id"] as String?).flatMap { UUID(uuidString: $0) }
        let existingCategoryId = (row["category_id"] as String?).flatMap { UUID(uuidString: $0) }
        let accountId = kind == "account" ? pickedId : existingAccountId
        let categoryId = kind == "category" ? pickedId : existingCategoryId
        guard let accountId, let categoryId else { return }

        let currency: String?
        if kind == "account" {
            currency = try? await dbQueue.read { database in
                try String.fetchOne(
                    database, sql: "SELECT currency FROM accounts WHERE id = ?", arguments: [pickedId.uuidString]
                )
            }
        } else {
            currency = row["currency"] as String?
        }
        guard let currency else { return }

        let payload = ReviewCaptureTransactionPayload(
            id: transactionId, expectedVersion: version, accountId: accountId, categoryId: categoryId,
            amountE4: amountE4, currency: currency, occurredAt: occurredAt,
            merchantRaw: row["merchant_raw"] as String?, notes: row["notes"] as String?
        )
        await outbox.submitReviewCaptureTransaction(payload)
    }

    private static func currentVersion(_ transactionId: UUID, _ dbQueue: DatabaseQueue) async throws -> Int? {
        try await dbQueue.read { database in
            try Int.fetchOne(
                database, sql: "SELECT version FROM transactions WHERE id = ?", arguments: [transactionId.uuidString]
            )
        }
    }

    private static func currentRow(_ transactionId: UUID, _ dbQueue: DatabaseQueue) async throws -> Row? {
        try await dbQueue.read { database in
            try Row.fetchOne(
                database,
                sql: """
                SELECT version, account_id, category_id, amount_e4, currency, occurred_at, merchant_raw, notes
                FROM transactions WHERE id = ?
                """,
                arguments: [transactionId.uuidString]
            )
        }
    }
}
