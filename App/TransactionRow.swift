import KeepoCore
import SwiftUI

/// Shared by `TransactionsListView`'s Recent section and
/// `TransactionRegisterView`'s full history — the same row rendering
/// (category icon, currency conversion label, privacy mode) in one place
/// rather than two copies.
struct TransactionRow: View {
    let transaction: PublicSchema.TransactionsWithDetailsSelect
    var category: PublicSchema.CategoriesSelect?
    var isPendingUpdate: Bool = false

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var isTransfer: Bool { transaction.kind == "transfer" }

    var body: some View {
        HStack {
            if isTransfer {
                CategoryIconView(category: nil).overlay {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
            } else {
                CategoryIconView(category: category)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(isTransfer ? "Transfer" : (transaction.categoryName ?? "—"))
                        .foregroundStyle(Color.primary)
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
                        amountBase: transaction.amountBase,
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
        return MoneyFormatter.format(transaction.amount, currency: currency)
    }

    private var amountColor: Color {
        guard let amount = transaction.amount, amount < 0 else { return Color.primary }
        return Color.primary
    }
}
