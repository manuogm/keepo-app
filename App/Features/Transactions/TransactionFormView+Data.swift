import KeepoCore
import SwiftUI

// Load, prefill and the ledger writes for TransactionFormView, split out of
// that file purely to keep it under the project's file-length lint
// threshold — same precedent as TransactionFormView+Transfer.swift.

extension TransactionFormView {
    /// Reads straight off the local GRDB mirror (Phase L6) — always
    /// current, never needs a cache-fallback chain the way a network fetch
    /// used to.
    func load() async {
        if let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency {
            let loaded = try? await session.dbQueue.read { database in
                (
                    try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency),
                    try LocalTableQueries.categories(database, ownerId: ownerId.uuidString)
                )
            }
            accounts = loaded?.0 ?? []
            categories = loaded?.1 ?? []
        }

        if case .edit(let transaction, let sibling) = mode {
            apply(transaction: transaction, sibling: sibling)
        } else {
            seedCreateDefaults()
        }
    }

    /// A new transaction opens on something rather than on nothing: the
    /// first account and the first category of the current kind. Both are
    /// changeable in one tap, and pre-selecting them means the common case
    /// (an expense on the account you use most) is amount-then-save.
    private func seedCreateDefaults() {
        if selectedAccountId == nil {
            selectedAccountId = accounts.first { $0.archivedAt == nil }?.id
        }
        if selectedCategoryId == nil {
            selectedCategoryId = categoriesForKind.first?.id
        }
    }

    /// Populates the form from a server row — the initial edit-mode prefill.
    func apply(
        transaction: PublicSchema.TransactionsWithDetailsSelect,
        sibling: PublicSchema.TransactionsWithDetailsSelect?
    ) {
        kind = {
            switch transaction.kind {
            case "income": return .income
            case "transfer": return .transfer
            default: return .expense
            }
        }()

        if let occurredAtString = transaction.occurredAt,
           let date = PostgresDate.date(fromTimestamp: occurredAtString) {
            occurredAt = date
        }

        addedByHouseholdMember = transaction.createdBy != nil && transaction.createdBy != session.profile?.id
        isPendingReview = transaction.status == .pending
        isCaptured = transaction.source == .capture
        editingRecurringRuleId = transaction.recurringRuleId

        switch kind {
        case .expense, .income:
            applyLedger(transaction)
        case .transfer:
            applyTransfer(transaction, sibling: sibling)
        }
    }

    private func applyLedger(_ transaction: PublicSchema.TransactionsWithDetailsSelect) {
        editingId = transaction.transactionId
        editingFromVersion = transaction.version.map(Int.init)
        selectedAccountId = transaction.accountId
        selectedCategoryId = transaction.categoryId
        merchantRaw = transaction.merchantRaw
        notes = transaction.notes ?? ""
        isConfirmingCapture = transaction.status == .pending && transaction.source == .capture
        if let amount = transaction.amountE4 {
            amountText = AmountFormatter.editableString(amount, minorUnit: Int(transaction.minorUnit ?? 2))
        }
    }

    private func applyTransfer(
        _ transaction: PublicSchema.TransactionsWithDetailsSelect,
        sibling: PublicSchema.TransactionsWithDetailsSelect?
    ) {
        let legs = [transaction, sibling].compactMap { $0 }
        guard
            let from = legs.first(where: { ($0.amountE4 ?? 0) < 0 }),
            let destination = legs.first(where: { ($0.amountE4 ?? 0) > 0 })
        else { return }
        editingTransferGroupId = transaction.transferGroupId
        editingFromVersion = from.version.map(Int.init)
        editingToVersion = destination.version.map(Int.init)
        selectedAccountId = from.accountId
        selectedToAccountId = destination.accountId
        if let amount = from.amountE4 {
            amountText = AmountFormatter.editableString(amount, minorUnit: Int(from.minorUnit ?? 2))
        }
        if from.currency != destination.currency, let amount = destination.amountE4 {
            receivedAmountText = AmountFormatter.editableString(amount, minorUnit: Int(destination.minorUnit ?? 2))
        }
    }
}

// MARK: - Writes

extension TransactionFormView {
    func save() async {
        guard let accountId = selectedAccountId else {
            errorMessage = "Choose an account."
            return
        }
        guard let magnitude = AmountParser.parse(amountText), magnitude > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            switch (isEditing, kind) {
            case (false, .expense), (false, .income):
                try await saveLedgerTransaction(accountId: accountId, magnitude: magnitude)
            case (false, .transfer):
                try await saveTransfer(accountId: accountId, magnitude: magnitude)
            case (true, .expense), (true, .income):
                if isConfirmingCapture {
                    try await reviewCaptureTransaction(accountId: accountId, magnitude: magnitude)
                } else {
                    try await updateLedgerTransaction(accountId: accountId, magnitude: magnitude)
                }
            case (true, .transfer):
                try await updateTransfer(magnitude: magnitude)
            }
            // A: the local write already landed by the time submitX
            // returns — the network delivery keeps running in the
            // background. A version conflict, if one happens, surfaces
            // later via Needs Review, not as a reason to keep this sheet
            // open; `divergenceWarning` is the one remaining pre-write gate.
            if divergenceWarning == nil {
                onSaved()
                dismiss()
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    /// Every write below goes through `session.outbox` (Phase 11), never
    /// `TransactionRepository` directly — an offline save queues instead of
    /// erroring; the app-wide stale-pending banner surfaces that, not this.
    func saveLedgerTransaction(accountId: UUID, magnitude: Int64) async throws {
        guard let userId = session.profile?.id, let categoryId = selectedCategoryId, let account = fromAccount else {
            errorMessage = "Choose a category."
            return
        }
        // Sign applied here, once, from the kind the user picked — never
        // re-derived elsewhere (money rule: never re-sign in application
        // code beyond this single point; the DB's sign_matches_category_kind
        // CHECK is the actual backstop).
        let signedAmountE4 = kind == .expense ? -magnitude : magnitude
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: userId, accountId: accountId, categoryId: categoryId,
            amountE4: signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            notes: notes.isEmpty ? nil : notes
        )
        await session.outbox.submitCreateTransaction(payload)
    }

    func updateLedgerTransaction(accountId: UUID, magnitude: Int64) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let signedAmountE4 = kind == .expense ? -magnitude : magnitude
        let payload = UpdateTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amountE4: signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            merchantRaw: merchantRaw, notes: notes.isEmpty ? nil : notes
        )
        await session.outbox.submitUpdateTransaction(payload)
    }

    /// The Needs Review "review, then confirm" path — one write instead of
    /// `updateLedgerTransaction` followed by a separate confirm. See
    /// `ReviewCaptureTransactionPayload`'s own header for why sending those
    /// as two independently-queued outbox writes was a real bug: they could
    /// race (whichever arrived second sent a now-stale `expectedVersion`),
    /// and offline, the outbox's own collapse-by-row-id rule could let the
    /// confirm silently discard the edit outright.
    func reviewCaptureTransaction(accountId: UUID, magnitude: Int64) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let signedAmountE4 = kind == .expense ? -magnitude : magnitude
        let payload = ReviewCaptureTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amountE4: signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            merchantRaw: merchantRaw, notes: notes.isEmpty ? nil : notes
        )
        await session.outbox.submitReviewCaptureTransaction(payload)
    }
}
