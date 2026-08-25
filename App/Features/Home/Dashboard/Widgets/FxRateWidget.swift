import KeepoCore
import SwiftUI

/// FX Rate — 2×1 collapsed, 4×2 expanded.
///
/// What one unit of a currency the user actually holds is worth in their
/// base currency, over time. Collapsed: the pair, the rate, a
/// month-over-month badge, and the trajectory behind it. Expanded: the same
/// trajectory as the subject, scrollable and highlightable, with weekly
/// resolution available on top of monthly and yearly.
///
/// The rate is **not** read out of `fx_rates` and cross-multiplied here. It
/// comes from converting a single unit through `LocalMoneyConversion`, the
/// same path every balance on the dashboard is converted by — so the number
/// this widget draws is by construction the number the other widgets used,
/// including the EUR pivot and the rounding contract. A second
/// implementation would be free to disagree with the figures beside it.
struct FxRateWidget: View {
    let capabilities: DashboardCapabilities?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let context: SeriesWidgetState.Context?
    let onTap: () -> Void

    @State private var series = SeriesWidgetState(kind: .fxRate)

    /// Only currencies the user actually holds, never the base currency
    /// itself — a rate of one against one is not information.
    private var quotable: [String] { capabilities?.foreignCurrencies ?? [] }

    private var baseCode: String { currency?.code ?? "—" }

    var body: some View {
        SeriesWidgetChrome(
            kind: .fxRate, series: series, isExpanded: isExpanded, context: context, onTap: onTap
        ) {
            if quotable.isEmpty {
                WidgetEmptyState(
                    systemImage: "globe",
                    message: "Add an account in another currency to track a rate."
                )
            } else if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        // Picked once, when the widget first has something to pick from.
        // The largest holding would be a better default but costs a
        // conversion the collapsed tile hasn't paid for; alphabetical-first
        // is honest, stable, and one tap from anything else.
        .onChange(of: quotable, initial: true) { _, currencies in
            guard series.config.quoteCurrency == nil || !currencies.contains(series.config.quoteCurrency ?? "") else {
                return
            }
            series.config.quoteCurrency = currencies.first
        }
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 3) {
            pair
            // Captionless on the collapsed 2×1, for the same reason
            // `InvestingRatioWidget.collapsed` is: one grid column cannot
            // hold the pill and "vs last month avg" without truncating it.
            MetricHeadlineBlock(
                value: .rate(series.highlightedPoint?.value), size: 30,
                percentChange: series.percentChange
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            WidgetSparkline(points: series.points, color: trendColor, height: 44)
                .opacity(0.5)
                .padding(.horizontal, -WidgetStyle.padding)
        }
        // The collapsed tile still needs one window of data to draw its
        // rate and its trend. Loading it here rather than in the chrome —
        // which only loads while expanded — is the one place a collapsed
        // widget pays for a read, and it is a cheap one: a single FX walk
        // over the visible months, no balances.
        .task(id: collapsedKey) {
            guard !isExpanded, let context, series.config.quoteCurrency != nil else { return }
            await series.refresh(context)
        }
    }

    private var pair: some View {
        HStack(spacing: 4) {
            quotePicker
            Text("/")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            CurrencyBadge(code: currency?.code, diameter: 22)
        }
    }

    /// A menu rather than a segmented anything: the list is however many
    /// currencies the user holds, which is two for most people and could be
    /// a dozen. Bordered and background-less so it reads as the one thing on
    /// the tile you can change.
    private var quotePicker: some View {
        Menu {
            ForEach(quotable, id: \.self) { code in
                Button {
                    series.config.quoteCurrency = code
                } label: {
                    if code == series.config.quoteCurrency {
                        Label(code, systemImage: "checkmark")
                    } else {
                        Text(code)
                    }
                }
            }
        } label: {
            CurrencyBadge(code: series.config.quoteCurrency, diameter: 22)
                .padding(.leading, 3)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                .frame(minHeight: WidgetStyle.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded

    /// Pair on its own line, figure and badge on the next.
    ///
    /// All three on one row is what the first version did, and at this
    /// tile's width it truncated both ends at once — "E…" for the currency
    /// and "vs last month a…" for the caption. The badge's caption is the
    /// part that says *what the number is being compared to*, so losing it
    /// to an ellipsis costs more than the vertical line it takes to keep.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            pair
            MetricHeadlineBlock(
                value: .rate(series.highlightedPoint?.value), size: 28,
                percentChange: series.percentChange, caption: badgeCaption
            )
            SeriesChartOrMessage(series: series, color: trendColor)
        }
    }

    /// The movement across the visible stretch, not the highlighted bucket's
    /// own — see `NetWorthWidget.trendColor` for why the two differ.
    private var trendColor: Color {
        DashboardTrend.color(for: series.overallChange)
    }

    private var badgeCaption: String {
        series.isHighlightingPast
            ? TrendCaption.expanded(series.granularity, averaged: true)
            : TrendCaption.collapsed(series.granularity, averaged: true)
    }

    private var collapsedKey: FxCollapsedKey {
        FxCollapsedKey(
            quote: series.config.quoteCurrency, token: context?.token ?? 0, scope: context?.scope ?? .total
        )
    }
}

private struct FxCollapsedKey: Equatable {
    let quote: String?
    let token: Int
    let scope: PublicSchema.AccountScope
}
