import KeepoCore
import SwiftUI

/// What a widget's headline figure *is*. One type rather than each widget
/// formatting its own, because "—" for an uncomputable value (money rule 5)
/// has to be the same decision everywhere — a widget that rendered `0%`
/// where another rendered `—` would be telling the user something false in
/// the one case that matters most.
enum MetricValue: Equatable {
    /// Signed minor units, formatted through `MoneyFormatter`.
    case money(Int64?, CurrencyInfo?)
    /// A ratio in 0…1, shown as a whole-number percentage.
    case percent(Double?)
    /// An exchange rate, which needs more decimals than money does — a rate
    /// rounded to two would show every EUR/USD move as no move at all.
    case rate(Double?, fractionDigits: Int = 4)
}

/// The number a widget is actually about — the one thing in the tile the
/// user is meant to read first.
///
/// The size shrinks when the widget expands, because the chart becomes the
/// subject and the headline becomes its caption. It is a plain font-size
/// change rather than a `scaleEffect`: the size participates in layout (the
/// expanded tile genuinely needs the vertical space back), and SwiftUI
/// cross-fades the two renderings inside the expansion animation, which is
/// the smooth transition the design asks for.
struct MetricHeadline: View {
    let value: MetricValue
    var size: CGFloat = WidgetStyle.metric
    var signStyle: MoneySignStyle = .standard
    /// Money only: the full figure rather than the short form. Set by a
    /// `FigureFit`, never decided here — see `FittingFigure`.
    var exact = false

    var body: some View {
        content
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var content: some View {
        switch value {
        case .money(let amountE4, let currency):
            // Delegated rather than reimplemented: this is where the
            // big-whole/small-fraction weighting and privacy mode live.
            BalanceHeaderView(
                amount: amountE4, currency: currency, size: size, signStyle: signStyle, exact: exact
            )
        case .percent(let ratio):
            text(ratio.map { $0.formatted(.percent.precision(.fractionLength(0))) })
        case .rate(let rate, let digits):
            text(rate.map { $0.formatted(.number.precision(.fractionLength(digits))) })
        }
    }

    /// The non-money branches still honour privacy mode — an FX rate is not
    /// a balance, but an investing ratio next to a hidden net worth would
    /// leak the shape of it.
    private func text(_ string: String?) -> some View {
        PrivateText(string ?? "—")
            .numberFont(size)
            .foregroundStyle(AppTheme.Palette.textPrimary)
    }
}

/// A widget's headline figure with its trend badge underneath.
///
/// One view rather than each widget stacking the two itself, because the
/// badge's **position** is the thing that has to be identical: laid out
/// per-widget it drifted into an `HStack` beside the figure when the tile
/// expanded, so the badge jumped sideways mid-animation and the eye lost the
/// number it had been reading. Below the figure, always — collapsed,
/// expanded, every widget.
///
/// `adjacent` is for what legitimately belongs on the figure's own line and
/// is not the trend: Investing Ratio's drivers chevron and the figures it
/// opens. It is drawn **immediately after the figure**, before the `Spacer`,
/// because a control that acts on the number has to look attached to it — at
/// the far end of a full-width tile the chevron sat 200 points from the
/// percentage it belonged to and read as part of the card's chrome. It still
/// cannot push the badge anywhere: the badge is on the next row of the
/// `VStack`, not in this `HStack`.
///
/// `fitsExact` is for an expanded widget: a money figure is shown in full
/// when its line has the room, short with a chevron when not
/// (`FittingFigure`). Collapsed tiles leave it off and stay short.
struct MetricHeadlineBlock<Adjacent: View>: View {
    let value: MetricValue
    var size: CGFloat = WidgetStyle.metric
    var signStyle: MoneySignStyle = .standard
    var fitsExact = false
    var percentChange: Double?
    var unit: String = "%"
    var caption: String?
    @ViewBuilder var adjacent: () -> Adjacent

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if fitsExact, case .money = value {
                FittingFigure { fit in headlineRow(fit) }
            } else {
                headlineRow(nil)
            }
            WidgetTrendBadge(percentChange: percentChange, unit: unit, caption: caption)
        }
    }

    private func headlineRow(_ fit: FigureFit?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
            MetricHeadline(value: value, size: size, signStyle: signStyle, exact: fit?.showsExact ?? false)
            if let fit {
                FigureFitToggle(fit: fit)
            }
            if fit?.clearsLine != true {
                adjacent()
            }
            Spacer(minLength: 0)
        }
    }
}

extension MetricHeadlineBlock where Adjacent == EmptyView {
    init(
        value: MetricValue,
        size: CGFloat = WidgetStyle.metric,
        signStyle: MoneySignStyle = .standard,
        fitsExact: Bool = false,
        percentChange: Double?,
        unit: String = "%",
        caption: String? = nil
    ) {
        self.init(
            value: value, size: size, signStyle: signStyle, fitsExact: fitsExact,
            percentChange: percentChange, unit: unit, caption: caption
        ) { EmptyView() }
    }
}

/// The caption under a trend badge, phrased for where it appears.
///
/// Collapsed, a widget compares against the previous period and says so in
/// the shortest form ("vs last month"). Expanded, once the user has
/// highlighted a bucket, the comparison is against *that* bucket's
/// predecessor — so the caption becomes explicit ("vs previous month"),
/// because "last" would now be ambiguous about which one.
enum TrendCaption {
    static func collapsed(_ granularity: MetricGranularity, averaged: Bool = false) -> String {
        averaged ? "vs last \(granularity.noun) avg" : "vs last \(granularity.noun)"
    }

    static func expanded(_ granularity: MetricGranularity, averaged: Bool = false) -> String {
        averaged ? "vs prev. \(granularity.noun) average" : "vs previous \(granularity.noun)"
    }
}
