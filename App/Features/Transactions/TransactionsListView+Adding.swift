import KeepoCore
import SwiftUI

/// What happens when the user adds a transaction or taps one — the prefill a
/// new one opens on, and the fork a recurring row presents.
///
/// Split out of TransactionsListView.swift for the project's file-length
/// lint, same precedent as TransactionsListView+Export.swift. The two belong
/// together: both are the ledger handing what is on screen to a form.
extension TransactionsListView {
    /// What the ledger is currently narrowed to, handed to the form so that
    /// filtering and adding are one gesture instead of the same answers
    /// given twice. Read at presentation time, so it is whatever the panel
    /// says the moment the sheet opens rather than whatever it said when
    /// this screen was built.
    ///
    /// The period travels as a **date**, clamped into the range on screen:
    /// the list filters on `occurred_at`, so a transaction added while
    /// looking at March and dated today would save and then vanish. See
    /// `TransactionSeed.date(in:now:calendar:)`.
    var newTransactionSeed: TransactionSeed {
        TransactionSeed(filter: filter, visible: range)
    }

    // MARK: - Tapping a row

    func handleTap(on transaction: PublicSchema.TransactionsWithDetailsSelect) {
        if transaction.recurringRuleId != nil {
            recurringEditChoice = transaction
        } else {
            editingTransaction = transaction
        }
    }

    var recurringChoiceBinding: Binding<Bool> {
        Binding(get: { recurringEditChoice != nil }, set: { if !$0 { recurringEditChoice = nil } })
    }

    func openRecurringRule(for transaction: PublicSchema.TransactionsWithDetailsSelect) async {
        guard let ruleId = transaction.recurringRuleId else { return }
        editingRecurringRule = try? await session.dbQueue.read { database in
            try LocalTableQueries.recurringRule(database, id: ruleId.uuidString)
        }
    }
}
