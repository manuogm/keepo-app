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
                        database, filter: effectiveFilter, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                    ),
                    categories: try LocalTableQueries.categories(database),
                    accounts: try LocalAccountRow.fetchAll(
                        database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency
                    )
                )
            }
            transactions = loaded.transactions
            filterCategories = loaded.categories
            filterAccounts = loaded.accounts
        } catch {
            loadErrorMessage = UserFacingError.describe(error)
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
}

private struct LoadedTransactionsState {
    let transactions: [PublicSchema.TransactionsWithDetailsSelect]
    let categories: [PublicSchema.CategoriesSelect]
    let accounts: [LocalAccountRow]
}
