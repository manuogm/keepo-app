import KeepoCore
import SwiftUI

/// Step 6 — the dashboard, chosen from pictures of working widgets rather
/// than from a list of names.
///
/// **Every tile here is the real widget**, rendered by the same
/// `DashboardWidgetView` the dashboard uses, against the same
/// `DashboardData.sample` the catalogue already previews from. A mock-up
/// would be promising something, and the whole argument for a long setup is
/// that the app is not empty on day one — so the user has to be choosing
/// the thing itself.
///
/// **The honest problem this screen has to handle: on day one every one of
/// these is nearly empty.** One account, no history, one currency — Net
/// Worth is a single point, Cashflow has no buckets, Upcoming has nothing.
/// A dashboard the user just "personalised" that renders five blank tiles
/// is worse than the seed it replaced. Two things answer that: the previews
/// are of sample data and say so, and a widget with genuinely nothing to
/// show carries the catalogue's own reason instead of being offered.
///
/// **Order is the hierarchy.** `DashboardStore.replace(kinds:)` appends in
/// selection order and `DashboardArrangement.append` fills the first free
/// slot in reading order, so the sequence of taps *is* the layout. That is
/// why the badge on a chosen widget is its index, and why this is an array
/// and never a set.
struct SetupDashboardStep: View {
    let store: OnboardingDraftStore

    /// The width the previews are sized from, measured rather than
    /// assumed.
    ///
    /// **Not a `GeometryReader` wrapped around the grid**, which is how
    /// this first shipped and why the last widget was clipped: a
    /// `GeometryReader` fills whatever it is given and reports that, so
    /// inside the scaffold's scroll view it needed an explicit height, and
    /// the height had to be guessed from a width nobody knew. Measuring in
    /// the background instead leaves the stack to size itself from its own
    /// children — which have exact frames — so there is no height to guess.
    @State private var availableWidth: CGFloat = 320

    var body: some View {
        OnboardingScaffold(
            title: "Build your dashboard",
            subtitle: "Tap them in the order you want them. They'll fill in as you use Keepo — "
                + "this is sample data.",
            step: .dashboard,
            onBack: store.goBack,
            onSkip: skip,
            isPrimaryEnabled: true,
            onPrimary: store.advance
        ) {
            // Two columns by construction (`DashboardLayout.columnCount`),
            // sized from the width actually available — so a half-width
            // widget here is half-width on the dashboard too.
            let geometry = DashboardGeometry(availableWidth: availableWidth)
            VStack(spacing: geometry.spacing) {
                ForEach(rows, id: \.first) { row in
                    HStack(alignment: .top, spacing: geometry.spacing) {
                        ForEach(row, id: \.self) { kind in
                            cell(kind, geometry: geometry)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            // Room for the order badges, which straddle each card's
            // top-right corner — without it the scroll view clips the
            // rightmost one in half.
            //
            // **Inside the `maxWidth` frame, not outside it.** Padding
            // applied after `.frame(maxWidth: .infinity)` is added to a
            // block that has already expanded to fill its container, so the
            // result is wider than the container and every card overhangs
            // the screen edge by exactly the inset.
            .padding(.top, AppTheme.Spacing.s)
            .padding(.trailing, AppTheme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    // Minus the trailing inset above, so the previews are
                    // sized from the room they actually get.
                    Color.clear.preference(
                        key: GridWidthKey.self, value: proxy.size.width - AppTheme.Spacing.s
                    )
                }
            }
            .onPreferenceChange(GridWidthKey.self) { measured in
                guard measured > 0 else { return }
                availableWidth = measured
            }
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: store.draft.selectedMetrics)
            .task { pruneUnavailable() }
        }
    }

    // MARK: - Packing

    private var rows: [[DashboardWidgetKind]] { SetupDashboardLayout.rows }

    // MARK: - A cell

    @ViewBuilder
    private func cell(_ kind: DashboardWidgetKind, geometry: DashboardGeometry) -> some View {
        let size = geometry.size(rows: kind.baseSize.rows, columns: kind.baseSize.columns)
        let reason = capabilities.unavailability(for: kind)
        let index = store.draft.selectedMetrics.firstIndex(of: kind)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack(alignment: .topTrailing) {
                DashboardWidgetView(kind: kind, data: .sample)
                    .frame(width: size.width, height: size.height)
                    // A picture of a widget, not a widget: its own controls
                    // would invite interaction that goes nowhere, and would
                    // compete with the tap that actually selects it.
                    .allowsHitTesting(false)
                    .opacity(reason == nil ? 1 : AppTheme.Opacity.dim)
                    .saturation(reason == nil ? 1 : 0)
                    .overlay {
                        if index != nil {
                            RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                                .strokeBorder(AppTheme.Palette.brandPrimary, lineWidth: 2)
                        }
                    }
                if let index {
                    orderBadge(index + 1)
                }
            }
            if let reason {
                Text(reason)
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
                    .frame(width: size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if reason == nil { toggle(kind) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(index.map { "Chosen, number \($0 + 1)" } ?? "Not chosen")
        .accessibilityHint(reason ?? "")
        .accessibilityAddTraits(index != nil ? .isSelected : [])
    }

    /// The position this widget will take, not a tick. A checkmark would
    /// say "chosen" and lose the only other thing the user decided here.
    ///
    /// **Straddling the corner rather than sitting inside it.** Inside, it
    /// landed on whatever the widget's own header already had there — on
    /// Cashflow, directly over its "Last month" chip, which made a picture
    /// of a control look like a control with a badge on it. Every position
    /// inside the card overlaps *something*, because these are real
    /// widgets; outside it overlaps nothing by construction. The
    /// canvas-coloured ring is what keeps it legible where it crosses the
    /// card's own edge, the same trick `AvatarButton`'s camera badge uses.
    private func orderBadge(_ position: Int) -> some View {
        Text(verbatim: "\(position)")
            .font(AppTheme.Typography.captionEmphasis)
            .monospacedDigit()
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
            .background(AppTheme.Palette.brandPrimary, in: Circle())
            .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
            .offset(x: AppTheme.Spacing.xs, y: -AppTheme.Spacing.xs)
    }

    // MARK: - State

    private var capabilities: DashboardCapabilities {
        DashboardCapabilities(onboarding: store.draft)
    }

    /// Going Back and changing the account can take a widget's data away
    /// underneath a selection already made — an investment account switched
    /// to Everyday strands Investing Ratio as chosen-but-impossible, and it
    /// would commit as a permanently dead tile.
    private func pruneUnavailable() {
        let kept = SetupDashboardLayout.pruned(store.draft.selectedMetrics, capabilities: capabilities)
        guard kept != store.draft.selectedMetrics else { return }
        store.update { $0.selectedMetrics = kept }
    }

    private func toggle(_ kind: DashboardWidgetKind) {
        store.update { draft in
            if let index = draft.selectedMetrics.firstIndex(of: kind) {
                // Removing renumbers everything after it, which is the
                // point of showing positions rather than ticks.
                draft.selectedMetrics.remove(at: index)
            } else {
                draft.selectedMetrics.append(kind)
            }
        }
    }

    /// Skip leaves the dashboard at `DashboardStore.seed` — Net Worth
    /// alone, which is what Home led with before the dashboard existed, so
    /// skipping loses nothing rather than producing an empty grid.
    private func skip() {
        store.update { $0.selectedMetrics = [.netWorth] }
        store.advance()
    }
}

private struct GridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The two decisions this step makes that are not about drawing: how the
/// six widgets pack into rows, and which of them a draft can actually
/// support. Both are pure functions of values, so both are tested rather
/// than looked at.
enum SetupDashboardLayout {
    /// The rows the six widgets fall into, worked out by
    /// `DashboardArrangement` itself rather than by a rule copied from it —
    /// three of them are full width and three are half, and which pairs up
    /// with which is exactly the packing the dashboard will do when these
    /// are committed.
    static var rows: [[DashboardWidgetKind]] {
        var arrangement = DashboardArrangement(tiles: [])
        for kind in DashboardWidgetKind.allCases {
            _ = arrangement.append(kind: kind)
        }
        return Dictionary(grouping: arrangement.tiles, by: \.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.column < $1.column }.map(\.kind) }
    }

    /// Drops any selection the draft can no longer support, **keeping the
    /// order of the rest** — the order is the dashboard's layout, so a
    /// prune that re-sorted would silently rearrange widgets the user
    /// placed deliberately.
    static func pruned(
        _ metrics: [DashboardWidgetKind], capabilities: DashboardCapabilities
    ) -> [DashboardWidgetKind] {
        metrics.filter { capabilities.unavailability(for: $0) == nil }
    }
}

extension DashboardCapabilities {
    /// Derived from the **draft**, not the database: nothing has been
    /// committed yet, so the only account that exists is the one the user
    /// described two steps ago. Answering "can this widget say anything?"
    /// from the mirror would answer it about an account that isn't there —
    /// and on a fresh signup the mirror holds none at all, which would grey
    /// out every widget that depends on one.
    init(onboarding draft: OnboardingDraft) {
        let account = draft.account
        self.init(
            hasInvestmentAccounts: account?.kind == .investment,
            // The one account the user has described, when it is not in the
            // currency they think in — which is exactly what the FX widget
            // would quote.
            foreignCurrencies: [account?.currency]
                .compactMap { $0 }
                .filter { $0 != draft.baseCurrency }
        )
    }
}
