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
    var isPendingUpdate: Bool = false

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var isTransfer: Bool { transaction.kind == "transfer" }
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
                    Text(transaction.accountName ?? "—")
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
                Text(isPrivacyMode ? "••••" : formattedAmount)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: transaction.currency,
                        amountBase: transaction.amountBaseE4,
                        baseCurrency: transaction.baseCurrency,
                        baseMinorUnit: transaction.baseMinorUnit,
                        hasMissingRate: transaction.hasMissingRate ?? false,
                        signStyle: .ledger
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedAmount: String {
        guard let currencyCode = transaction.currency, let minorUnit = transaction.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(transaction.amountE4, currency: currency, signStyle: .ledger)
    }

    /// Green means "money arrived", by sign rather than by kind — which also
    /// gives a transfer's receiving leg the same treatment as income, since
    /// from the destination account's point of view that is exactly what it
    /// is. Outflows stay in the primary text colour rather than going red:
    /// spending is the normal case, and colouring every expense as an alert
    /// makes the colour mean nothing.
    private var amountColor: Color {
        guard let amount = transaction.amountE4, amount > 0 else { return Color.primary }
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
