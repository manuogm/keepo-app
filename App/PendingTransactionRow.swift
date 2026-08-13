import KeepoCore
import SwiftUI

/// Extracted from TransactionsListView.swift (Phase 14, when that file
/// crossed SwiftLint's file_length limit) — displays a pending, not-yet-
/// synced create from the offline outbox (Phase 11).
struct PendingTransactionDisplay: Identifiable {
    let id: UUID
    let accountName: String
    let categoryName: String
    let amountE4: Int64
    let currency: String
    let minorUnit: Int
}

struct PendingTransactionRow: View {
    let pending: PendingTransactionDisplay

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.categoryName)
                    .foregroundStyle(Color.primary)
                HStack(spacing: 4) {
                    Text(pending.accountName)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Image(systemName: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                    Text("Not synced")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            let currency = CurrencyInfo(code: pending.currency, minorUnit: pending.minorUnit)
            Text(MoneyFormatter.format(pending.amountE4, currency: currency))
                .monospacedDigit()
                .foregroundStyle(pending.amountE4 < 0 ? Color.primary : Color.primary)
        }
    }
}
