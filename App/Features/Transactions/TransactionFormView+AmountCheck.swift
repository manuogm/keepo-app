import KeepoCore
import SwiftUI

// Reading the amount fields as they are typed, and turning an amount away —
// split out of TransactionFormView.swift for the file-length lint, same
// precedent as the other extensions beside it.
//
// The form used to say "Enter a valid amount." at the foot of the card, and
// only once Save was tapped. It now says what is wrong, under the block the
// amount is in, the moment it is wrong — `AmountIssue` decides what, and
// `TransactionDetailContainer` draws it.

extension TransactionFormView {
    /// The amount block's issue: the paid figure, or on a foreign entry the
    /// charge beneath it, which sits in the same block.
    var amountIssue: AmountIssue? {
        issue(in: amountText, minorUnit: paidCurrencyInfo?.minorUnit)
            ?? (isForeign ? issue(in: chargedAmountText, minorUnit: fromAccount?.currencyInfo.minorUnit) : nil)
    }

    /// A transfer's received figure, shown on the destination's own block.
    /// Only when there is one — a same-currency transfer mirrors the sent
    /// figure, which is already flagged on the block above.
    var receivedAmountIssue: AmountIssue? {
        guard needsReceivedAmount else { return nil }
        return issue(in: receivedAmountText, minorUnit: toAccount?.currencyInfo.minorUnit)
    }

    private func issue(in text: String, minorUnit: Int?) -> AmountIssue? {
        AmountIssue.of(text, minorUnit: minorUnit, isFinal: isAmountFinal)
    }

    /// Save's gate. Marks the entry final — which is what lets "0" and a
    /// lone "." count as problems at all — and reports whether anything is
    /// wrong.
    ///
    /// Bumps `amountRejections` only when the issue was **already on
    /// screen**: tapping Save again at a figure the form has already flagged
    /// still has to answer the tap. An issue that only appears now ("0"
    /// becoming final) is shaken by its block as it arrives, like every new
    /// one — bumping here too would buzz twice.
    func rejectsAmount() -> Bool {
        let before = [amountIssue, receivedAmountIssue]
        isAmountFinal = true
        let after = [amountIssue, receivedAmountIssue]
        guard after.contains(where: { $0 != nil }) else { return false }
        if after == before { amountRejections += 1 }
        return true
    }
}

/// Any keystroke in any amount field makes the entry provisional again, so
/// a "0" flagged by Save stops being flagged the moment the user starts
/// turning it into "0.50". A modifier rather than one more `onChange` in the
/// form's `body`, which is already at the SwiftUI type checker's limit.
struct AmountEditObserver: ViewModifier {
    let texts: [String]
    @Binding var isFinal: Bool

    func body(content: Content) -> some View {
        content.onChange(of: texts) { isFinal = false }
    }
}
