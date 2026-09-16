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
                    try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    try LocalTableQueries.tags(database),
                    try LocalTableQueries.currencies(database)
                )
            }
            accounts = loaded?.0 ?? []
            categories = loaded?.1 ?? []
            tagsById = Dictionary(uniqueKeysWithValues: (loaded?.2 ?? []).map { ($0.id, $0) })
            currencies = loaded?.3 ?? []
        }

        if case .edit(let transaction, let sibling) = mode {
            apply(transaction: transaction, sibling: sibling)
            await loadAppliedTags()
        } else {
            seedCreateDefaults()
        }
    }

    /// Read after `apply(transaction:sibling:)`, which is what sets
    /// `editingId`. `originalTagIds` is the baseline Save diffs against, so
    /// re-saving a transaction nobody re-tagged writes nothing at all.
    private func loadAppliedTags() async {
        guard let id = editingId else { return }
        let dbQueue = session.dbQueue
        let ids = (try? await dbQueue.read { database in
            try LocalTableQueries.tagIds(database, transactionId: id.uuidString)
        }) ?? []
        originalTagIds = Set(ids.compactMap(UUID.init(uuidString:)))
        selectedTagIds = originalTagIds
    }

    /// Writes only what changed, as one outbox item per added or removed
    /// tag, once `after` (the transaction's own network delivery, on a
    /// create) has finished.
    ///
    /// **Waiting is the whole point.** `submitCreateTransaction` returns as
    /// soon as the LOCAL write lands, with the POST still in flight, so a
    /// tag link sent immediately after it reaches the server before the
    /// transaction does and is rejected by `transaction_tags`' foreign key.
    /// The outbox retried and converged, so nothing was lost — but the
    /// failed attempt recorded an error the app-wide pending-sync banner
    /// then showed, for a save that had in fact worked. Observed live: a 400
    /// followed by a 201 thirty seconds later.
    ///
    /// Detached, so the sheet still dismisses immediately; the local
    /// write-through inside each submit is what the reopened form reads, and
    /// the refresh bump at the end is what tells the rest of the app.
    ///
    /// A **transfer is tagged on its outflow leg only**. Both legs are real
    /// rows, so tagging both would make any future sum over a tag count one
    /// $100 transfer as $200 — the leg carrying the money out is the one
    /// that represents the movement.
    func applyTagChanges(to transactionId: UUID, after delivery: Task<OutboxSubmitResult, Never>?) {
        guard let ownerId = session.profile?.id else { return }
        let added = selectedTagIds.subtracting(originalTagIds)
        let removed = originalTagIds.subtracting(selectedTagIds)
        guard !added.isEmpty || !removed.isEmpty else { return }
        let outbox = session.outbox
        let refresh = session.refresh

        Task {
            _ = await delivery?.value
            for (tagId, isApplied) in added.map({ ($0, true) }) + removed.map({ ($0, false) }) {
                await outbox.submitSetTransactionTag(
                    SetTransactionTagPayload(
                        transactionId: transactionId, tagId: tagId, ownerId: ownerId, isApplied: isApplied
                    )
                )
            }
            refresh.bump()
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
        applyForeignAmounts(transaction)
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
    /// Everything the write below needs, present and parseable. Lives
    /// beside `save()` rather than in the view: it is the same question
    /// that function asks, answered before the tap instead of after.
    var isSaveDisabled: Bool {
        if isSaving || selectedAccountId == nil || amountText.isEmpty { return true }
        if kind == .transfer {
            if selectedToAccountId == nil { return true }
            if needsReceivedAmount && receivedAmountText.isEmpty { return true }
        } else if selectedCategoryId == nil {
            return true
        }
        // Exactly the `needsReceivedAmount` rule above, for the same
        // reason: a second amount the entry genuinely needs and does not
        // have yet. Blocking Save says so before the tap rather than after.
        if isForeign && chargedAmountText.isEmpty { return true }
        return false
    }

    func save() async {
        guard let accountId = selectedAccountId else {
            errorMessage = "Choose an account."
            return
        }
        guard let magnitude = AmountParser.parse(amountText), magnitude > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }
        guard let amounts = resolveLedgerAmounts(magnitude: magnitude) else { return }

        isSaving = true
        errorMessage = nil
        do {
            let taggedTransactionId = try await write(
                accountId: accountId, magnitude: magnitude, amounts: amounts
            )

            // Skipped when a divergence warning stopped the write — there is
            // no transaction to tag, and the user has not confirmed yet.
            if let taggedTransactionId, divergenceWarning == nil {
                applyTagChanges(to: taggedTransactionId, after: pendingDelivery)
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

    /// The one write this save actually is, chosen from the kind and
    /// whether this is an edit. Split out of `save()` so that function stays
    /// what it reads as — validate, write, then tag and dismiss — rather
    /// than carrying a five-way switch in the middle of it.
    ///
    /// `magnitude` is what a transfer needs (its two legs are each already
    /// in their own account's currency); `amounts` is what a ledger row
    /// needs, where the figure stored and the figure paid can differ.
    private func write(accountId: UUID, magnitude: Int64, amounts: LedgerAmounts) async throws -> UUID? {
        switch (isEditing, kind) {
        case (false, .expense), (false, .income):
            return try await saveLedgerTransaction(accountId: accountId, amounts: amounts)
        case (false, .transfer):
            return try await saveTransfer(accountId: accountId, magnitude: magnitude)
        case (true, .expense), (true, .income):
            if isConfirmingCapture {
                try await reviewCaptureTransaction(accountId: accountId, amounts: amounts)
            } else {
                try await updateLedgerTransaction(accountId: accountId, amounts: amounts)
            }
            return editingId
        case (true, .transfer):
            try await updateTransfer(magnitude: magnitude)
            return editingId
        }
    }

    /// What the form's one or two amount fields mean for the row about to
    /// be written.
    struct LedgerAmounts {
        /// **Always in the account's currency** — the figure that moves the
        /// balance, and the only one any sum ever touches.
        let signedAmountE4: Int64
        /// Non-nil only when the purchase was made in another currency.
        /// Provenance, never arithmetic (CLAUDE.md money rule 6).
        let original: ForeignOriginal?
    }

    /// Splits the two fields into what the row stores, applying the sign
    /// once, from the kind the user picked — the same single point every
    /// write here has always signed at.
    ///
    /// Returns `nil` having set `errorMessage` when the entry is foreign
    /// and the charge is missing, which happens when no rate resolved and
    /// the user has not typed one: there is no number that belongs in the
    /// account's currency, and inventing one is the thing this whole
    /// workstream exists to stop.
    func resolveLedgerAmounts(magnitude: Int64) -> LedgerAmounts? {
        let signedPaid = kind == .expense ? -magnitude : magnitude
        guard isForeign, let code = paidCurrencyCode else {
            return LedgerAmounts(signedAmountE4: signedPaid, original: nil)
        }
        guard let charged = AmountParser.parse(chargedAmountText), charged > 0 else {
            errorMessage = "Enter the amount charged to \(fromAccount?.name ?? "this account")."
            return nil
        }
        return LedgerAmounts(
            signedAmountE4: kind == .expense ? -charged : charged,
            original: ForeignOriginal(amountE4: signedPaid, currency: code)
        )
    }

    /// Every write below goes through `session.outbox` (Phase 11), never
    /// `TransactionRepository` directly — an offline save queues instead of
    /// erroring; the app-wide stale-pending banner surfaces that, not this.
    @discardableResult
    func saveLedgerTransaction(accountId: UUID, amounts: LedgerAmounts) async throws -> UUID? {
        guard let userId = session.profile?.id, let categoryId = selectedCategoryId, let account = fromAccount else {
            errorMessage = "Choose a category."
            return nil
        }
        // The sign is applied once, in `resolveLedgerAmounts`, from the kind
        // the user picked — never re-derived here (money rule: never re-sign
        // in application code beyond that single point; the DB's
        // sign_matches_category_kind CHECK is the actual backstop).
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: userId, accountId: accountId, categoryId: categoryId,
            amountE4: amounts.signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            notes: notes.isEmpty ? nil : notes, original: amounts.original
        )
        pendingDelivery = await session.outbox.submitCreateTransaction(payload)
        return payload.id
    }

    func updateLedgerTransaction(accountId: UUID, amounts: LedgerAmounts) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let payload = UpdateTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amountE4: amounts.signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            merchantRaw: merchantRaw, notes: notes.isEmpty ? nil : notes, original: amounts.original
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
    func reviewCaptureTransaction(accountId: UUID, amounts: LedgerAmounts) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let payload = ReviewCaptureTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amountE4: amounts.signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            merchantRaw: merchantRaw, notes: notes.isEmpty ? nil : notes, original: amounts.original
        )
        await session.outbox.submitReviewCaptureTransaction(payload)
    }
}
