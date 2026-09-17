import KeepoCore
import SwiftUI

/// Step 6 — which widgets the dashboard opens with, and in what order.
///
/// **Names, not pictures.** This screen used to render every option as the
/// real `DashboardWidgetView` against sample data, on the argument that a
/// mock-up promises something and the user should be choosing the thing
/// itself. What that actually produced was a screen-and-a-half of scrolling
/// through six live-looking cards — most of them showing invented numbers —
/// to answer a question as small as "do you want a net worth total?". The
/// pictures were the most prominent thing on a screen where they were the
/// least important: the user has not seen the dashboard yet, so a preview
/// of a widget teaches them nothing a name does not, and it cost the whole
/// screen to say it. A pill per widget asks the question at its actual size.
///
/// **The order is not the user's to set, and it should not have been.**
/// This step used to collect a sequence — tap order was layout order, with
/// a number on every chosen pill and drag-to-reorder between them. It asked
/// somebody who has never seen the dashboard to make a decision about it,
/// and it let them produce a grid with a hole in the middle. Now they
/// choose a set and `OnboardingDashboardPlan` arranges it at the commit,
/// which is the only place that has the finished selection to work from.
///
/// **One group of choices, not two.** Chosen and unchosen widgets used to
/// sit in separate labelled sections, which made picking one move it across
/// the screen — a list that rearranges itself under the finger is a list you
/// have to re-read after every tap. They are one set now, in catalogue
/// order, and selection is a state a pill is in rather than a section it
/// belongs to.
///
/// Unavailable widgets keep their own section, because they are a different
/// kind of thing: not "you have not picked this" but "this cannot say
/// anything yet". They are drawn on a filled surface at full opacity rather
/// than dimmed — a dimmed white pill on an off-white canvas was very close
/// to invisible, which is the wrong way to say "disabled".
struct SetupDashboardStep: View {
    let store: OnboardingDraftStore

    var body: some View {
        OnboardingScaffold(
            title: "Build your dashboard",
            subtitle: "Tap all metrics you're interested in",
            step: .dashboard,
            onBack: store.goBack,
            onSkip: skip,
            isPrimaryEnabled: true,
            // The pills are a list, and a list belongs under the words
            // introducing it. Floating left a band of empty canvas between
            // the subtitle and the first thing there is to tap.
            pinsContentToTop: true,
            contentGap: AppTheme.Spacing.l,
            onPrimary: store.advance
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                choicesSection
                unavailableSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: store.draft.selectedMetrics)
            .task { pruneUnavailable() }
        }
    }

    // MARK: - The choices

    private var chosen: [DashboardWidgetKind] { store.draft.selectedMetrics }

    /// **No heading.** The subtitle above already says what to do, and a
    /// label over the only interactive thing on the screen is a label for
    /// its own sake.
    private var choicesSection: some View {
        TagFlowLayout(spacing: AppTheme.Spacing.s) {
            ForEach(selectable, id: \.self) { kind in
                let isSelected = chosen.contains(kind)
                pill(kind.title, isSelected: isSelected)
                    .onTapGesture { toggle(kind) }
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint(isSelected ? "Double tap to remove" : "Double tap to add")
            }
        }
    }

    /// Catalogue order, always — including for the ones already chosen. A
    /// pill that jumps to a different place on the screen when tapped makes
    /// the next tap a search.
    private var selectable: [DashboardWidgetKind] {
        DashboardWidgetKind.allCases.filter { capabilities.unavailability(for: $0) == nil }
    }

    // MARK: - Unavailable

    private var unavailable: [(kind: DashboardWidgetKind, reason: String)] {
        DashboardWidgetKind.allCases.compactMap { kind in
            capabilities.unavailability(for: kind).map { (kind, $0) }
        }
    }

    /// Shown, never hidden. Hiding a widget that cannot draw anything yet
    /// makes the catalogue look shorter than it is and leaves the user
    /// wondering where a feature went; naming it with its reason answers the
    /// question before it is asked, and tells them what to do if they want
    /// it — add an investment account, add one in another currency.
    @ViewBuilder
    private var unavailableSection: some View {
        if !unavailable.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Text("Not available yet")
                    .font(AppTheme.Typography.rowTitle)
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(unavailable, id: \.kind) { entry in
                        pill(entry.kind.title, isSelected: false)
                            .onTapGesture { explain(entry.kind) }
                            .accessibilityLabel(entry.kind.title)
                            .accessibilityHint(entry.reason)
                    }
                }

                if let explained, let reason = capabilities.unavailability(for: explained) {
                    Text(reason)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - The pill itself

    private func pill(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(
                isSelected
                    ? AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.fill)
                    : AppTheme.Palette.bgSurface,
                in: Capsule()
            )
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(AppTheme.Palette.brandPrimary, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .animation(AppTheme.Motion.quick, value: isSelected)
    }

    /// **Ask, rather than annotate.** Each unavailable widget used to carry
    /// its reason inside the pill, which made them a different shape and a
    /// different size from every other pill on the screen — two rows of tall
    /// two-line blocks under a row of short ones, for an explanation most
    /// people do not need and nobody needs twice. They look like the rest
    /// now, and the reason appears under the group when one is tapped.
    ///
    /// The group's own heading is what says these cannot be chosen, so the
    /// pill does not have to look broken to say it.
    private func explain(_ kind: DashboardWidgetKind) {
        withAnimation(AppTheme.Motion.quick) {
            explained = explained == kind ? nil : kind
        }
    }

    // MARK: - State

    /// Which unavailable widget the user last asked about, if any.
    @State private var explained: DashboardWidgetKind?

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

    /// Still an array rather than a set, because `OnboardingDraft` persists
    /// it and an array's order is stable across encode/decode. Nothing reads
    /// that order any more — `OnboardingDashboardPlan` re-derives its own
    /// from the catalogue — so two users who pick the same widgets get the
    /// same dashboard whatever sequence they tapped them in.
    private func toggle(_ kind: DashboardWidgetKind) {
        store.update { draft in
            if let index = draft.selectedMetrics.firstIndex(of: kind) {
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

/// The one decision this step makes that is not about drawing: which
/// widgets a draft can actually support. A pure function of values, so it
/// is tested rather than looked at.
enum SetupDashboardLayout {
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
