import Foundation
import KeepoCore

/// One line of the ledger — which is not the same thing as one row of
/// `transactions`.
///
/// A transfer is stored as two rows, one per account, because that is what
/// makes both balances come out right with a single balance formula (money
/// rule 1). The ledger was showing those two rows as two transactions:
/// "Transfer −$200, Checking" directly above "Transfer +$200, Savings",
/// which reads as $400 moving and gives the user two things to tap, two
/// things to delete, and no statement of where the money actually went.
/// Collapsing them here means the *screen* says "Checking → Savings, $200"
/// while the database keeps its two rows untouched.
///
/// Pairing is deliberately conditional. Filter the list to one account and
/// only that leg is loaded — there is no pair to make, and the single leg
/// still has to render, still signed, because from that account's side it
/// genuinely is money leaving or arriving.
struct TransactionEntry: Identifiable {
    let transaction: PublicSchema.TransactionsWithDetailsSelect
    /// The transfer's other leg, when both are on screen. `nil` for
    /// everything else, and for a transfer whose sibling the current filter
    /// excluded.
    let counterpart: PublicSchema.TransactionsWithDetailsSelect?

    /// **Never `?? UUID()`.** A computed `id` that mints a fresh UUID on
    /// every read gives the row a different identity on every diff, so
    /// SwiftUI tears down and rebuilds it instead of reusing it — and
    /// `.sheet(item:)`/`.onDelete` on that row target something that no
    /// longer exists. A row with no id is not a row this ledger can address
    /// at all, so it says so rather than inventing an address.
    var id: UUID? { transaction.transactionId }

    /// Folds each complete pair of transfer legs into a single entry,
    /// keeping the position of whichever leg came first so the ledger's
    /// order is unchanged.
    static func collapsingTransfers(
        _ transactions: [PublicSchema.TransactionsWithDetailsSelect]
    ) -> [TransactionEntry] {
        var legsByGroup: [UUID: [PublicSchema.TransactionsWithDetailsSelect]] = [:]
        for transaction in transactions {
            guard let groupId = transaction.transferGroupId else { continue }
            legsByGroup[groupId, default: []].append(transaction)
        }

        var absorbed: Set<UUID> = []
        var entries: [TransactionEntry] = []
        for transaction in transactions {
            guard let id = transaction.transactionId else {
                entries.append(TransactionEntry(transaction: transaction, counterpart: nil))
                continue
            }
            guard !absorbed.contains(id) else { continue }
            // Exactly two: one leg means a filtered view, and anything else
            // is a shape this screen should render as-is rather than guess at.
            guard
                let groupId = transaction.transferGroupId,
                let legs = legsByGroup[groupId], legs.count == 2,
                let other = legs.first(where: { $0.transactionId != id }),
                let otherId = other.transactionId
            else {
                entries.append(TransactionEntry(transaction: transaction, counterpart: nil))
                continue
            }
            absorbed.insert(otherId)
            entries.append(TransactionEntry(transaction: transaction, counterpart: other))
        }
        return entries
    }
}
