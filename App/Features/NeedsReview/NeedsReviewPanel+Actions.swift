import KeepoCore
import SwiftUI

/// Every action the Needs Review panel can take on a row, split out of
/// `NeedsReviewPanel.swift` purely to keep that file under the project's
/// file-length lint threshold — same precedent as
/// `TransactionsListView+Loading.swift`.
/// What a row's button does. Free-standing rather than nested inside
/// `RowAction` — one more level and it would be three deep inside
/// `NeedsReviewPanel`.
enum NeedsReviewActionKind {
    case confirmCapture
    case resolveConflict
    case dismissCard
    case deleteCapture
}

extension NeedsReviewPanel {
    struct RowAction {
        /// What the action is called. It is not drawn — the swipe shows the
        /// glyph alone — so this is what VoiceOver reads, and the reason the
        /// words still live here rather than being dropped.
        let title: String
        /// The glyph the swipe draws. Named here rather than at the call
        /// site so the icon and the verb cannot come apart.
        let symbol: String
        let kind: NeedsReviewActionKind
    }

    /// The one-tap version of whatever opening the row would have led to,
    /// or `nil` where there isn't one — and for a capture, "isn't one" is
    /// the interesting case. See `isReadyToConfirm`.
    func quickAction(_ entry: NeedsReviewItem) -> RowAction? {
        switch entry.item.kind {
        // SF Symbols' own `checkmark`, and it cannot be made heavier from
        // here: UIKit rebuilds a swipe action's glyph from the symbol's
        // *name*, so `.fontWeight` and `.font(.system(size:weight:))` are
        // both dropped on the way. A custom asset would carry the weight;
        // it is not worth an asset.
        case "sync_conflict":
            return RowAction(title: "Resolve", symbol: "checkmark", kind: .resolveConflict)
        case "pending_capture":
            return isReadyToConfirm(entry)
                ? RowAction(title: "Confirm", symbol: "checkmark", kind: .confirmCapture) : nil
        default: return nil
        }
    }

    /// **A swipe may only confirm a capture that has nothing left to
    /// decide.** Confirming flips `status` and nothing else — so a swipe on
    /// a half-known capture would file a guess into the ledger, where it
    /// stops being flagged and starts being a balance. All three of the
    /// facts a transaction is made of have to already be there:
    ///
    /// - **an account**, which an unmapped card has not resolved to yet
    ///   (and without one there is no `currency` either —
    ///   `account_currency_together` binds the pair);
    /// - **an amount**. The local table has `amount_e4` NOT NULL, so this
    ///   can only ever be the generated type widening it to an optional —
    ///   but it is the optional the caller is handed, and a transaction
    ///   filed without a figure is the one mistake worth a dead branch.
    /// - **a category that is a category**, not the default "Other" the
    ///   capture pipeline falls back to when it recognises nothing. That
    ///   fallback is the app saying it does not know, and a gesture must
    ///   not turn "I don't know" into a filed answer.
    ///
    /// Anything short of that keeps the row tappable and the leading swipe
    /// empty: the review form is where a missing account or category is
    /// chosen, and choosing it there *is* the confirmation (C-05).
    ///
    /// **The notification banner already made this call**, on the same two
    /// facts — `CaptureQuickActions.build` offers Confirm only in its
    /// `(accountKnown, categoryKnown) == (true, true)` branch, reading
    /// `accountId != nil` and `!categoryIsDefault`. Two call sites agreeing
    /// by construction is allowed to stay two; a third is the signal to
    /// lift the predicate out. Change one of them and change the other.
    private func isReadyToConfirm(_ entry: NeedsReviewItem) -> Bool {
        guard let transaction = entry.transaction else { return false }
        return transaction.accountId != nil
            && transaction.amountE4 != nil
            && entry.category?.isDefault == false
    }

    func destructiveAction(_ item: PublicSchema.NeedsReviewSelect) -> RowAction? {
        switch item.kind {
        // A capture the user never made — a refund line, a duplicate, a
        // test — had no way out of this list except being confirmed into
        // the ledger and deleted from there. Same soft-delete the ledger's
        // own swipe performs, through the same outbox payload.
        case "pending_capture": return RowAction(title: "Delete", symbol: "trash", kind: .deleteCapture)
        // A card that's never getting mapped (a test card, one no longer in
        // use) had no way to leave this list short of mapping it to *some*
        // account — soft-deletes the `card_mappings` placeholder, same as
        // "Remove Mapping" in the Account edit sheet's card list.
        // A trash, like Delete above, because that is what it does —
        // it soft-deletes the placeholder mapping.
        case "ambiguous_card": return RowAction(title: "Dismiss", symbol: "trash", kind: .dismissCard)
        default: return nil
        }
    }

    func perform(_ kind: NeedsReviewActionKind, on item: PublicSchema.NeedsReviewSelect) {
        Task {
            switch kind {
            case .confirmCapture: await confirmCapture(item)
            case .resolveConflict: await resolve(item)
            case .dismissCard: await dismissUnmappedCard(item)
            case .deleteCapture: await deleteCapture(item)
            }
        }
    }

    /// Tapping the row itself — the full flow for whatever this item is.
    func open(_ item: PublicSchema.NeedsReviewSelect) {
        switch item.kind {
        case "pending_capture":
            Task { await openForReview(item) }
        case "ambiguous_card":
            mappingCard = item
            showCardMapping = true
        case "sync_conflict":
            conflictId = item.itemId
        default:
            break
        }
    }

    /// Everything one reload reads, in one `dbQueue.read`.
    ///
    /// The transactions are the addition: the inbox draws each pending
    /// capture with `TransactionRow`, which needs the whole row and its
    /// category, neither of which `needs_review`'s column contract carries.
    private struct Loaded {
        let items: [PublicSchema.NeedsReviewSelect]
        let transactions: [PublicSchema.TransactionsWithDetailsSelect]
        let categories: [PublicSchema.CategoriesSelect]
        let currencies: [PublicSchema.CurrenciesSelect]
    }

    func load() async {
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else { return }
        do {
            let loaded = try await session.dbQueue.read { database -> Loaded in
                let rows = try LocalMoneyQueries.needsReview(database, ownerId: ownerId.uuidString)
                let items = try rows.map { try LocalTransactionRow.needsReviewSelect(from: $0) }
                return Loaded(
                    items: items,
                    transactions: try LocalTransactionRow.fetch(
                        database,
                        ids: items.filter { $0.kind == "pending_capture" }
                            .compactMap { $0.itemId?.uuidString },
                        baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                    ),
                    categories: try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    currencies: try LocalTableQueries.currencies(database)
                )
            }
            // Animated — this is also how a "review, then confirm" trip
            // through TransactionFormView clears its row here: that sheet
            // dismisses, `onSaved()` bumps the refresh token, and this
            // reload is what actually removes the row the user just
            // confirmed.
            let fresh = assemble(loaded)
            withAnimation(AppTheme.Motion.standard) {
                items = fresh
            }
            currencyMinorUnits = Dictionary(
                uniqueKeysWithValues: loaded.currencies.map { ($0.code, Int($0.minorUnit)) }
            )
        } catch {
            actionError = ActionError("Couldn't Load Your Inbox", error)
        }
    }

    /// Joins each inbox row to the transaction and category behind it.
    /// Dictionaries rather than a `first(where:)` per row — the same reason
    /// `TransactionsListView` keeps `categoriesById`.
    private func assemble(_ loaded: Loaded) -> [NeedsReviewItem] {
        let transactionsById = Dictionary(
            loaded.transactions.compactMap { transaction in
                transaction.transactionId.map { ($0, transaction) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let categoriesById = Dictionary(loaded.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return loaded.items.map { item in
            let transaction = item.itemId.flatMap { transactionsById[$0] }
            return NeedsReviewItem(
                item: item,
                transaction: transaction,
                category: transaction?.categoryId.flatMap { categoriesById[$0] }
            )
        }
    }

    /// Removes an item from this panel the instant its underlying local row
    /// is known to have changed — never waiting on `session.refresh.bump()`'s
    /// own full reload, which is what made every action here feel laggy
    /// before (the whole list stayed frozen until a network round trip
    /// finished). The bump still follows, for the tab bar's own badge.
    ///
    /// It used to be optional (`thenBump: false`), for the one caller whose
    /// change had no local mirror to reload from — a CSV import candidate,
    /// where the refresh read still-stale local state and resurrected the
    /// row this had just animated away. That caller went with CSV import;
    /// every remaining action writes through the local store first, so the
    /// reload can only ever agree with what this already did.
    ///
    /// The animation is what the user actually sees: a `List` closes the
    /// gap left by a removed row on its own, so the row it just took an
    /// action on visibly leaves the inbox.
    private func removeLocally(_ id: UUID) {
        withAnimation(AppTheme.Motion.standard) {
            items.removeAll { $0.item.itemId == id }
        }
        resolvedCount += 1
        session.refresh.bump()
    }

    private func dismissUnmappedCard(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId, let cardIdentifier = item.subtitle, let ownerId = session.profile?.id else {
            return
        }
        await session.outbox.submitUnmapCard(
            UnmapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: cardIdentifier)
        )
        removeLocally(id)
    }

    private func resolve(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: id)
            try? await session.dbQueue.write { database in
                try ConflictLocalQueries.markResolved(id: id.uuidString, in: database)
            }
            removeLocally(id)
        } catch {
            actionError = ActionError("Couldn't Resolve This Conflict", error)
        }
    }

    /// The review screen is `TransactionFormView` in edit mode, not a
    /// bespoke capture-review screen (app-architecture.md) — this re-reads
    /// the row rather than using the copy the panel already holds for
    /// display, because the form saves against an `expectedVersion` and
    /// that copy is only as fresh as the last refresh.
    private func openForReview(_ item: PublicSchema.NeedsReviewSelect) async {
        do {
            guard let transaction = try await fetchCurrent(item) else { return }
            editingTransaction = transaction
        } catch {
            actionError = ActionError("Couldn't Open This Item", error)
        }
    }

    /// Confirming only ever flips `status` — any field edit goes through
    /// `open`'s normal transaction-edit path first. Goes through the outbox,
    /// not a direct RPC call — local-first, so the row is gone from this
    /// list before the network delivery (still running in the background)
    /// even finishes.
    private func confirmCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        do {
            guard let id = item.itemId, let transaction = try await fetchCurrent(item),
                  let version = transaction.version else { return }
            await session.outbox.submitConfirmCaptureTransaction(
                ConfirmCaptureTransactionPayload(id: id, expectedVersion: Int(version))
            )
            removeLocally(id)
        } catch {
            actionError = ActionError("Couldn't Confirm This Transaction", error)
        }
    }

    /// A capture the user is rejecting outright — the same soft delete, the
    /// same payload and the same optimistic-concurrency check the ledger's
    /// own swipe-to-delete performs, so a row rejected here and a row
    /// deleted there cannot end up meaning two different things.
    ///
    /// A capture is never half of a transfer (a transfer is only ever
    /// created by hand, in the form's Transfer tab), so there is no sibling
    /// leg to take with it — `DeleteTransferPayload` has no business here.
    private func deleteCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        do {
            guard let id = item.itemId, let transaction = try await fetchCurrent(item),
                  let version = transaction.version else { return }
            await session.outbox.submitDeleteTransaction(
                DeleteTransactionPayload(id: id, expectedVersion: Int(version))
            )
            removeLocally(id)
        } catch {
            actionError = ActionError("Couldn't Delete This Transaction", error)
        }
    }

    /// The row as it stands *now*, for the three callers that write against
    /// its `version`. One place, because "read it again before you write"
    /// is the rule, not a per-action decision.
    private func fetchCurrent(
        _ item: PublicSchema.NeedsReviewSelect
    ) async throws -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let id = item.itemId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return nil }
        return try await session.dbQueue.read { database in
            try LocalTransactionRow.fetchOne(
                database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
            )
        }
    }
}
