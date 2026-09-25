import KeepoCore

/// Explicit delete for the transaction form's edit mode — split out of
/// TransactionFormView.swift purely to keep that file under the project's
/// file-length lint threshold. Standard practice whenever a swipe-action
/// exists elsewhere for the same object (the list's swipe-to-delete).
extension TransactionFormView {
    func deleteTransaction() async {
        isSaving = true
        errorMessage = nil
        // A transfer is deleted as a transfer or not at all. Falling through
        // to `delete_transaction` with one leg's id — which is what happened
        // when the other leg's version was unknown — is refused server-side
        // ("use delete_transfer") while the local write has already removed
        // the leg, so the outbox retried it forever.
        if let transferGroupId = editingTransferGroupId {
            guard let fromExpectedVersion = editingFromVersion, let toExpectedVersion = editingToVersion else {
                isSaving = false
                errorMessage = "Only the owner of the other account can delete this transfer."
                return
            }
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
