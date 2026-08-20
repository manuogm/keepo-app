import KeepoCore
import SwiftUI

/// Which side of the ledger the user tapped into.
enum CashflowDirection: String, Identifiable, Equatable {
    case moneyIn
    case moneyOut

    var id: String { rawValue }
    var title: String { self == .moneyIn ? "Money In" : "Money Out" }
    var color: Color { self == .moneyIn ? CashflowPalette.income : CashflowPalette.expense }
    var categoryKind: PublicSchema.CategoryKind { self == .moneyIn ? .income : .expense }
}

/// Cashflow — 1×2 collapsed, 2×2 for the in/out split, 3×2 for one side's
/// categories.
///
/// The three sizes are not a cycle. A plain tap on the card opens or closes
/// the in/out view; tapping one of the two bars goes straight to that
/// direction's breakdown. Cycling blindly into the third size would open a
/// state with no direction selected and nothing to draw.
///
/// The window is always a **complete** month or year — see `CashflowPeriod`
/// for why a partial period would make the trend badge lie every time the
/// month rolled over.
struct CashflowWidget: View {
    let metrics: CashflowMetrics?
    let currency: CurrencyInfo?
    let expansionStep: Int?
    /// Loads a different window. The default window arrives preloaded in
    /// `metrics`, so switching to Year is the only thing that costs a read.
    let load: (CashflowPeriod) async -> CashflowMetrics?
    let onExpand: (Int?) -> Void

    @State private var period: CashflowPeriod = .month
    @State private var loaded: CashflowMetrics?
    @State private var direction: CashflowDirection?

    private var isExpanded: Bool { expansionStep != nil }
    private var isShowingBreakdown: Bool { expansionStep == 1 }

    /// The preloaded window unless the user picked another one.
    private var current: CashflowMetrics? {
        period == .month ? (loaded ?? metrics) : loaded
    }

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.cashflow.title,
            systemImage: DashboardWidgetKind.cashflow.systemImage,
            accessory: { AnyView(periodPicker) },
            onTap: cardTapped,
            content: { content }
        )
        .task(id: period) {
            guard period != .month else { return }
            loaded = await load(period)
        }
        // Edit mode collapses every tile, and a stale direction would then
        // reopen straight into a breakdown the user never asked for.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { direction = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let current, current.totals.moneyInE4 != nil || current.totals.moneyOutE4 != nil {
            if isShowingBreakdown, let direction {
                CashflowBreakdownView(metrics: current, direction: direction, currency: currency) {
                    self.direction = nil
                    onExpand(0)
                }
            } else if isExpanded {
                expanded(current)
            } else {
                collapsed(current)
            }
        } else {
            WidgetEmptyState(
                systemImage: "arrow.left.arrow.right",
                message: "Nothing moved in \(metrics?.periodLabel ?? "this period")."
            )
        }
    }

    /// A plain tap opens or closes the in/out view. It never reaches the
    /// breakdown — only a bar does.
    private func cardTapped() {
        direction = nil
        onExpand(isExpanded ? nil : 0)
    }

    // MARK: - Header

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(CashflowPeriod.allCases) { option in
                Button {
                    period = option
                } label: {
                    Text(option.label)
                        .font(.caption2.weight(period == option ? .bold : .regular))
                        .foregroundStyle(period == option ? Color.primary : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            period == option ? Color.secondary.opacity(0.15) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: period)
    }

    private func summary(_ metrics: CashflowMetrics, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            BalanceHeaderView(amount: metrics.totals.netE4, currency: currency, size: size)
            HStack(spacing: 6) {
                Text(rateLabel(metrics.totals.savingsRate))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                WidgetTrendBadge(percentChange: metrics.percentChange, caption: "vs. previous")
            }
        }
    }

    /// "kept 32% of income". `nil` — no income in the window — renders as
    /// the period's name instead of a 0% that would read as a real result.
    private func rateLabel(_ rate: Double?) -> String {
        guard let rate else { return "in \(current?.periodLabel ?? "")" }
        return "\(rate.formatted(.percent.precision(.fractionLength(0)))) of income"
    }

    // MARK: - Collapsed

    private func collapsed(_ metrics: CashflowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summary(metrics, size: 26)
            Spacer(minLength: 0)
            bars(metrics)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bars(_ metrics: CashflowMetrics) -> some View {
        VStack(spacing: 6) {
            bar(metrics, .moneyIn, amountE4: metrics.totals.moneyInE4)
            bar(metrics, .moneyOut, amountE4: metrics.totals.moneyOutE4)
        }
    }

    /// Each bar is its own tap target — that is the gesture the design calls
    /// for, and it is why the card's own tap can't cycle into the breakdown:
    /// the bar is what says *which* breakdown.
    private func bar(
        _ metrics: CashflowMetrics, _ barDirection: CashflowDirection, amountE4: Int64?
    ) -> some View {
        Button {
            direction = barDirection
            onExpand(1)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(barDirection.title)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                    Spacer(minLength: 4)
                    Text(amountLabel(amountE4))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(barDirection.color.opacity(0.15))
                        Capsule()
                            .fill(barDirection.color)
                            .frame(width: proxy.size.width * metrics.fill(of: amountE4))
                    }
                }
                .frame(height: 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
    }

    // MARK: - Expanded (in vs. out)

    private func expanded(_ metrics: CashflowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summary(metrics, size: 26)
            HStack(alignment: .center, spacing: 14) {
                DonutChartView(slices: inOutSlices(metrics)) {
                    Text(metrics.periodLabel)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                .frame(width: 112, height: 112)
                bars(metrics)
            }
            Spacer(minLength: 0)
        }
    }

    /// Magnitudes, not signed values — a donut cannot draw a negative wedge,
    /// and "how big was the outflow against the inflow" is the question this
    /// chart answers.
    private func inOutSlices(_ metrics: CashflowMetrics) -> [DonutSlice] {
        [
            DonutSlice(
                id: "in", label: CashflowDirection.moneyIn.title,
                value: Double(abs(metrics.totals.moneyInE4 ?? 0)), color: CashflowPalette.income
            ),
            DonutSlice(
                id: "out", label: CashflowDirection.moneyOut.title,
                value: Double(abs(metrics.totals.moneyOutE4 ?? 0)), color: CashflowPalette.expense
            )
        ]
        .filter { $0.value > 0 }
    }

    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency, signStyle: .ledger)
    }
}
