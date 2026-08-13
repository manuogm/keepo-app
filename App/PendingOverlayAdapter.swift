import Foundation
import KeepoCore

/// Bridges the App target's own `Outbox`/`OutboxPayloads` types — which
/// `KeepoCore` can't depend on, same reasoning as `OfflineStore`'s own
/// header comment on why the offline store lives here and not the package
/// — to `KeepoCore.PendingOverlay`'s pure engine: decodes every currently-
/// queued write, in the order it was queued, into the primitive-field
/// `PendingOp` cases the engine folds. The actual arithmetic stays in
/// `KeepoCore`, testable like every other piece of money logic in this
/// codebase; this file's only job is decoding and bookkeeping.
///
/// Deliberately not overlaid this pass: `updateTransfer`/`deleteTransfer`
/// (need the same old-value lookup `updateTransaction`/`deleteTransaction`
/// get, not yet built), `captureTransaction` (resolves its account via
/// `card_mappings` server-side, which isn't cached client-side), and any
/// opening-balance change from `updateAccount`. All of these still queue
/// and sync correctly — they just don't move a balance instantly the way
/// the cases below do.
@MainActor
enum PendingOverlayAdapter {
    /// One entry per transaction id this adapter needs "the old effect"
    /// for, to turn an edit or delete into "subtract the old effect, add
    /// the new one." Seeded from whatever's cached and updated as pending
    /// creates/edits are walked in order, so a chain of edits to the same
    /// still-unsynced row nets out correctly too.
    private static func pendingOps(
        outbox: Outbox, cachedTransactions: [UUID: (accountId: UUID, amount: Int64)]
    ) -> [PendingOp] {
        var known = cachedTransactions
        var ops: [PendingOp] = []
        let decoder = JSONDecoder()

        for (kind, data) in outbox.queuedKindsAndPayloads() {
            appendOps(for: kind, data: data, decoder: decoder, known: &known, ops: &ops)
        }
        return ops
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func appendOps(
        for kind: OutboxKind, data: Data, decoder: JSONDecoder,
        known: inout [UUID: (accountId: UUID, amount: Int64)], ops: inout [PendingOp]
    ) {
        switch kind {
        case .createTransaction:
            guard let payload = try? decoder.decode(CreateTransactionPayload.self, from: data) else { return }
            ops.append(.transactionDelta(accountId: payload.accountId, amount: payload.amountE4))
            known[payload.id] = (payload.accountId, payload.amountE4)

        case .updateTransaction:
            guard let payload = try? decoder.decode(UpdateTransactionPayload.self, from: data) else { return }
            if let old = known[payload.id] {
                ops.append(.transactionDelta(accountId: old.accountId, amount: -old.amount))
            }
            ops.append(.transactionDelta(accountId: payload.accountId, amount: payload.amountE4))
            known[payload.id] = (payload.accountId, payload.amountE4)

        case .deleteTransaction:
            guard let payload = try? decoder.decode(DeleteTransactionPayload.self, from: data) else { return }
            if let old = known[payload.id] {
                ops.append(.transactionDelta(accountId: old.accountId, amount: -old.amount))
            }
            known.removeValue(forKey: payload.id)

        case .createTransfer:
            guard let payload = try? decoder.decode(CreateTransferPayload.self, from: data) else { return }
            let toAmountE4 = payload.toAmountE4 ?? payload.fromAmountE4
            ops.append(.transferDelta(
                fromAccountId: payload.fromAccountId, fromAmount: -payload.fromAmountE4,
                toAccountId: payload.toAccountId, toAmount: toAmountE4
            ))
            known[payload.fromId] = (payload.fromAccountId, -payload.fromAmountE4)
            known[payload.toId] = (payload.toAccountId, toAmountE4)

        case .setAccountBalance:
            guard let payload = try? decoder.decode(SetAccountBalancePayload.self, from: data) else { return }
            ops.append(.accountBalanceOverride(accountId: payload.accountId, newBalance: payload.newBalanceE4))

        case .updateTransfer, .deleteTransfer, .captureTransaction,
             .createAccount, .updateAccount, .createCategory, .updateCategory:
            return
        }
    }

    /// Every currently cached transaction, keyed by id — the "old value"
    /// lookup `pendingOps` needs for edits/deletes. Reads straight from
    /// the same `PayloadCache` key `TransactionsListView` itself writes,
    /// so this works without that screen being on screen or its `@State`
    /// list populated.
    static func cachedTransactionLookup(session: SessionStore) -> [UUID: (accountId: UUID, amount: Int64)] {
        guard let (data, _) = session.payloadCache.load(key: "transactions_page_0") else { return [:] }
        guard let rows = try? JSONDecoder().decode(
            [PublicSchema.TransactionsWithDetailsSelect].self, from: data
        ) else { return [:] }
        var result: [UUID: (accountId: UUID, amount: Int64)] = [:]
        for row in rows {
            guard let id = row.transactionId, let accountId = row.accountId, let amount = row.amountE4 else { continue }
            result[id] = (accountId, amount)
        }
        return result
    }

    /// Every cached account balance, overlaid with whatever's still
    /// queued. Accounts untouched by any pending write pass through
    /// unchanged; an account with no cached balance at all (an
    /// unsnapshotted valuation account — money rule 5, "—" not "0") stays
    /// absent unless a pending `set_account_balance` override touches it.
    static func overlaidBalances(
        cached: [UUID: Int64], outbox: Outbox, cachedTransactions: [UUID: (accountId: UUID, amount: Int64)]
    ) -> [UUID: Int64] {
        let ops = pendingOps(outbox: outbox, cachedTransactions: cachedTransactions)
        return PendingOverlay.accountBalances(cached: cached, ops: ops)
    }

    /// Whether an already-cached transaction has a pending edit or delete
    /// queued against it — `TransactionsListView`'s own marker for "this
    /// row isn't what you're about to see once it syncs." Pending
    /// *creates* are already shown via `Outbox.pendingCreateTransactions`
    /// in their own "Pending sync" section; this only covers rows that
    /// already exist in the cached list.
    enum PendingRowState {
        case updated
        case deleted
    }

    static func pendingRowStates(outbox: Outbox) -> [UUID: PendingRowState] {
        var states: [UUID: PendingRowState] = [:]
        let decoder = JSONDecoder()
        for (kind, data) in outbox.queuedKindsAndPayloads() {
            switch kind {
            case .updateTransaction:
                guard let payload = try? decoder.decode(UpdateTransactionPayload.self, from: data) else { continue }
                states[payload.id] = .updated
            case .deleteTransaction:
                guard let payload = try? decoder.decode(DeleteTransactionPayload.self, from: data) else { continue }
                states[payload.id] = .deleted
            default:
                continue
            }
        }
        return states
    }

    /// Single-account convenience for `AccountFormView`'s balance-edit
    /// prefill: "what does this account's balance look like right now,
    /// including whatever the user already queued while offline."
    static func overlaidBalance(
        accountId: UUID, cachedBalance: Int64, outbox: Outbox,
        cachedTransactions: [UUID: (accountId: UUID, amount: Int64)]
    ) -> Int64 {
        let ops = pendingOps(outbox: outbox, cachedTransactions: cachedTransactions)
        let result = PendingOverlay.accountBalances(cached: [accountId: cachedBalance], ops: ops)
        return result[accountId] ?? cachedBalance
    }
}
