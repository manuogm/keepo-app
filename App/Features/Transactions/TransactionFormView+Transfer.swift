import Foundation
import KeepoCore

// Transfer-specific create/update writes, split out of TransactionFormView.swift
// purely to keep that file under the project's file-length lint threshold —
// same precedent as TransactionFormView+Delete.swift.

/// What an edited transfer looked like when the sheet opened, so the rate
/// guard below speaks up only when something it judges has changed. Re-saving
/// a transfer the user already confirmed through the warning — to fix its
/// note, say — must not ask the same question again.
struct TransferBaseline: Equatable {
    let fromAccountId: UUID?
    let toAccountId: UUID?
    let fromAmountE4: Int64
    let toAmountE4: Int64
}

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
        if await rateDivergenceHoldsSave(fromAmountE4: magnitude, toAmountE4: receivedAmount) { return nil }

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
        let edited = TransferBaseline(
            fromAccountId: selectedAccountId, toAccountId: selectedToAccountId,
            fromAmountE4: magnitude, toAmountE4: toAmount
        )
        if edited != editingTransferBaseline,
           await rateDivergenceHoldsSave(fromAmountE4: magnitude, toAmountE4: toAmount) {
            return
        }
        let payload = UpdateTransferPayload(
            transferGroupId: transferGroupId, fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion, fromAmountE4: magnitude, toAmountE4: toAmount,
            occurredAt: occurredAt, notes: notes.isEmpty ? nil : notes, title: TransactionTitle.stored(title),
            fromAccountId: selectedAccountId, toAccountId: selectedToAccountId
        )
        await session.outbox.submitUpdateTransfer(payload)
    }

    /// What the SENDING picker may offer. Everything, on a new transfer; on
    /// an existing one, only accounts belonging to whoever owns the sending
    /// leg — `update_transfer` moves a leg between one owner's accounts and
    /// refuses anything else (a leg's owner is its account's owner, and
    /// `transactions_prevent_owner_id_change` fixes it). The receiving side's
    /// counterpart is in `transferDestinations`.
    var transferSourceAccounts: [LocalAccountRow] {
        guard let owner = ownerOfAccount(editingTransferBaseline?.fromAccountId) else { return accounts }
        return accounts.filter { $0.ownerId == owner }
    }

    func ownerOfAccount(_ id: UUID?) -> UUID? {
        accounts.first { $0.id == id }?.ownerId
    }

    /// The typo guard for a transfer between two currencies — a `320` typed
    /// as `3200` — asked on create and on edit alike. Editing used to skip
    /// it entirely, so a received amount could be corrected into a wildly
    /// wrong rate with nothing said.
    ///
    /// `true` means the save must stop: `divergenceWarning` is now set, and
    /// the alert's "Use Anyway" sets `transferDivergenceConfirmed` and saves
    /// again, which passes straight through here once. Same-currency
    /// transfers never ask — there is no rate to be off.
    private func rateDivergenceHoldsSave(fromAmountE4: Int64, toAmountE4: Int64?) async -> Bool {
        defer { transferDivergenceConfirmed = false }
        guard !transferDivergenceConfirmed, needsReceivedAmount, let toAmountE4,
              let source = fromAccount, let destination = toAccount
        else { return false }
        divergenceWarning = await TransferDivergenceCheck.evaluate(
            client: session.client, sourceCurrency: source.currency, destinationCurrency: destination.currency,
            fromAmountE4: fromAmountE4, toAmountE4: toAmountE4, occurredAt: occurredAt
        )
        return divergenceWarning != nil
    }
}
