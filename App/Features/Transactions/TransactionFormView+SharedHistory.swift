import KeepoCore
import SwiftUI

// Where an account shared from a date lets this entry go, asked before the
// save rather than learned from the server's refusal after it. The rules and
// their sentences are `SharedHistory`'s; this file only says which accounts
// and dates the form is holding. Split out of TransactionFormView.swift for
// the project's file-length lint, same precedent as
// TransactionFormView+Date.swift.

extension TransactionFormView {
    /// The earliest day the calendar and the day chevrons offer, or nil when
    /// nothing limits this viewer on these accounts.
    var earliestAllowedDate: Date? {
        guard let viewer = session.profile?.id, let source = fromAccount else { return nil }
        if kind == .transfer, let destination = toAccount {
            return SharedHistory.earliestTransferDate(source.sharing, destination.sharing, for: viewer)
        }
        return SharedHistory.earliestDate(on: source.sharing, for: viewer)
    }

    /// Why the server would refuse this save, in its own words — shown as a
    /// pop-up before anything is written. Without it the phone would write
    /// the entry locally, the server would refuse it, and the user would find
    /// out from a "Couldn't Save a Change" alert after the sheet had closed.
    var sharedHistoryRefusal: String? {
        guard let viewer = session.profile?.id, let source = fromAccount else { return nil }
        let wasSource = kind == .transfer ? editingTransferBaseline?.fromAccountId : originalAccountId
        var legs = [SharedHistory.Leg(was: placement(of: wasSource, at: originalOccurredAt), now: placement(source))]
        if kind == .transfer, let destination = toAccount {
            legs.append(SharedHistory.Leg(
                was: placement(of: editingTransferBaseline?.toAccountId, at: originalOccurredAt),
                now: placement(destination)
            ))
        }
        return SharedHistory.refusal(saving: legs, viewer: viewer, isTransfer: kind == .transfer)
    }

    /// Puts `sharedHistoryRefusal` in front of the user, and says whether
    /// there was one — Save stops there.
    func presentSharedHistoryRefusal() -> Bool {
        guard let refusal = sharedHistoryRefusal else { return false }
        let subject = kind == .transfer ? "Transfer" : "Transaction"
        actionError = ActionError(title: "Couldn't Save \(subject)", message: refusal)
        return true
    }

    private func placement(_ account: LocalAccountRow) -> SharedHistory.Placement {
        SharedHistory.Placement(accountId: account.id, account: account.sharing, date: occurredAt)
    }

    private func placement(of accountId: UUID?, at date: Date?) -> SharedHistory.Placement? {
        guard let date, let account = accounts.first(where: { $0.id == accountId }) else { return nil }
        return SharedHistory.Placement(accountId: account.id, account: account.sharing, date: date)
    }
}
