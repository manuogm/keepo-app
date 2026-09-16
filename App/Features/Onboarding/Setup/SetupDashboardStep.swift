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
/// **Order is the hierarchy, and Keepo may still overrule it.**
/// `DashboardStore.replace(kinds:)` appends in this order and
/// `DashboardArrangement.append` puts each tile in the first free slot in
/// reading order — so a half-width widget will happily slide up beside an
/// earlier one rather than leave a hole in the grid. A complete dashboard
/// beats a literal reading of the order.
///
/// That is deliberately **not** explained on screen. A line warning that
/// the order might not be honoured spends the user's attention on a
/// discrepancy most of them will never notice — the packer only reorders
/// when the alternative is a visible gap — and the dashboard is drag-
/// rearrangeable the moment they reach it.
struct SetupDashboardStep: View {
    let store: OnboardingDraftStore

    var body: some View {
        OnboardingScaffold(
            title: "Build your dashboard",
            subtitle: "Pick what you want to see. Drag to set the order.",
            step: .dashboard,
            onBack: store.goBack,
            onSkip: skip,
            isPrimaryEnabled: true,
            onPrimary: store.advance
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                chosenSection
                availableSection
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
                        chosenPill(kind)
                    }
                }
            }
        }
    }

    /// Carries its position rather than a tick: the number *is* the second
    /// decision this screen collects, and a checkmark would throw it away.
    private func chosenPill(_ kind: DashboardWidgetKind) -> some View {
        let position = (chosen.firstIndex(of: kind) ?? 0) + 1
        return pill(kind.title, position: position, isSelected: true)
            .onTapGesture { toggle(kind) }
            // The raw value, because it is already the stable identity this
            // enum persists under — inventing a Transferable wrapper for a
            // string that crosses four points of screen would be machinery
            // for its own sake.
            .draggable(kind.rawValue) {
                pill(kind.title, position: position, isSelected: true)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let moved = DashboardWidgetKind(rawValue: raw) else { return false }
                move(moved, before: kind)
                return true
            }
            .accessibilityLabel(kind.title)
            .accessibilityValue("Position \(position)")
            .accessibilityAddTraits(.isSelected)
            .accessibilityHint("Double tap to remove")
    }

    // MARK: - Available

    private var available: [DashboardWidgetKind] {
        DashboardWidgetKind.allCases.filter { !chosen.contains($0) }
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
                        availablePill(kind)
                    }
                }
            }
        }
    }

    /// A widget with nothing to draw is shown and disabled rather than
    /// hidden. Hiding it makes the catalogue look shorter than it is and
    /// leaves the user wondering where a feature went; showing it with its
    /// reason answers the question before it is asked.
    private func availablePill(_ kind: DashboardWidgetKind) -> some View {
        let reason = capabilities.unavailability(for: kind)
        return pill(kind.title, reason: reason, position: nil, isSelected: false)
            .opacity(reason == nil ? 1 : AppTheme.Opacity.dim)
            .onTapGesture { if reason == nil { toggle(kind) } }
            .accessibilityLabel(kind.title)
            .accessibilityHint(reason ?? "Double tap to add")
    }

    // MARK: - The pill itself

    private func pill(
        _ title: String, reason: String? = nil, position: Int?, isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if let position {
                    Text(verbatim: "\(position)")
                        .font(AppTheme.Typography.captionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                        .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                        .background(AppTheme.Palette.brandPrimary, in: Circle())
                }
                Text(title)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
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

    /// Insert-before rather than swap. A swap moves two things when the user
    /// dragged one, which is exactly the behaviour that makes reordering
    /// feel like it is fighting back.
    private func move(_ moved: DashboardWidgetKind, before target: DashboardWidgetKind) {
        guard moved != target else { return }
        store.update { draft in
            guard let from = draft.selectedMetrics.firstIndex(of: moved) else { return }
            draft.selectedMetrics.remove(at: from)
            let destination = draft.selectedMetrics.firstIndex(of: target) ?? draft.selectedMetrics.count
            draft.selectedMetrics.insert(moved, at: destination)
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
