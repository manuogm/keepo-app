import Foundation
import KeepoCore

/// Everything setup is about to write, worked out before anything is
/// written.
///
/// The draft is what the user said; this is what that means in rows. They
/// are separated because the translation is where the mistakes live — a
/// category filed under the wrong kind, a colour that is not in the
/// palette, a selection order silently sorted, a name that violates the
/// column's CHECK — and none of those are visible in a screenshot. Pure
/// value in, pure value out, so all of it is testable without a network,
/// a database or a view.
///
/// It is also the answer to "can this be committed at all?": `make`
/// returns `nil` for a draft with no base currency, which is the one thing
/// `onboarded_requires_base_currency` will not let the flow finish without.
struct SetupCommitPlan {
    let userId: UUID
    let baseCurrency: String
    /// `nil` when the profile step was skipped. Absence, not `""` — see
    /// `ProfileRepository.completeOnboarding`.
    let displayName: String?
    let avatarJPEG: Data?
    /// `nil` only defensively: the account step is the one step that cannot
    /// be skipped, so in practice this is always present.
    let account: CreateAccountPayload?
    let categories: [CreateCategoryPayload]
    /// In selection order, deduplicated — the dashboard holds one widget
    /// per kind.
    let widgets: [DashboardWidgetKind]

    /// `profiles_display_name_length` allows 1–60 characters after
    /// trimming. The field caps typing at 60 already; this is the backstop,
    /// so a draft restored from an older build can never fail the patch.
    private static let displayNameLimit = 60

    static func make(draft: OnboardingDraft, userId: UUID) -> SetupCommitPlan? {
        guard let baseCurrency = draft.baseCurrency else { return nil }
        return SetupCommitPlan(
            userId: userId,
            baseCurrency: baseCurrency,
            displayName: name(from: draft.displayName),
            avatarJPEG: draft.avatarJPEG,
            account: accountPayload(from: draft.account, ownerId: userId),
            categories: categoryPayloads(for: draft.selectedCategories, ownerId: userId),
            // **Arranged here, not on the step.** The user chooses a set;
            // `OnboardingDashboardPlan` decides the order that packs
            // without leaving a hole in the grid. Doing it at the commit
            // rather than as they tap means the draft keeps what they
            // actually chose, and the layout is one decision made once from
            // the finished selection.
            widgets: OnboardingDashboardPlan.arrange(deduplicated(draft.selectedMetrics))
        )
    }

    private static func name(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(displayNameLimit))
    }

    /// The id comes from the draft rather than being minted here, which is
    /// what makes a retried commit land on the same row instead of leaving
    /// a duplicate account behind.
    private static func accountPayload(from account: DraftAccount?, ownerId: UUID) -> CreateAccountPayload? {
        guard let account else { return nil }
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return CreateAccountPayload(
            id: account.id, ownerId: ownerId, kind: account.kind, name: name,
            currency: account.currency, openingBalanceE4: account.openingBalanceE4,
            icon: account.icon, color: account.color
        )
    }

    /// A key with no catalogue entry is dropped rather than guessed at —
    /// the only way to hold one is a draft written by a build that knew a
    /// category this one does not, and inventing a row for it would put a
    /// category in the user's list that nothing in the app can describe.
    private static func categoryPayloads(
        for keys: [DefaultCategoryKey], ownerId: UUID
    ) -> [CreateCategoryPayload] {
        keys.compactMap(DefaultCategoryCatalog.category(for:)).map { category in
            CreateCategoryPayload(
                id: UUID(), ownerId: ownerId, kind: category.kind,
                name: category.name, icon: category.icon, color: category.color
            )
        }
    }

    private static func deduplicated(_ kinds: [DashboardWidgetKind]) -> [DashboardWidgetKind] {
        var seen: Set<DashboardWidgetKind> = []
        return kinds.filter { seen.insert($0).inserted }
    }
}
