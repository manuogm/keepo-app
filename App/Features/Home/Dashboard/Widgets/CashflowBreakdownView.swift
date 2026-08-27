import KeepoCore
import SwiftUI

/// The lower half of the expanded Cashflow widget: where one direction's
/// money came from or went, as a full-width bar and a list.
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
            // takes every point of height offered, so a centred stack puts
            // the bar halfway down with a dead band above it.
            VStack(alignment: .leading, spacing: 12) {
                bar
                list
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The split, as one bar the full width of the widget.
    ///
    /// This replaces a donut, and the width is the reason. The donut was a
    /// 120pt square on the leading edge with the list squeezed into what was
    /// left, which even on a six-column tile is not much: category names
    /// truncated and their amounts wrapped onto a second line, so the
    /// breakdown was harder to read than the chart it was explaining. A bar
    /// needs one row of height and gives the list the whole width back.
    ///
    /// It is also the more honest shape here. A donut is a whole, and these
    /// shares are not guaranteed to be one: a category whose own total can't
    /// be converted contributes no segment (money rule 5), and the bar
    /// simply stops short of the end — visible remaining track, which the
    /// widget's guide explains. A donut with a wedge missing has no such
    /// reading.
    private var bar: some View {
        WidgetFillBar(segments: segments, thickness: 12)
            .accessibilityLabel("\(categories.count) categories")
    }

    /// One segment per category, in its own colour, largest first — the
    /// order the query already returns them in, so the bar and the list
    /// below read left-to-right as top-to-bottom.
    ///
    /// The denominator is the direction's own total, computed in SQL, never
    /// a client-side sum of these amounts (money rule 3). That is also what
    /// makes the short-bar case correct rather than accidental: a category
    /// that couldn't be converted is missing from the numerators while the
    /// denominator still counts everything, so the gap left at the end is
    /// exactly the unresolvable share.
    private var segments: [FillSegment] {
        categories.compactMap { category in
            guard let share = share(category.amountE4), share > 0 else { return nil }
            return FillSegment(id: category.categoryId, share: share, color: Color(hex: category.color))
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(categories) { category in
                    row(category)
                    if category.id != categories.last?.id {
                        Divider().padding(.leading, 40)
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
            HStack(spacing: 12) {
                CategoryIconView(icon: category.icon, color: Color(hex: category.color), diameter: 28)
                Text(category.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    PrivateText(amountLabel(category.amountE4))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                    // The *share* is not hidden. It says how the money is
                    // split, not how much there is, and blanking it would
                    // leave the bar above it explaining a breakdown whose
                    // rows had all become bullets.
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
            .padding(.vertical, 8)
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

    /// A category's share of its direction's total, 0-1. `nil` where either
    /// side is unresolvable — the bar draws no segment for it and the row
    /// prints "—", which is the same fact told twice rather than two
    /// different rules.
    private func share(_ amountE4: Int64?) -> Double? {
        guard let amountE4, let totalE4, totalE4 != 0 else { return nil }
        return Double(abs(amountE4)) / Double(abs(totalE4))
    }

    private func shareLabel(_ amountE4: Int64?) -> String {
        guard let share = share(amountE4) else { return "—" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger)
    }
}
