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
/// Three groups rather than two. **Unavailable is its own section**, not a
/// dimmed pill among the available ones: a widget that cannot draw anything
/// yet is a different kind of thing from one the user has simply not picked,
/// and mixing them made the Available list look like it contained broken
/// entries.
struct SetupDashboardStep: View {
    let store: OnboardingDraftStore

    var body: some View {
        OnboardingScaffold(
            title: "Build your dashboard",
            subtitle: "Pick what you want to see.",
            step: .dashboard,
            onBack: store.goBack,
            onSkip: skip,
            isPrimaryEnabled: true,
            onPrimary: store.advance
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                chosenSection
                availableSection
                unavailableSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: store.draft.selectedMetrics)
            .task { pruneUnavailable() }
        }
    }

    // MARK: - Chosen

    private var chosen: [DashboardWidgetKind] { store.draft.selectedMetrics }

    @ViewBuilder
    private var chosenSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("On your dashboard")
                .font(AppTheme.Typography.rowTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            if chosen.isEmpty {
                // Not an error, and phrased so it does not read as one:
                // Skip commits Net Worth alone and the dashboard is
                // editable forever afterwards.
                Text("Nothing yet — tap one below.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            } else {
                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(chosen, id: \.self) { kind in
                        pill(kind.title, isSelected: true)
                            .onTapGesture { toggle(kind) }
                            .accessibilityLabel(kind.title)
                            .accessibilityAddTraits(.isSelected)
                            .accessibilityHint("Double tap to remove")
                    }
                }
            }
        }
    }

    // MARK: - Available

    private var available: [DashboardWidgetKind] {
        DashboardWidgetKind.allCases.filter {
            !chosen.contains($0) && capabilities.unavailability(for: $0) == nil
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Text("Available")
                    .font(AppTheme.Typography.rowTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(available, id: \.self) { kind in
                        pill(kind.title, isSelected: false)
                            .onTapGesture { toggle(kind) }
                            .accessibilityLabel(kind.title)
                            .accessibilityHint("Double tap to add")
                    }
                }
            }
        }
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
                Text("Not yet")
                    .font(AppTheme.Typography.rowTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(unavailable, id: \.kind) { entry in
                        pill(entry.kind.title, reason: entry.reason, isSelected: false)
                            .opacity(AppTheme.Opacity.dim)
                            .accessibilityLabel(entry.kind.title)
                            .accessibilityHint(entry.reason)
                    }
                }
            }
        }
    }

    // MARK: - The pill itself

    private func pill(_ title: String, reason: String? = nil, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            if let reason {
                Text(reason)
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
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
