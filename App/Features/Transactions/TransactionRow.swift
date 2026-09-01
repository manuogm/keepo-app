import KeepoCore
import SwiftUI

/// Shared by every transaction row in `TransactionsListView` — the same row
/// rendering (category icon, currency conversion label, privacy mode) in
/// one place.
///
/// Amounts render in ledger style: an expense drops its minus sign and an
/// income gains an explicit `+` in green. The stored value is untouched —
/// `amount` stays signed, and nothing here re-signs it (money rule 1). The
/// row already says which direction the money went by sitting under a
/// category and next to an account; a minus sign in front of every second
/// row is noise that makes the few genuinely negative *balances* elsewhere
/// in the app harder to notice.
struct TransactionRow: View {
    let transaction: PublicSchema.TransactionsWithDetailsSelect
    var category: PublicSchema.CategoriesSelect?
    /// The transfer's other leg, when the ledger has folded both into this
    /// one row (`TransactionEntry`). Its presence is what turns the row from
    /// "money left Checking" into "money moved Checking → Savings".
    var counterpart: PublicSchema.TransactionsWithDetailsSelect?
    var isPendingUpdate: Bool = false

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var isTransfer: Bool { transaction.kind == "transfer" }

    /// Source and destination, worked out from the signs rather than from
    /// which leg the list happened to reach first — the ledger keeps
    /// whichever came first, and that can be either one.
    private var legs: (from: PublicSchema.TransactionsWithDetailsSelect,
                       to: PublicSchema.TransactionsWithDetailsSelect)? {
        guard let counterpart else { return nil }
        return (transaction.amountE4 ?? 0) < 0 ? (transaction, counterpart) : (counterpart, transaction)
    }

    /// The leg every figure on this row is drawn from: the outgoing one for
    /// a combined transfer, so the amount shown is the amount that left.
    private var displayed: PublicSchema.TransactionsWithDetailsSelect { legs?.from ?? transaction }

    /// A transfer between two currencies does not have "an amount" — it has
    /// one on each side. Only then is the far side worth a second line.
    private var arrivingAmount: String? {
        guard let legs, legs.from.currency != legs.to.currency else { return nil }
        guard let code = legs.to.currency, let minorUnit = legs.to.minorUnit else { return nil }
        let currency = CurrencyInfo(code: code, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(legs.to.amountE4, currency: currency, signStyle: .magnitude)
    }

    private var isCombinedTransfer: Bool { counterpart != nil }

    // `status == .pending` — an automatic capture still waiting on review,
    // never true for a manually-entered transaction (those are created
    // already `confirmed`). Distinct from `isPendingUpdate` (unsynced
    // outbox write) — this row can be fully synced and still unreviewed.
    private var isPendingReview: Bool { transaction.status == .pending }
    private var isCaptured: Bool { transaction.source == .capture }
    private var isRecurring: Bool { transaction.recurringRuleId != nil }

    var body: some View {
        HStack(spacing: 12) {
            if isTransfer {
                CategoryIconView(icon: "arrow.left.arrow.right", color: Color.gray, diameter: 36)
            } else {
                CategoryIconView(category: category, diameter: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(isTransfer ? "Transfer" : (transaction.categoryName ?? "—"))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if isPendingReview {
                        PendingBadge()
                    }
                    if isPendingUpdate {
                        Image(systemName: "icloud.slash")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }

                HStack(spacing: 5) {
                    Text(accountLine)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    // How this row came to exist, when it wasn't the user
                    // typing it. Glyph-only and grey: it is provenance, and
                    // spelling it out on every row would crowd out the
                    // account name, which is what people actually scan for.
                    if isCaptured {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .accessibilityLabel("Captured automatically")
                    }
                    if isRecurring {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .accessibilityLabel("Part of a recurring payment")
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                PrivateText(formattedAmount)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if let arrivingAmount {
                    PrivateText("→ " + arrivingAmount)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                } else if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: displayed.currency,
                        amountBase: displayed.amountBaseE4,
                        baseCurrency: displayed.baseCurrency,
                        baseMinorUnit: displayed.baseMinorUnit,
                        hasMissingRate: displayed.hasMissingRate ?? false,
                        signStyle: .ledger
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Both accounts when the row is a whole transfer, one when it is a leg
    /// or an ordinary transaction. The arrow is the row's statement of
    /// direction, which is why the amount beside it needs no sign.
    private var accountLine: String {
        guard let legs else { return transaction.accountName ?? "—" }
        return "\(legs.from.accountName ?? "—") → \(legs.to.accountName ?? "—")"
    }

    private var formattedAmount: String {
        guard let currencyCode = displayed.currency, let minorUnit = displayed.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        // `.magnitude`, not `.ledger`: a combined transfer is neither an
        // inflow nor an outflow — the money is still the user's — so the
        // row draws the figure alone and lets the arrow say the rest.
        return MoneyFormatter.format(
            displayed.amountE4, currency: currency, signStyle: isCombinedTransfer ? .magnitude : .ledger
        )
    }

    /// Green means "money arrived", by sign rather than by kind — which also
    /// gives a transfer's receiving leg the same treatment as income, since
    /// from the destination account's point of view that is exactly what it
    /// is. Outflows stay in the primary text colour rather than going red:
    /// spending is the normal case, and colouring every expense as an alert
    /// makes the colour mean nothing.
    /// A combined transfer is exempt: green would say money arrived, and
    /// across the pair nothing did.
    private var amountColor: Color {
        guard !isCombinedTransfer, let amount = transaction.amountE4, amount > 0 else { return Color.primary }
        return Color.green
    }
}

/// A capture still waiting on review. Its own type because the transaction
/// form shows the identical badge, and two copies would drift.
struct PendingBadge: View {
    var body: some View {
        Text("Pending")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}
