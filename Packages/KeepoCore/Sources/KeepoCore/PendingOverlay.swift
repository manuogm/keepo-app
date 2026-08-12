import Foundation

/// The three ways a still-unsynced write can move an account's balance —
/// decoded from Outbox payloads by the App target's own adapter (which owns
/// those payload types) into these primitive-field cases, so the actual
/// fold/math lives here, pure and unit-testable like every other piece of
/// money logic in this package. Every case here is exactly the arithmetic
/// the server itself will do once the write lands — an overlay, never an
/// approximation.
public enum PendingOp: Sendable {
    /// A single leg's effect on one account — already signed. An ordinary
    /// create is one of these; an edit becomes two (subtract the old
    /// effect, add the new one); a delete is one with the amount negated.
    case transactionDelta(accountId: UUID, amount: Decimal)
    /// A transfer's two legs together — `fromAmount`/`toAmount` already
    /// signed (negative out of `fromAccountId`, positive into
    /// `toAccountId`), matching what `create_transfer` itself applies.
    case transferDelta(fromAccountId: UUID, fromAmount: Decimal, toAccountId: UUID, toAmount: Decimal)
    /// `set_account_balance`: not a delta — the account's balance becomes
    /// exactly `newBalance` at this point in the queue, with only ops
    /// *after* it still additive on top. Matches the RPC's own semantics:
    /// it recomputes the gap fresh against whatever the balance actually
    /// is when it finally runs, not whatever the client guessed offline.
    case accountBalanceOverride(accountId: UUID, newBalance: Decimal)
}

/// Applies queued-but-not-yet-synced writes on top of the last known
/// server balances, so a screen can show what an account balance *will be*
/// once those writes land, immediately, instead of waiting for a sync.
public enum PendingOverlay {
    /// `ops` must be in the order they were queued (the Outbox's own FIFO,
    /// oldest `createdAt` first) — `accountBalanceOverride` only means
    /// "everything before this is superseded" when folded in that order.
    /// An account with no cached balance and no pending op touching it is
    /// simply absent from the result, same as it was absent from `cached`.
    public static func accountBalances(cached: [UUID: Decimal], ops: [PendingOp]) -> [UUID: Decimal] {
        var overrideBaseline: [UUID: Decimal] = [:]
        var runningDelta: [UUID: Decimal] = [:]

        func applyDelta(_ accountId: UUID, _ amount: Decimal) {
            runningDelta[accountId, default: 0] += amount
        }

        for pendingOp in ops {
            switch pendingOp {
            case .transactionDelta(let accountId, let amount):
                applyDelta(accountId, amount)
            case .transferDelta(let fromAccountId, let fromAmount, let toAccountId, let toAmount):
                applyDelta(fromAccountId, fromAmount)
                applyDelta(toAccountId, toAmount)
            case .accountBalanceOverride(let accountId, let newBalance):
                overrideBaseline[accountId] = newBalance
                runningDelta[accountId] = 0
            }
        }

        var result = cached
        let touchedAccounts = Set(cached.keys).union(overrideBaseline.keys).union(runningDelta.keys)
        for accountId in touchedAccounts {
            let baseline = overrideBaseline[accountId] ?? cached[accountId] ?? 0
            result[accountId] = baseline + (runningDelta[accountId] ?? 0)
        }
        return result
    }
}
