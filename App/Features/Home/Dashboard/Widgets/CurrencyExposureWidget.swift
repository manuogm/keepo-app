import KeepoCore
import SwiftUI

/// Currency Exposure — 1×1 collapsed, 2×2 expanded.
///
/// Collapsed: a donut of what the money is held in, with the largest
/// currency's share in the hole. Expanded: the full split, plus what one unit
/// of a chosen currency has been worth in the base currency over time —
/// one currency at a time, because two lines on one axis with different
/// scales is the dual-axis mistake in disguise.
struct CurrencyExposureWidget: View {
    let metrics: CurrencyExposureMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let loadTrend: (String) async -> [DashboardSeriesPoint]?
    let onTap: () -> Void

    @State private var selectedCurrency: String?
    @State private var trend: [DashboardSeriesPoint]?

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.currencyExposure.title,
            systemImage: DashboardWidgetKind.currencyExposure.systemImage,
            onTap: onTap
        ) {
            content
        }
        .task(id: TrendLoadKey(currency: selectedCurrency, isExpanded: isExpanded)) {
            guard isExpanded, let selectedCurrency else { return }
            trend = await loadTrend(selectedCurrency)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let metrics, metrics.slices == nil {
            // Distinct from "no accounts": we know there is money, we just
            // can't price it. Saying so beats a donut drawn from a partial
            // denominator, where every share would be wrong (money rule 5).
            WidgetEmptyState(
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                message: "Exchange rates are still catching up."
            )
        } else if let metrics, !metrics.positiveSlices.isEmpty {
            if isExpanded {
                expanded(metrics)
            } else {
                donut(metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 2)
            }
        } else {
            WidgetEmptyState(
                systemImage: "banknote",
                message: "No balances to break down yet."
            )
        }
    }

    // MARK: - Collapsed

    /// Unsized on purpose — the collapsed tile lets it fill, the expanded one
    /// pins it to a square beside the legend. A donut that inherits
    /// `maxHeight: .infinity` in a tall container centres itself vertically
    /// and leaves a gap above it, which is what the expanded layout looked
    /// like before it was given an explicit size.
    private func donut(_ metrics: CurrencyExposureMetrics) -> some View {
        DonutChartView(slices: slices(metrics)) {
            VStack(spacing: 0) {
                Text(metrics.largest?.currency ?? "—")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(shareLabel(metrics.largestShare))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func slices(_ metrics: CurrencyExposureMetrics) -> [DonutSlice] {
        metrics.positiveSlices.map { slice in
            DonutSlice(
                id: slice.currency, label: slice.currency,
                value: Double(slice.amountBaseE4), color: CurrencyColor.color(for: slice.currency)
            )
        }
    }

    /// Money rule 5's shape, applied to a ratio: an unresolvable share is
    /// "—", never 0%.
    private func shareLabel(_ share: Double?) -> String {
        guard let share else { return "—" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Expanded

    /// Donut and legend share the top band; the rate chart gets the full
    /// width underneath it. Putting the chart in a side column instead would
    /// give a time series roughly 150 points to live in, which is not enough
    /// width for a line to mean anything.
    private func expanded(_ metrics: CurrencyExposureMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                donut(metrics)
                    .frame(width: 112, height: 112)
                legend(metrics)
            }
            Divider()
            trendSection
        }
    }

    /// Every currency, including net-short ones — those are excluded from the
    /// donut (a negative wedge is not a thing) but they are real positions,
    /// and a breakdown that silently omitted them would be lying by
    /// selection. Tapping one picks it for the rate chart below.
    private func legend(_ metrics: CurrencyExposureMetrics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(metrics.slices ?? []) { slice in
                Button {
                    selectedCurrency = slice.currency == baseCode ? nil : slice.currency
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CurrencyColor.color(for: slice.currency))
                            .frame(width: 7, height: 7)
                        Text(slice.currency)
                            .font(.caption2.weight(selectedCurrency == slice.currency ? .bold : .regular))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 4)
                        Text(amountLabel(slice.amountBaseE4))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableRow)
                .disabled(slice.currency == baseCode)
            }
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        if let selectedCurrency {
            VStack(alignment: .leading, spacing: 2) {
                Text("1 \(selectedCurrency) in \(baseCode)")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                if let trend, trend.count >= 3 {
                    NetWorthChartView(seriesPoints: trend, showAxes: false, trendColor: .secondary)
                } else {
                    Text("Not enough rate history yet.")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } else {
            Text("Pick a currency to see its rate against \(baseCode).")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var baseCode: String { currency?.code ?? "—" }

    private func amountLabel(_ amountE4: Int64) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency)
    }
}

/// `.task(id:)` needs one `Equatable` id — collapsing or changing the picked
/// currency triggers exactly one reload.
private struct TrendLoadKey: Equatable {
    let currency: String?
    let isExpanded: Bool
}
