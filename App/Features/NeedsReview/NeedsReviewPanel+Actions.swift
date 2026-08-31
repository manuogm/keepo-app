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
    case acceptImport
    case rejectImport
    case dismissCard
}

extension NeedsReviewPanel {
    struct RowAction {
        let title: String
        let kind: NeedsReviewActionKind
    }

    /// The one-tap version of whatever opening the row would have led to.
    /// `nil` where there isn't one — an unmapped capture still routes
    /// through the full review form, which requires the explicit account
    /// choice a one-tap confirm can't provide (C-05).
    func quickAction(_ item: PublicSchema.NeedsReviewSelect) -> RowAction? {
        switch item.kind {
        case "sync_conflict": return RowAction(title: "Resolve", kind: .resolveConflict)
        case "pending_capture":
            return item.accountId == nil ? nil : RowAction(title: "Confirm", kind: .confirmCapture)
        case "csv_import_candidate": return RowAction(title: "Accept", kind: .acceptImport)
        default: return nil
        }
    }

    func destructiveAction(_ item: PublicSchema.NeedsReviewSelect) -> RowAction? {
        switch item.kind {
        // A card that's never getting mapped (a test card, one no longer in
        // use) had no way to leave this list short of mapping it to *some*
        // account — soft-deletes the `card_mappings` placeholder, same as
        // "Remove Mapping" in the Account edit sheet's card list.
        case "ambiguous_card": return RowAction(title: "Dismiss", kind: .dismissCard)
        case "csv_import_candidate": return RowAction(title: "Reject", kind: .rejectImport)
        default: return nil
        }
    }

    func perform(_ kind: NeedsReviewActionKind, on item: PublicSchema.NeedsReviewSelect) {
        Task {
            switch kind {
            case .confirmCapture: await confirmCapture(item)
            case .resolveConflict: await resolve(item)
            case .acceptImport: await acceptImportCandidate(item)
            case .rejectImport: await rejectImportCandidate(item)
            case .dismissCard: await dismissUnmappedCard(item)
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

    func load() async {
        actionErrorMessage = nil
        guard let ownerId = session.profile?.id else { return }
        do {
            let loaded = try await session.dbQueue.read { database in
                (
                    try LocalMoneyQueries.needsReview(database, ownerId: ownerId.uuidString),
                    try LocalTableQueries.currencies(database)
                )
            }
            // Animated — this is also how a "review, then confirm" trip
            // through TransactionFormView clears its row here: that sheet
            // dismisses, `onSaved()` bumps the refresh token, and this
            // reload is what actually removes the row the user just
            // confirmed.
            let freshItems = try loaded.0.map { try LocalTransactionRow.needsReviewSelect(from: $0) }
            withAnimation {
                items = freshItems
            }
            currencyMinorUnits = Dictionary(uniqueKeysWithValues: loaded.1.map { ($0.code, Int($0.minorUnit)) })
        } catch {
            actionErrorMessage = UserFacingError.isCancellation(error) ? nil : UserFacingError.describe(error)
        }
    }

    /// Removes an item from this panel the instant its underlying local row
    /// is known to have changed — never waiting on `session.refresh.bump()`'s
    /// own full reload, which is what made every action here feel laggy
    /// before (the whole list stayed frozen until a network round trip
    /// finished). `thenBump` still runs the app-wide refresh after, for the
    /// tab bar's own badge — safe only when the local mirror already
    /// reflects the change, or the reload it triggers would just resurrect
    /// the row this just animated away.
    private func removeLocally(_ id: UUID, thenBump: Bool = true) {
        withAnimation {
            items.removeAll { $0.itemId == id }
        }
        if thenBump {
            session.refresh.bump()
        }
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
        actionErrorMessage = nil
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: id)
            try? await session.dbQueue.write { database in
                try ConflictLocalQueries.markResolved(id: id.uuidString, in: database)
            }
            removeLocally(id)
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    /// The review screen is `TransactionFormView` in edit mode, not a
    /// bespoke capture-review screen (app-architecture.md) — this only
    /// fetches the one row `needs_review` doesn't carry in full.
    private func openForReview(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return }
        actionErrorMessage = nil
        do {
            guard let transaction = try await session.dbQueue.read({ database in
                try LocalTransactionRow.fetchOne(
                    database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }) else { return }
            editingTransaction = transaction
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    /// Confirming only ever flips `status` — any field edit goes through
    /// `open`'s normal transaction-edit path first. Needs the row's current
    /// version, which `needs_review` doesn't carry, hence the extra fetch.
    /// Goes through the outbox, not a direct RPC call — local-first, so the
    /// row is gone from this list before the network delivery (still running
    /// in the background) even finishes.
    private func confirmCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return }
        actionErrorMessage = nil
        do {
            guard let transaction = try await session.dbQueue.read({ database in
                try LocalTransactionRow.fetchOne(
                    database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }), let version = transaction.version else { return }
            await session.outbox.submitConfirmCaptureTransaction(
                ConfirmCaptureTransactionPayload(id: id, expectedVersion: Int(version))
            )
            removeLocally(id)
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    /// No local write-through exists for CSV import candidates (a
    /// server-only concept, no local mirror table for it) — `thenBump:
    /// false` skips the app-wide reload that would otherwise read the
    /// still-stale local state and resurrect the row this just animated
    /// away; the next real sync pull is what actually clears it everywhere
    /// else.
    private func acceptImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await ImportRepository.accept(client: session.client, id: id)
            removeLocally(id, thenBump: false)
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    private func rejectImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await ImportRepository.reject(client: session.client, id: id)
            removeLocally(id, thenBump: false)
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }
}
