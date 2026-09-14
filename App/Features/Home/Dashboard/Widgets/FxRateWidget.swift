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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            pair
            MetricHeadline(value: .rate(series.highlightedPoint?.value), size: WidgetStyle.metric)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            WidgetSparkline(points: series.points, color: trendColor, height: 44)
                .opacity(AppTheme.Opacity.muted)
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

    /// Both FX pills draw their code at one width — see `CurrencyBadge`'s
    /// `codeWidth`. Wide enough for the widest code in the supported set
    /// (`MXN`), and scaled so three letters still fit at larger Dynamic Type
    /// sizes. Two of them, because the pair is drawn at two scales — see
    /// `PairScale`.
    @ScaledMetric(relativeTo: .subheadline) private var codeWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var compactCodeWidth: CGFloat = 30

    /// The pair is a heading on an expanded tile and a label on a collapsed
    /// one, and is sized accordingly — `PairScale` has the measurements.
    private var scale: PairScale { isExpanded ? .full : .compact }

    private var pairCodeWidth: CGFloat { isExpanded ? codeWidth : compactCodeWidth }

    /// Quote, slash, base — the order the number is read in. `EUR / USD` at
    /// 1.1654 means one euro buys 1.1654 dollars, so the pair has to be
    /// written the same way round as the figure under it.
    ///
    /// The slash is a size up from the codes beside it, with real air either
    /// side. It is the only thing on the row saying these two currencies are
    /// a *ratio* and not a list, and level with them it read as a stray mark.
    /// It steps down with the rest of the row rather than keeping a heading's
    /// size over caption-sized pills.
    private var pair: some View {
        HStack(spacing: scale.spacing) {
            quotePicker
            Text("/")
                .font(scale.slashFont)
                .foregroundStyle(AppTheme.Palette.textSecondary)
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
            CurrencyBadge(
                code: series.config.quoteCurrency, diameter: scale.diameter,
                codeWidth: pairCodeWidth, codeFont: scale.codeFont
            )
            .currencyPill(stroke: AppTheme.Palette.fillStrong, trailing: scale.pillTrailing)
            .hitTarget()
            // See `basePill` for why both pills take their ideal width.
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        // **The pill must not animate.** Picking a currency changes the
        // config, which re-keys the collapsed load — and that load runs
        // inside whatever transaction the dashboard has open, so the pill
        // was being carried along by it: it re-laid out over about a second,
        // clipped at both ends while it went. Nothing about a label swapping
        // three letters for three others should move, so this pill opts out
        // of every animation around it.
        //
        // **This shortens the distortion; it does not remove it.** The
        // comment above used to imply otherwise, and the clipping was still
        // visible (briefer) with only the transaction suppressed. The rest
        // of it is UIKit's, not ours — see
        // `TransactionsListView.pillLabel`'s note, which traced the same
        // artifact frame by frame on the filter pills.
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
            CurrencyBadge(
                code: currency?.code, diameter: scale.diameter,
                codeWidth: pairCodeWidth, codeFont: scale.codeFont
            )
            .opacity(AppTheme.Opacity.muted)
            .currencyPill(stroke: AppTheme.Palette.fillStrong, trailing: scale.pillTrailing)
            .hitTarget()
            // Both pills report their own ideal width rather than
            // accepting a proposal, so the host measures them once. See
            // `TransactionsListView.pillLabel` for the artifact this
            // helps with and for what it cannot fix.
            .fixedSize(horizontal: true, vertical: false)
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            // "Base currency", the exact words Profile uses for the row
            // this links to. One name for one thing: a popover that said
            // "default" and a settings screen that said "base" would read as
            // two different settings. It opens Profile's root rather than
            // pushing a screen, because that is where the row now lives.
            Text("\(currency?.code ?? "—") is your base currency")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Button {
                isShowingBaseNote = false
                navigation?.openProfileRoot()
            } label: {
                // The chevron is the promise that this pushes a screen
                // rather than opening another layer on top of this one.
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("Go to settings")
                    Image(systemName: "chevron.right")
                        .font(AppTheme.Typography.nanoEmphasis)
                }
                .font(AppTheme.Typography.labelEmphasis)
            }
            .buttonStyle(.plain)
            .disabled(navigation == nil)
        }
        .padding(AppTheme.Spacing.l)
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
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

/// How large the pair is drawn. **The collapsed tile cannot carry the full
/// size and never could** — this is the difference, in one place, rather
/// than five ternaries scattered down the pills.
///
/// A 2×1 tile has 133–147pt inside its padding, depending on the device.
/// Two `Size.glyph` pills with a three-letter code apiece, a title3 slash
/// and the air either side of it need about 170. The row was within a point
/// of the card's edge when the discs were 22pt and each code hugged its own
/// letters; rounding the disc up to the `Size.glyph` token and then pinning
/// the codes to one width (both of which were right for their own reasons)
/// pushed it 23pt over, so the base pill was drawn through the card's right
/// edge and the slash — the one mark saying these two are a *ratio* — was
/// squeezed away to nothing.
///
/// So the collapsed pair drops to caption scale, which is what it actually
/// is on that tile: a label over the figure, not a control row. Expanded
/// keeps the full size, where a 4×2 has ~340pt and the pair is a heading
/// above a chart.
///
/// **Check a change to these numbers at 375pt**, the narrowest iPhone on
/// iOS 18, and not at whatever device is attached — a row that fits a 402pt
/// Pro says nothing about the one it has to fit. Compact measures ~129pt
/// against the 133.5pt an SE's tile gives it, which is the whole of the
/// margin there is.
private struct PairScale {
    let diameter: CGFloat
    /// `nil` lets `CurrencyBadge` size the code off the disc, which is right
    /// at full size and far too small at 16pt — hence a type token here.
    let codeFont: Font?
    let slashFont: Font
    /// Between the pills and the slash, and inside each pill after its code.
    /// The leading inset is the disc's own and never changes.
    let spacing: CGFloat
    let pillTrailing: CGFloat

    static let full = PairScale(
        diameter: AppTheme.Size.glyph,
        codeFont: nil,
        slashFont: AppTheme.Typography.cardTitle,
        spacing: AppTheme.Spacing.s,
        pillTrailing: AppTheme.Spacing.s
    )

    static let compact = PairScale(
        diameter: AppTheme.Size.glyphSmall,
        codeFont: AppTheme.Typography.microEmphasis,
        slashFont: AppTheme.Typography.labelEmphasis,
        spacing: AppTheme.Spacing.xs,
        pillTrailing: AppTheme.Spacing.xs
    )
}

/// The pill both currencies are drawn in. One modifier rather than two call
/// sites, because the whole point of the base pill is that it is the same
/// shape as the one beside it — laid out separately they drifted by a point
/// of padding and read as two different controls.
private struct CurrencyPill: ViewModifier {
    let stroke: Color
    let trailing: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, AppTheme.Spacing.xs)
            .padding(.trailing, trailing)
            .padding(.vertical, AppTheme.Spacing.xs)
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

private extension View {
    func currencyPill(stroke: Color, trailing: CGFloat) -> some View {
        modifier(CurrencyPill(stroke: stroke, trailing: trailing))
    }
}

private struct FxCollapsedKey: Equatable {
    let quote: String?
    let token: Int
    let scope: PublicSchema.AccountScope
}
