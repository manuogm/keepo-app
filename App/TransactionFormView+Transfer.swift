import Foundation
import KeepoCore

// Transfer-specific create/update writes, split out of TransactionFormView.swift
// purely to keep that file under the project's file-length lint threshold —
// same precedent as TransactionFormView+Delete.swift.

extension TransactionFormView {
    func saveTransfer(accountId: UUID, magnitude: Int64) async throws {
        guard let toAccountId = selectedToAccountId else {
            errorMessage = "Choose a destination account."
            return
        }
        let receivedAmount = needsReceivedAmount ? AmountParser.parse(receivedAmountText) : nil
        if needsReceivedAmount && receivedAmount == nil {
            errorMessage = "Enter a valid received amount."
            return
        }

        if !transferDivergenceConfirmed, needsReceivedAmount, let toAmount = receivedAmount,
           let source = fromAccount, let destination = toAccount {
            divergenceWarning = await TransferDivergenceCheck.evaluate(
                client: session.client, sourceCurrency: source.currency, destinationCurrency: destination.currency,
                fromAmountE4: magnitude, toAmountE4: toAmount, occurredAt: occurredAt
            )
            if divergenceWarning != nil { return }
        }
        transferDivergenceConfirmed = false

        let payload = CreateTransferPayload(
            fromId: UUID(), toId: UUID(), fromAccountId: accountId, toAccountId: toAccountId,
            fromAmountE4: magnitude, toAmountE4: receivedAmount, occurredAt: occurredAt
        )
        await session.outbox.submitCreateTransfer(payload)
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
            toExpectedVersion: toExpectedVersion, fromAmountE4: magnitude, toAmountE4: toAmount, occurredAt: occurredAt
        )
        await session.outbox.submitUpdateTransfer(payload)
    }
}
