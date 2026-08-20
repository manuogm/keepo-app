import KeepoCore
import SwiftUI

/// Upcoming Bills — 1×2 collapsed, 2×2 expanded.
///
/// Collapsed: what the next two weeks will cost, plus how many payments make
/// it up. Expanded: the payments themselves, each with its category's own
/// icon and colour so a bill is recognisable before its name is read.
///
/// Every amount here is signed and negative all the way through — these are
/// outflows. `MoneySignStyle.ledger` drops the minus at the display boundary,
/// where "due" already tells the user which direction the money goes; nothing
/// re-signs the value itself (money rule 1).
struct UpcomingBillsWidget: View {
    let metrics: UpcomingBillsMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.upcomingBills.title,
            systemImage: DashboardWidgetKind.upcomingBills.systemImage,
            onTap: onTap
        ) {
            if let metrics, !metrics.bills.isEmpty {
                if isExpanded {
                    expanded(metrics)
                } else {
                    collapsed(metrics)
                }
            } else {
                WidgetEmptyState(
                    systemImage: "calendar.badge.checkmark",
                    message: "Nothing due in the next two weeks."
                )
            }
        }
    }

    // MARK: - Collapsed

    private func collapsed(_ metrics: UpcomingBillsMetrics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            amount(metrics.totalE4, size: 30)
            Text(subtitle(metrics))
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func subtitle(_ metrics: UpcomingBillsMetrics) -> String {
        let count = metrics.bills.count
        return "\(count) payment\(count == 1 ? "" : "s") in the next \(metrics.windowDays) days"
    }

    // MARK: - Expanded

    private func expanded(_ metrics: UpcomingBillsMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                amount(metrics.totalE4, size: 26)
                Spacer(minLength: 8)
                Text(subtitle(metrics))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            // The list scrolls inside the tile: a fortnight of weekly rules
            // can be a dozen rows, and a tile that silently truncates would
            // under-report what is owed.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(metrics.bills) { bill in
                        row(bill)
                        if bill.id != metrics.bills.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ bill: UpcomingBillLocal) -> some View {
        HStack(spacing: 9) {
            CategoryIconView(icon: bill.categoryIcon, color: Color(hex: bill.categoryColor), diameter: 25)
            VStack(alignment: .leading, spacing: 1) {
                Text(bill.categoryName)
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("\(dueLabel(bill.dueOn)) · \(bill.accountName)")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            amountText(bill.amountBaseE4)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
        }
        .padding(.vertical, 6)
    }

    /// Formatted in `utcCalendar` — the same calendar the due date was
    /// decoded in. `Date.formatted` would use the device's zone and render
    /// every bill a day early for anyone west of UTC; see
    /// `PostgresDate.dateOnlyLabel`.
    private func dueLabel(_ date: Date) -> String {
        PostgresDate.dateOnlyLabel(date, calendar: utcCalendar)
    }

    // MARK: - Amounts

    private func amount(_ amountE4: Int64?, size: CGFloat) -> some View {
        BalanceHeaderView(amount: amountE4, currency: currency, size: size, signStyle: .ledger)
    }

    private func amountText(_ amountE4: Int64?) -> Text {
        guard let currency else { return Text("—") }
        return Text(MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger))
    }
}
