import KeepoCore
import SwiftUI

/// The lower half of the expanded Cashflow widget: where one direction's
/// money came from or went, as a donut and a list.
///
/// Split from `CashflowWidget` because it is a genuinely separate question —
/// the widget owns the period, the totals and the history; this owns
/// everything that only exists once a direction and a bucket have been
/// picked.
///
/// Categories carry their own icon and colour throughout, in the donut and in
/// the rows, because the user chose them precisely so their own spending is
/// recognisable at a glance.
struct CashflowBreakdownView: View {
    let totals: CashflowTotalsLocal?
    let direction: CashflowDirection
    let currency: CurrencyInfo?
    /// The days behind these figures, handed to the Transactions screen when
    /// a row's chevron is tapped so it opens on the same window.
    let period: ClosedRange<Date>?
    let isLoading: Bool

    @Environment(AppNavigation.self) private var navigation: AppNavigation?

    private var categories: [CashflowCategoryLocal] {
        (totals?.byCategory ?? []).filter { $0.kind == direction.categoryKind }
    }

    private var totalE4: Int64? {
        direction == .moneyIn ? totals?.moneyInE4 : totals?.moneyOutE4
    }

    var body: some View {
        if isLoading {
            Text("Working this out…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if categories.isEmpty {
            WidgetEmptyState(
                systemImage: "tray",
                message: "No \(direction.title.lowercased()) in this period."
            )
        } else {
            // Top-aligned, not centred: the list is a `ScrollView`, which
            // takes every point of height offered, so a centred row puts the
            // donut halfway down with a dead band above it.
            HStack(alignment: .top, spacing: 12) {
                donut
                    .frame(width: 116, height: 116)
                list
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var donut: some View {
        DonutChartView(slices: slices) {
            VStack(spacing: 0) {
                Text("\(categories.count)")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(categories.count == 1 ? "category" : "categories")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    /// Magnitudes — a share of a total is what a donut says, and expense
    /// amounts are negative. A category whose own total is unresolvable
    /// (money rule 5) is dropped from the chart rather than drawn as a zero
    /// wedge; it still appears in the list below, showing "—", so it is never
    /// silently disappeared.
    private var slices: [DonutSlice] {
        categories.compactMap { category in
            guard let amountE4 = category.amountE4, amountE4 != 0 else { return nil }
            return DonutSlice(
                id: category.categoryId, label: category.name,
                value: Double(abs(amountE4)), color: Color(hex: category.color)
            )
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(categories) { category in
                    row(category)
                    if category.id != categories.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// The whole row is the button, not just the chevron — a 12pt glyph is a
    /// poor target, and there is nothing else in the row to tap.
    private func row(_ category: CashflowCategoryLocal) -> some View {
        Button {
            open(category)
        } label: {
            HStack(spacing: 10) {
                CategoryIconView(icon: category.icon, color: Color(hex: category.color), diameter: 28)
                Text(category.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(amountLabel(category.amountE4))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Text(shareLabel(category.amountE4))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
            }
            // The whole row is the target, at HIG's 44pt minimum — this one
            // navigates to another tab, so a miss is expensive.
            .padding(.vertical, 6)
            .frame(minHeight: WidgetStyle.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .accessibilityHint("Opens these transactions")
    }

    /// Switches to the Transactions tab showing exactly these transactions.
    ///
    /// The transfers roll-up has no category to filter by — it is several
    /// transfers from several accounts — so it asks for the kind instead.
    /// `UUID(uuidString:)` failing on its sentinel id is what distinguishes
    /// the two; see `CashflowCategoryLocal.transfersInId`.
    private func open(_ category: CashflowCategoryLocal) {
        guard let period else { return }
        navigation?.openTransactions(
            TransactionsRequest(
                categoryId: category.isTransfers ? nil : UUID(uuidString: category.categoryId),
                kind: category.isTransfers ? "transfer" : nil,
                utcDays: period
            )
        )
    }

    private func shareLabel(_ amountE4: Int64?) -> String {
        guard let amountE4, let totalE4, totalE4 != 0 else { return "—" }
        return (Double(abs(amountE4)) / Double(abs(totalE4)))
            .formatted(.percent.precision(.fractionLength(0)))
    }

    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger)
    }
}
