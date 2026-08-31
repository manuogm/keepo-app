import Foundation
import KeepoCore

/// Data loading and mutation for `TransactionsListView` — split out purely
/// for file-length (SwiftLint's `type_body_length`).
extension TransactionsListView {
    func load() async {
        loadErrorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let dbQueue = session.dbQueue
        let scope = session.scope
        let effectiveFilter: TransactionFilter = {
            var effective = filter
            effective.from = range.start
            effective.through = range.end
            return effective
        }()
        do {
            let loaded: LoadedTransactionsState = try await dbQueue.read { database in
                LoadedTransactionsState(
                    transactions: try LocalTransactionRow.fetchFiltered(
                        database, filter: effectiveFilter, scope: scope, baseCurrency: baseCurrency,
                        ownerId: ownerId.uuidString
                    ),
                    categories: try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    accounts: try LocalAccountRow.fetchAll(
                        database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency
                    )
                )
            }
            transactions = loaded.transactions
            filterCategories = loaded.categories
            filterAccounts = loaded.accounts
            // Day grouping and the category lookup are derived here, once,
            // rather than recomputed inside `body` — see `regroup`'s own
            // comment on why that mattered.
            regroup()
        } catch {
            // A cancelled load is not a failure the user needs told about —
            // it means the task id changed and a newer load is already in
            // flight. That happens routinely here now that another screen can
            // hand this one a filter *and* a period in the same turn: the
            // first load was cancelled mid-flight and surfaced "Something went
            // wrong" under a list that had loaded perfectly.
            if !UserFacingError.isCancellation(error) {
                loadErrorMessage = UserFacingError.describe(error)
            }
        }
        isLoading = false
    }

    /// A: the local write-through already removes each row from the list
    /// the moment this loop reaches it — the network delivery for each
    /// delete keeps running in the background after this function returns.
    /// A version conflict, if one happens, surfaces later via Needs Review,
    /// not as a reason to make the swipe-to-delete gesture wait.
    func delete(
        at offsets: IndexSet, in list: [PublicSchema.TransactionsWithDetailsSelect]
    ) async {
        for index in offsets {
            let transaction = list[index]
            guard let id = transaction.transactionId, let version = transaction.version else { continue }
            if let groupId = transaction.transferGroupId, let siblingVersion = sibling(of: transaction)?.version {
                let payload = DeleteTransferPayload(
                    transferGroupId: groupId,
                    fromExpectedVersion: (transaction.amountE4 ?? 0) < 0 ? Int(version) : Int(siblingVersion),
                    toExpectedVersion: (transaction.amountE4 ?? 0) < 0 ? Int(siblingVersion) : Int(version)
                )
                await session.outbox.submitDeleteTransfer(payload)
            } else {
                let payload = DeleteTransactionPayload(id: id, expectedVersion: Int(version))
                await session.outbox.submitDeleteTransaction(payload)
            }
        }
        session.refresh.bump()
    }

    /// The Transactions screen's own quick "Confirm" swipe action — an
    /// alternative to opening the full review form, same local-first outbox
    /// path `NeedsReviewView`'s own swipe action and `TransactionFormView`'s
    /// Save use. `session.refresh.bump()` is what makes the row's "Pending"
    /// badge disappear here AND clears it out of Needs Review, both reading
    /// the same local `status` column this write just flipped.
    func confirmCapture(_ transaction: PublicSchema.TransactionsWithDetailsSelect) async {
        guard let id = transaction.transactionId, let version = transaction.version else { return }
        await session.outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: id, expectedVersion: Int(version))
        )
        session.refresh.bump()
    }
}

private struct LoadedTransactionsState {
    let transactions: [PublicSchema.TransactionsWithDetailsSelect]
    let categories: [PublicSchema.CategoriesSelect]
    let accounts: [LocalAccountRow]
}
