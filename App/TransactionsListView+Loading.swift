import Foundation
import KeepoCore

/// Data loading and mutation for `TransactionsListView` — split out purely
/// for file-length (SwiftLint's `type_body_length`), same reasoning as
/// `TransactionsListView+NeedsReview.swift`.
extension TransactionsListView {
    func load() async {
        if filterAccounts.isEmpty {
            let fetched = try? await AccountRepository.fetchAllWithBalances(client: session.client)
            filterAccounts = fetched ?? cachedAccounts()
        }
        if filterCategories.isEmpty {
            let fetched = try? await CategoryRepository.fetchAll(client: session.client)
            filterCategories = fetched ?? cachedCategories()
        }
        if reviewCurrencies.isEmpty {
            let currencies = await CurrencyCache.fetchAll(session: session)
            reviewCurrencies = Dictionary(uniqueKeysWithValues: currencies.map { ($0.code, Int($0.minorUnit)) })
        }
        await reviewStore.load { try await NeedsReviewRepository.fetchAll(client: session.client) }
        // Caching only applies to the default, unfiltered page — a filtered
        // view has no offline fallback beyond whatever's already shown.
        await store.load(
            { try await TransactionRepository.fetchFiltered(client: session.client, filter: filter) },
            cache: filter.isEmpty ? session.payloadCache : nil
        )
    }

    func cachedAccounts() -> [PublicSchema.AccountsWithBalancesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "accounts_with_balances") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.AccountsWithBalancesSelect].self, from: data)) ?? []
    }

    func cachedCategories() -> [PublicSchema.CategoriesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "categories") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.CategoriesSelect].self, from: data)) ?? []
    }

    func delete(
        at offsets: IndexSet, in list: [PublicSchema.TransactionsWithDetailsSelect]
    ) async {
        var hadConflict = false
        for index in offsets {
            let transaction = list[index]
            guard let id = transaction.transactionId, let version = transaction.version else { continue }
            let result: OutboxSubmitResult
            if let groupId = transaction.transferGroupId, let siblingVersion = sibling(of: transaction)?.version {
                let payload = DeleteTransferPayload(
                    transferGroupId: groupId,
                    fromExpectedVersion: (transaction.amountE4 ?? 0) < 0 ? Int(version) : Int(siblingVersion),
                    toExpectedVersion: (transaction.amountE4 ?? 0) < 0 ? Int(siblingVersion) : Int(version)
                )
                result = await session.outbox.submitDeleteTransfer(payload)
            } else {
                let payload = DeleteTransactionPayload(id: id, expectedVersion: Int(version))
                result = await session.outbox.submitDeleteTransaction(payload)
            }
            if result == .conflict { hadConflict = true }
        }
        session.refresh.bump()
        if hadConflict { showConflictAlert = true }
    }
}
