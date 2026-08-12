import Foundation
import Testing
@testable import KeepoCore

@Suite("PendingOverlay")
struct PendingOverlayTests {
    private let accountA = UUID()
    private let accountB = UUID()

    @Test("no pending ops leaves cached balances untouched")
    func noOps() {
        let result = PendingOverlay.accountBalances(cached: [accountA: 100], ops: [])
        #expect(result[accountA] == 100)
    }

    @Test("a pending expense subtracts from the cached balance")
    func pendingExpense() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [.transactionDelta(accountId: accountA, amount: -25)]
        )
        #expect(result[accountA] == 75)
    }

    @Test("multiple pending transactions on the same account accumulate")
    func multiplePendingTransactions() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [
                .transactionDelta(accountId: accountA, amount: -25),
                .transactionDelta(accountId: accountA, amount: -10),
                .transactionDelta(accountId: accountA, amount: 5)
            ]
        )
        #expect(result[accountA] == 70)
    }

    @Test("editing a pending transaction nets out the old effect before applying the new one")
    func editIsSubtractThenAdd() {
        // The adapter decomposes an edit into "undo the old effect, apply
        // the new one" — verifying that composition produces the right
        // final balance, not just that each op in isolation is correct.
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [
                .transactionDelta(accountId: accountA, amount: -20), // original create
                .transactionDelta(accountId: accountA, amount: 20), // undo it (edit)
                .transactionDelta(accountId: accountA, amount: -35) // apply the edited amount
            ]
        )
        #expect(result[accountA] == 65)
    }

    @Test("a transfer moves the same amount out of one account and into the other")
    func transferMovesBetweenAccounts() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100, accountB: 50],
            ops: [.transferDelta(fromAccountId: accountA, fromAmount: -40, toAccountId: accountB, toAmount: 40)]
        )
        #expect(result[accountA] == 60)
        #expect(result[accountB] == 90)
    }

    @Test("a cross-currency transfer's two legs need not be equal in magnitude")
    func crossCurrencyTransferLegsDiffer() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100, accountB: 50],
            ops: [.transferDelta(fromAccountId: accountA, fromAmount: -40, toAccountId: accountB, toAmount: 44)]
        )
        #expect(result[accountA] == 60)
        #expect(result[accountB] == 94)
    }

    @Test("setting a balance overrides the baseline, discarding deltas queued before it")
    func balanceOverrideDiscardsPriorDeltas() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [
                .transactionDelta(accountId: accountA, amount: -30),
                .accountBalanceOverride(accountId: accountA, newBalance: 500)
            ]
        )
        #expect(result[accountA] == 500)
    }

    @Test("a delta queued after a balance override is still additive on top of it")
    func deltaAfterOverrideIsAdditive() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [
                .accountBalanceOverride(accountId: accountA, newBalance: 500),
                .transactionDelta(accountId: accountA, amount: -20)
            ]
        )
        #expect(result[accountA] == 480)
    }

    @Test("two balance overrides in a row: the later one wins")
    func secondOverrideWins() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100],
            ops: [
                .accountBalanceOverride(accountId: accountA, newBalance: 500),
                .accountBalanceOverride(accountId: accountA, newBalance: 250)
            ]
        )
        #expect(result[accountA] == 250)
    }

    @Test("an account touched by no pending op is unaffected by ops on a different account")
    func untouchedAccountUnaffected() {
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 100, accountB: 50],
            ops: [.transactionDelta(accountId: accountA, amount: -30)]
        )
        #expect(result[accountB] == 50)
    }

    @Test("an account absent from cached but present via an offline-created account seed still overlays correctly")
    func newlyCreatedAccountSeed() {
        // The adapter seeds `cached` with an offline-created account's
        // opening balance before calling this — verifying the engine
        // treats that exactly like any other starting balance.
        let result = PendingOverlay.accountBalances(
            cached: [accountA: 200],
            ops: [.transactionDelta(accountId: accountA, amount: -50)]
        )
        #expect(result[accountA] == 150)
    }
}
