import KeepoCore

/// Explicit delete for the transaction form's edit mode — split out of
/// TransactionFormView.swift purely to keep that file under the project's
/// file-length lint threshold. Standard practice whenever a swipe-action
/// exists elsewhere for the same object (the list's swipe-to-delete).
extension TransactionFormView {
    func deleteTransaction() async {
        isSaving = true
        errorMessage = nil
        if let transferGroupId = editingTransferGroupId,
           let fromExpectedVersion = editingFromVersion,
           let toExpectedVersion = editingToVersion {
            let payload = DeleteTransferPayload(
                transferGroupId: transferGroupId,
                fromExpectedVersion: fromExpectedVersion, toExpectedVersion: toExpectedVersion
            )
            await session.outbox.submitDeleteTransfer(payload)
        } else if let id = editingId, let expectedVersion = editingFromVersion {
            let payload = DeleteTransactionPayload(id: id, expectedVersion: expectedVersion)
            await session.outbox.submitDeleteTransaction(payload)
        } else {
            isSaving = false
            errorMessage = "Missing transaction details."
            return
        }
        isSaving = false
        onSaved()
        dismiss()
    }
}
