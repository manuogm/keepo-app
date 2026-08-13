import KeepoCore

/// `TransactionFormView`'s post-conflict reload — split out purely to keep
/// that file under the project's file-length lint threshold, same
/// reasoning as `TransactionsListView+NeedsReview.swift`.
extension TransactionFormView {
    /// A stale version means someone else changed this transaction since it
    /// loaded. `Outbox`'s write-through already applied OUR attempted edit
    /// to the local mirror optimistically (before the conflict was known),
    /// so a plain local re-read would just show that same wrong guess back
    /// — a sync pull is what actually corrects the local row to the real
    /// server state; only then is a local re-read meaningful. Repopulating
    /// with it lets the user decide whether to reapply their edit, rather
    /// than silently discarding what they typed or clobbering the newer data.
    func reloadAfterConflict() async {
        await session.syncEngine?.pull()
        guard let baseCurrency = session.profile?.baseCurrency else {
            showConflictAlert = true
            return
        }
        let groupId = editingTransferGroupId
        let id = editingId
        let transaction: PublicSchema.TransactionsWithDetailsSelect?
        let sibling: PublicSchema.TransactionsWithDetailsSelect?
        if let groupId {
            let legs = (try? await session.dbQueue.read { database in
                try LocalTransactionRow.fetchByTransferGroup(
                    database, transferGroupId: groupId.uuidString, baseCurrency: baseCurrency
                )
            }) ?? []
            transaction = legs.first { $0.transactionId == id } ?? legs.first
            sibling = legs.first { $0.transactionId != transaction?.transactionId }
        } else if let id {
            transaction = try? await session.dbQueue.read { database in
                try LocalTransactionRow.fetchOne(database, id: id.uuidString, baseCurrency: baseCurrency)
            }
            sibling = nil
        } else {
            transaction = nil
            sibling = nil
        }
        if let transaction {
            apply(transaction: transaction, sibling: sibling)
        }
        showConflictAlert = true
    }
}
