import KeepoCore
import SwiftUI

/// Shared by every transaction row in `TransactionsListView` — the same row
/// rendering (category icon, currency conversion label, privacy mode) in
/// one place.
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

    var body: some View {
        HStack {
            if isTransfer {
                CategoryIconView(icon: "arrow.left.arrow.right", color: Color.gray)
            } else {
                CategoryIconView(category: category)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(isTransfer ? "Transfer" : (transaction.categoryName ?? "—"))
                        .foregroundStyle(Color.primary)
                    if isPendingReview {
                        Text("Pending")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    if isPendingUpdate {
                        Image(systemName: "icloud.slash")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Text(transaction.accountName ?? "—")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(isPrivacyMode ? "••••" : formattedAmount)
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: transaction.currency,
                        amountBase: transaction.amountBaseE4,
                        baseCurrency: transaction.baseCurrency,
                        baseMinorUnit: transaction.baseMinorUnit,
                        hasMissingRate: transaction.hasMissingRate ?? false
                    )
                }
            }
        }
    }

    private var formattedAmount: String {
        guard let currencyCode = transaction.currency, let minorUnit = transaction.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(transaction.amountE4, currency: currency)
    }

    private var amountColor: Color {
        guard let amount = transaction.amountE4, amount < 0 else { return Color.primary }
        return Color.primary
    }
}
