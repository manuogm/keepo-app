import Foundation
import KeepoCore

// Transfer-specific create/update writes, split out of TransactionFormView.swift
// purely to keep that file under the project's file-length lint threshold —
// same precedent as TransactionFormView+Delete.swift.

extension TransactionFormView {
    /// Returns the **outflow leg's** id, which is the one a tag goes on.
    /// Both legs are real rows, so tagging both would make any future sum
    /// over a tag count one $100 transfer as $200; the leg carrying the
    /// money out is the one that represents the movement.
    @discardableResult
    func saveTransfer(accountId: UUID, magnitude: Int64) async throws -> UUID? {
        guard let toAccountId = selectedToAccountId else {
            errorMessage = "Choose a destination account."
            return nil
        }
        let receivedAmount = needsReceivedAmount ? AmountParser.parse(receivedAmountText) : nil
        if needsReceivedAmount && receivedAmount == nil {
            errorMessage = "Enter a valid received amount."
            return nil
        }

        if !transferDivergenceConfirmed, needsReceivedAmount, let toAmount = receivedAmount,
           let source = fromAccount, let destination = toAccount {
            divergenceWarning = await TransferDivergenceCheck.evaluate(
                client: session.client, sourceCurrency: source.currency, destinationCurrency: destination.currency,
                fromAmountE4: magnitude, toAmountE4: toAmount, occurredAt: occurredAt
            )
            if divergenceWarning != nil { return nil }
        }
        transferDivergenceConfirmed = false

        let payload = CreateTransferPayload(
            fromId: UUID(), toId: UUID(), fromAccountId: accountId, toAccountId: toAccountId,
            fromAmountE4: magnitude, toAmountE4: receivedAmount, occurredAt: occurredAt,
            notes: notes.isEmpty ? nil : notes, title: TransactionTitle.stored(title)
        )
        pendingDelivery = await session.outbox.submitCreateTransfer(payload)
        return payload.fromId
    }

    func updateTransfer(magnitude: Int64) async throws {
        guard
            let transferGroupId = editingTransferGroupId,
            let fromExpectedVersion = editingFromVersion,
            let toExpectedVersion = editingToVersion
        else {
            errorMessage = "Missing transfer details."
            return
        }
        let receivedAmount = needsReceivedAmount ? AmountParser.parse(receivedAmountText) : magnitude
        guard let toAmount = receivedAmount, toAmount > 0 else {
            errorMessage = "Enter a valid received amount."
            return
        }
        let payload = UpdateTransferPayload(
            transferGroupId: transferGroupId, fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion, fromAmountE4: magnitude, toAmountE4: toAmount,
            occurredAt: occurredAt, notes: notes.isEmpty ? nil : notes, title: TransactionTitle.stored(title)
        )
        await session.outbox.submitUpdateTransfer(payload)
    }
}
