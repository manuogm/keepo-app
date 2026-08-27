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
    /// The base-currency note. Optional so the catalogue — which draws this
    /// widget with no tab bar above it — renders rather than traps.
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @State private var isShowingBaseNote = false

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
        // **Re-picked whenever the current choice stops being valid**, which
        // includes having no choice at all.
        //
        // Keyed on the list alone, this fired once at launch and never again
        // — and collapsing the widget calls `reset()`, which restores the
        // kind's default config, and that config has no currency in it. So
        // the tile came back from its first expansion showing a globe and a
        // dash, with nothing left that could ever put a currency back.
        // Keying on the choice as well means the reset is a change this can
        // see. Assigning here re-fires it once more, and the guard then
        // passes, so there is no loop.
        //
        // The largest holding would be a better default but costs a
        // conversion the collapsed tile hasn't paid for; alphabetical-first
        // is honest, stable, and one tap from anything else.
        .onChange(of: quoteSelection, initial: true) { _, selection in
            guard selection.picked == nil || !selection.available.contains(selection.picked ?? "") else { return }
            series.config.quoteCurrency = selection.available.first
        }
    }

    // MARK: - Collapsed

    /// **No trend badge here**, unlike every other collapsed tile.
    ///
    /// This one carries a pair of currency badges above the figure already,
    /// and a pill under it made three stacked objects in a 2×1 — the tile
    /// stopped reading as "a rate" and started reading as a list. The rate
    /// is also the one figure on the dashboard whose period-over-period
    /// move is the least interesting thing about it: what a user opens this
    /// tile for is the number itself. The badge returns the moment the
    /// widget is expanded, where there is room for it and a chart for it to
    /// describe.
    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 4) {
            pair
            MetricHeadline(value: .rate(series.highlightedPoint?.value), size: WidgetStyle.metric)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            WidgetSparkline(points: series.points, color: trendColor, height: 44)
                .opacity(0.5)
                .padding(.horizontal, -WidgetStyle.padding)
        }
        // The rate has four decimal places and the trajectory runs under all
        // of them; without the wash a line crossing "1.0847" at the wrong
        // angle costs the reader a digit.
        .metricLegibilityScrim()
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

    /// Quote, slash, base — the order the number is read in. `EUR / USD` at
    /// 1.1654 means one euro buys 1.1654 dollars, so the pair has to be
    /// written the same way round as the figure under it.
    ///
    /// The slash is `.title3` rather than `.caption`, with real air either
    /// side. It is the only thing on the row saying these two currencies are
    /// a *ratio* and not a list, and at caption size between two 22pt discs
    /// it read as a stray mark.
    private var pair: some View {
        HStack(spacing: 8) {
            quotePicker
            Text("/")
                .font(.title3)
                .foregroundStyle(Color.secondary)
            basePill
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
                .currencyPill(stroke: Color.secondary.opacity(0.4))
                .hitTarget()
        }
        .buttonStyle(.plain)
        // **The pill must not animate.** Picking a currency changes the
        // config, which re-keys the collapsed load — and that load runs
        // inside whatever transaction the dashboard has open, so the pill
        // was being carried along by it: it re-laid out over about a second,
        // clipped at both ends while it went. Nothing about a label swapping
        // three letters for three others should move, so this pill opts out
        // of every animation around it.
        .transaction { $0.animation = nil }
    }

    /// The base currency, drawn as a pill that is deliberately **not** a
    /// choice.
    ///
    /// A bare badge beside a bordered one read as an oversight — two
    /// currencies, one of them apparently tappable for no stated reason. The
    /// same capsule at a lighter weight says "same kind of thing, fixed",
    /// and it still answers a tap, because the question a fixed control
    /// invites is "why can't I change this?".
    private var basePill: some View {
        Button {
            isShowingBaseNote = true
        } label: {
            CurrencyBadge(code: currency?.code, diameter: 22)
                .opacity(0.6)
                .currencyPill(stroke: Color.secondary.opacity(0.18))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(currency?.code ?? "Base currency"), your base currency")
        .popover(isPresented: $isShowingBaseNote) { baseNote }
    }

    /// Why the base currency can't be picked here, and where it can.
    ///
    /// A popover rather than a sheet: the answer is one line about the pill
    /// that was just tapped, and it belongs beside it.
    /// `presentationCompactAdaptation(.popover)` is what stops iPhone
    /// promoting it into a half-height sheet, which would cover the widget
    /// the question is about.
    ///
    /// Deliberately two lines and no prose. The first draft explained *why*
    /// every figure converts into this currency — true, and not what someone
    /// tapping a greyed-out control is asking. They want to know it is
    /// deliberate and where to change it.
    ///
    /// `fixedSize` rather than a width: with nothing to wrap, the content has
    /// one honest size and the popover can take it. Given a `maxWidth`
    /// instead, the bubble sized itself from the first measuring pass and the
    /// text then ran out of the top and bottom of it.
    private var baseNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "Base currency", the exact words Preferences uses for the
            // row this links to. One name for one thing: a popover that
            // said "default" and a settings screen that said "base" would
            // read as two different settings.
            Text("\(currency?.code ?? "—") is your base currency")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            Button {
                isShowingBaseNote = false
                navigation?.openProfile(.preferences)
            } label: {
                // The chevron is the promise that this pushes a screen
                // rather than opening another layer on top of this one.
                HStack(spacing: 4) {
                    Text("Go to settings")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(navigation == nil)
        }
        .padding(16)
        .fixedSize()
        .presentationCompactAdaptation(.popover)
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
        VStack(alignment: .leading, spacing: 8) {
            pair
            MetricHeadlineBlock(
                value: .rate(series.highlightedPoint?.value), size: WidgetStyle.metricExpanded,
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

    private var quoteSelection: FxQuoteSelection {
        FxQuoteSelection(available: quotable, picked: series.config.quoteCurrency)
    }

    private var collapsedKey: FxCollapsedKey {
        FxCollapsedKey(
            quote: series.config.quoteCurrency, token: context?.token ?? 0, scope: context?.scope ?? .total
        )
    }
}

/// The two halves of "is the picked currency still a valid pick" — what the
/// list offers and what is currently chosen. One `Equatable` value so a
/// change to *either* re-runs the default pick.
private struct FxQuoteSelection: Equatable {
    let available: [String]
    let picked: String?
}

/// The pill both currencies are drawn in. One modifier rather than two call
/// sites, because the whole point of the base pill is that it is the same
/// shape as the one beside it — laid out separately they drifted by a point
/// of padding and read as two different controls.
private struct CurrencyPill: ViewModifier {
    let stroke: Color

    func body(content: Content) -> some View {
        content
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

private extension View {
    func currencyPill(stroke: Color) -> some View { modifier(CurrencyPill(stroke: stroke)) }
}

private struct FxCollapsedKey: Equatable {
    let quote: String?
    let token: Int
    let scope: PublicSchema.AccountScope
}
