import KeepoCore
import SwiftUI

/// Currency Exposure — 2×1 collapsed, 4×2 expanded.
///
/// Collapsed: which currency most of the money sits in, how much of it, and a
/// bar showing the rest of the split. Expanded: every currency as its own
/// tile, each one openable into the accounts that make it up — drawn in the
/// colours the user picked for those accounts, so a row is recognisable
/// before its name is read.
///
/// The donut this widget used to be is gone deliberately. A donut answers
/// "what share", and only that; the tile answers "what share, how much, and
/// which accounts", which is the question someone holding four currencies
/// actually has.
///
/// Every currency is drawn in a **shade of one colour**, ranked by size
/// (`WidgetPalette.shade`), rather than in a hue of its own. Four unrelated
/// hues on a 2×1 read as four categories; a single-hue ramp says the one
/// thing the bar is actually claiming, which is that this currency is bigger
/// than that one. The user's own account colours are still used — but only
/// inside a currency, once it has been opened, where the question really is
/// "which of *these* accounts".
struct CurrencyExposureWidget: View {
    let metrics: CurrencyExposureMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let onTap: () -> Void

    /// Which currency tiles are open. Reset on collapse, like every other
    /// widget's transient state — a widget always opens in a known state.
    ///
    /// Internal rather than `private` because the expanded half of this
    /// widget lives in `CurrencyExposureWidget+Expanded.swift`, and a
    /// `private` member is not visible to an extension in another file.
    @State var openCurrencies: Set<String> = []

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.currencyExposure.title,
            guide: isExpanded ? DashboardWidgetKind.currencyExposure.guide : nil,
            onTap: onTap
        ) {
            content
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { openCurrencies = [] }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let metrics, metrics.slices == nil {
            // Distinct from "no accounts": we know there is money, we just
            // can't price it. Saying so beats a breakdown drawn from a partial
            // denominator, where every share would be wrong (money rule 5).
            WidgetEmptyState(
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                message: "Exchange rates are still catching up."
            )
        } else if let metrics, !(metrics.slices ?? []).isEmpty {
            if isExpanded {
                expanded(metrics)
            } else {
                collapsed(metrics)
            }
        } else {
            WidgetEmptyState(
                systemImage: "banknote",
                message: "No balances to break down yet."
            )
        }
    }

    // MARK: - Collapsed

    /// The dominant currency as the subject, the minority ones as a small row
    /// of flags, and the whole split as a bar along the bottom.
    ///
    /// A 2×1 tile is a square about 130pt wide inside its padding, which is
    /// three short rows at most. Listing every currency in it would either
    /// truncate at an arbitrary number or shrink the type past reading size,
    /// so one figure leads and the row below names as many of the rest as
    /// will honestly fit — the expanded tile is where the full list lives.
    private func collapsed(_ metrics: CurrencyExposureMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CurrencyBadge(code: metrics.largest?.currency, diameter: 26)
            MetricHeadline(value: .percent(metrics.largestShare), size: WidgetStyle.metric)
            Spacer(minLength: 0)
            // The gap under the minority row is deliberately wider than the
            // stack's own: the row and the bar are both about the split, so
            // with 4 points between them they read as one block and the row
            // looked like a label *on* the bar rather than a list beside it.
            minorRow(minorCurrencies(metrics))
                .padding(.bottom, 6)
            // Along the bottom edge, under everything it explains.
            WidgetFillBar(segments: shareSegments(metrics), thickness: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Every held currency as one stacked bar, darkest first. Net-short
    /// currencies are absent rather than drawn as an outline here: at this
    /// size the bar is a shape, not a legend, and a dashed sliver a few points
    /// wide reads as a rendering artefact.
    private func shareSegments(_ metrics: CurrencyExposureMetrics) -> [FillSegment] {
        metrics.positiveSlices.enumerated().compactMap { rank, slice in
            guard let share = metrics.share(of: slice) else { return nil }
            return FillSegment(id: slice.currency, share: share, color: WidgetPalette.shade(rank: rank))
        }
    }

    /// One entry in the minority row: a currency, or the roll-up standing for
    /// all the ones that wouldn't fit.
    private struct MinorCurrency: Identifiable {
        let id: String
        /// `nil` draws the roll-up's globe rather than a flag.
        let code: String?
        let label: String?
        let share: Double?
    }

    /// Everything except the headline currency, named where there is room and
    /// rolled up where there isn't.
    ///
    /// One currency shows nothing at all — a row saying "and no others" is
    /// noise. Two or three fit as themselves. Past that the last slot becomes
    /// "REST", carrying the *combined* share of everything it stands for, so
    /// the row's percentages still add up with the headline's rather than
    /// trailing off into an unaccounted remainder.
    private func minorCurrencies(_ metrics: CurrencyExposureMetrics) -> [MinorCurrency] {
        let rest = Array(metrics.positiveSlices.dropFirst())
        guard !rest.isEmpty else { return [] }
        guard rest.count > 2 else {
            return rest.map {
                MinorCurrency(id: $0.currency, code: $0.currency, label: nil, share: metrics.share(of: $0))
            }
        }
        let second = rest[0]
        return [
            MinorCurrency(
                id: second.currency, code: second.currency, label: nil, share: metrics.share(of: second)
            ),
            MinorCurrency(
                id: "rest", code: nil, label: "REST",
                share: metrics.share(ofCombined: Array(rest.dropFirst()))
            )
        ]
    }

    /// Deliberately much smaller than the headline. These are the currencies
    /// the user holds *least* of, and a row that competed with the figure
    /// above it would say the opposite of what it means.
    ///
    /// **The row sizes itself to how many entries it holds**, because the
    /// tile does not grow to match. A 2×1 leaves about 144 points of width,
    /// and each entry is a disc, a three-letter code and a percentage — one
    /// of those has room to be comfortable, two do not. Sized for one at
    /// both counts, the second entry's percentage truncated to an ellipsis,
    /// and a figure drawn as "…" is worse than the same figure drawn small.
    ///
    /// The disc is the part that has to step down rather than the type: it
    /// is the only element `minimumScaleFactor` cannot shrink, so at a fixed
    /// diameter every point it takes comes out of the numbers.
    @ViewBuilder
    private func minorRow(_ entries: [MinorCurrency]) -> some View {
        if !entries.isEmpty {
            let isCrowded = entries.count > 1
            HStack(spacing: isCrowded ? 4 : 8) {
                ForEach(entries) { entry in
                    HStack(spacing: isCrowded ? 3 : 4) {
                        CurrencyBadge(code: entry.code, diameter: isCrowded ? 18 : 24, label: entry.label)
                        Text(shareLabel(entry.share))
                            .font(isCrowded ? .caption2 : .caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Formatting

    /// Money rule 5's shape, applied to a ratio: an unresolvable share is
    /// "—", never 0%.
    func shareLabel(_ share: Double?) -> String {
        guard let share else { return "—" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The base-currency figure that a native one converts to, or nothing
    /// when the two are the same money.
    func convertedLabel(_ amountBaseE4: Int64, from native: CurrencyInfo) -> String? {
        guard let currency, native.code != currency.code else { return nil }
        return MoneyFormatter.compact(amountBaseE4, currency: currency)
    }

    /// The unabbreviated figure, for VoiceOver. A screen reader has no width
    /// to run out of, so it gets the cents the visible row gives up.
    func exactLabel(_ amountE4: Int64, in native: CurrencyInfo) -> String {
        MoneyFormatter.format(amountE4, currency: native)
    }
}
