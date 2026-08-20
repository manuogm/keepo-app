import KeepoCore
import SwiftUI

/// Cashflow's 3×2 state: one direction's categories, as a donut and a list.
///
/// Split from `CashflowWidget` because it is a genuinely separate screen's
/// worth of content, not because of a line count — the widget owns the
/// period, the totals and the two bars; this owns everything that only
/// exists once a direction has been picked.
///
/// Categories carry their own icon and colour throughout, in the donut and
/// in the rows, because the user chose them precisely so their own spending
/// is recognisable at a glance.
struct CashflowBreakdownView: View {
    let metrics: CashflowMetrics
    let direction: CashflowDirection
    let currency: CurrencyInfo?
    /// Back to the in/out view. The breakdown needs its own way out — the
    /// card's tap is what got the user here.
    let onBack: () -> Void

    private var categories: [CashflowCategoryLocal] {
        metrics.totals.categories(direction.categoryKind)
    }

    private var totalE4: Int64? {
        direction == .moneyIn ? metrics.totals.moneyInE4 : metrics.totals.moneyOutE4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if categories.isEmpty {
                WidgetEmptyState(
                    systemImage: "tray",
                    message: "No \(direction.title.lowercased()) in \(metrics.periodLabel)."
                )
            } else {
                // Top-aligned, not centred: the list is a `ScrollView`, which
                // takes every point of height offered, so a centred row puts
                // the donut halfway down a tall tile with a dead band above
                // it. Both start at the top and the list grows downward.
                HStack(alignment: .top, spacing: 14) {
                    donut
                        .frame(width: 124, height: 124)
                    list
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to money in and out")

            Text(direction.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(direction.color)
            Spacer(minLength: 4)
            Text(amountLabel(totalE4))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
        }
    }

    private var donut: some View {
        DonutChartView(slices: slices) {
            VStack(spacing: 0) {
                Text("\(categories.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(categories.count == 1 ? "category" : "categories")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    /// Magnitudes — a share of a total is what a donut says, and expense
    /// amounts are negative. A category whose own total is unresolvable
    /// (money rule 5) is dropped from the chart rather than drawn as a zero
    /// wedge; it still appears in the list below, showing "—", so it is
    /// never silently disappeared.
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
                        Divider().padding(.leading, 28)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ category: CashflowCategoryLocal) -> some View {
        HStack(spacing: 8) {
            CategoryIconView(icon: category.icon, color: Color(hex: category.color), diameter: 20)
            Text(category.name)
                .font(.caption)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(amountLabel(category.amountE4))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text(shareLabel(category.amountE4))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 5)
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
