import Foundation
import KeepoCore

/// Data loading and mutation for `TransactionsListView` — split out purely
/// for file-length (SwiftLint's `type_body_length`), same reasoning as
/// `TransactionsListView+NeedsReview.swift`.
extension TransactionsListView {
    func load() async {
        loadErrorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let dbQueue = session.dbQueue
        let currentFilter = filter
        do {
            let loaded: LoadedTransactionsState = try await dbQueue.read { database in
                LoadedTransactionsState(
                    transactions: try LocalTransactionRow.fetchFiltered(
                        database, filter: currentFilter, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                    ),
                    accounts: try LocalAccountRow.fetchAll(
                        database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency
                    ),
                    categories: try LocalTableQueries.categories(database),
                    reviewRows: try LocalMoneyQueries.needsReview(database),
                    currencies: try LocalTableQueries.currencies(database)
                )
            }
            transactions = loaded.transactions
            filterAccounts = loaded.accounts
            filterCategories = loaded.categories
            reviewItems = try loaded.reviewRows.map { try LocalTransactionRow.needsReviewSelect(from: $0) }
            reviewCurrencies = Dictionary(uniqueKeysWithValues: loaded.currencies.map { ($0.code, Int($0.minorUnit)) })
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
    let accounts: [LocalAccountRow]
    let categories: [PublicSchema.CategoriesSelect]
    let reviewRows: [NeedsReviewLocalRow]
    let currencies: [PublicSchema.CurrenciesSelect]
}
