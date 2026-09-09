import KeepoCore
import SwiftUI

/// Everything the household holds, in one card — and the controls to change
/// it.
///
/// **The same view in two places, on purpose.** It is the last screen of the
/// setup report and the whole body of the Household screen afterwards, because
/// the spec asks for identical content in both and they are, genuinely, the
/// same question: what is in this household right now. Building it twice would
/// mean the summary the user approved during setup and the summary they see a
/// month later could drift into disagreeing about what "shared" means.
///
/// Your own rows carry a **live switch** — flipping one shares or unshares
/// immediately, no separate save. Theirs carry a glyph instead of a disabled
/// switch: a control you cannot move invites you to try and then says nothing
/// about why it did not.
struct HouseholdSummaryCard: View {
    let session: SessionStore
    let snapshot: HouseholdSnapshot
    var onChange: () -> Void

    @State private var isAccountsExpanded = true
    @State private var isCategoriesExpanded = false
    @State private var isTagsExpanded = false
    @State private var busyIds: Set<UUID> = []
    @State private var errorMessage: String?

    private var viewer: UUID? { session.profile?.id }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            HouseholdCard(title: "Summary") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    BalanceHeaderView(
                        amount: snapshot.netWorthE4,
                        currency: snapshot.baseCurrency,
                        size: AppTheme.Typography.Number.balance
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
                        accountsSection
                        Divider()
                        categoriesSection
                        Divider()
                        tagsSection
                    }
                }
            }

            if let errorMessage { FormErrorText(message: errorMessage) }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        HouseholdDisclosure(
            title: "Shared accounts",
            count: snapshot.sharedAccounts.count,
            isExpanded: $isAccountsExpanded
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                ForEach(HouseholdAccountGroup.allCases, id: \.self) { group in
                    // Both your shared accounts and the ones you could still
                    // share, in one list: the switch is the difference, which
                    // is what makes "share one more" a flip rather than a
                    // journey back through the setup flow.
                    let rows = (snapshot.sharedAccounts + snapshot.privateAccounts)
                        .filter { $0.kind == group.kind }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if !rows.isEmpty {
                        subheading(group.title)
                        ForEach(rows) { account in
                            HouseholdAccountRow(
                                name: account.name,
                                icon: account.icon,
                                color: Color(hex: account.color),
                                isInvestment: account.kind == .investment
                            ) {
                                if account.ownerId == viewer {
                                    shareToggle(
                                        id: account.id,
                                        isOn: account.isShared,
                                        set: { await setAccountShared(account.id, shared: $0) }
                                    )
                                } else {
                                    SharedByThemIcon()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, AppTheme.Spacing.s)
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        HouseholdDisclosure(
            title: "Shared categories",
            count: snapshot.mergedCategories.count + snapshot.extraCategories.count,
            isExpanded: $isCategoriesExpanded
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                ForEach([PublicSchema.CategoryKind.expense, .income], id: \.self) { kind in
                    let rows = categoryRows(kind)
                    if !rows.isEmpty {
                        subheading(kind == .expense ? "Expenses" : "Income")
                        ForEach(rows) { row in
                            HouseholdCategoryRow(
                                name: row.name, icon: row.icon, color: Color(hex: row.color)
                            ) {
                                if row.isMine {
                                    shareToggle(
                                        id: row.id,
                                        isOn: row.isShared,
                                        set: { await setCategoryShared(row.id, shared: $0) }
                                    )
                                } else {
                                    SharedByThemIcon()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, AppTheme.Spacing.s)
        }
    }

    /// One flat list per kind: what is shared, then what could be.
    ///
    /// A merged pair contributes **one** row, not two. It is one category —
    /// that is what merging it meant — and listing both halves would undo on
    /// this screen the very thing the report screen before it was for.
    private func categoryRows(_ kind: PublicSchema.CategoryKind) -> [SummaryCategoryRow] {
        let merged = snapshot.merged(kind).map {
            SummaryCategoryRow(
                id: $0.mine.id, name: $0.name, icon: $0.icon, color: $0.color,
                isMine: true, isShared: true
            )
        }
        let extras = snapshot.extras(kind).map {
            SummaryCategoryRow(
                id: $0.category.id, name: $0.category.name, icon: $0.category.icon,
                color: $0.category.color, isMine: $0.isMine, isShared: true
            )
        }
        let unshared = snapshot.privateCategories.filter { $0.kind == kind }.map {
            SummaryCategoryRow(
                id: $0.id, name: $0.name, icon: $0.icon, color: $0.color,
                isMine: true, isShared: false
            )
        }
        return (merged + extras + unshared)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        HouseholdDisclosure(
            title: "All tags", count: snapshot.tags.count, isExpanded: $isTagsExpanded
        ) {
            TagFlowLayout(spacing: AppTheme.Spacing.s) {
                ForEach(snapshot.tags, id: \.id) { tag in
                    TagChip(name: tag.name)
                }
            }
            .padding(.bottom, AppTheme.Spacing.s)
        }
    }

    // MARK: - Pieces

    private func subheading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppTheme.Typography.nanoEmphasis)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .kerning(0.6)
            .padding(.top, AppTheme.Spacing.xs)
    }

    /// A switch that writes as soon as it moves, and shows a spinner in its
    /// place while it does.
    ///
    /// Swapping the control out rather than dimming it: sharing an account
    /// is a round trip plus a sync pull, and a switch that has visibly moved
    /// while the underlying value has not yet changed is a switch the user
    /// will flip again.
    @ViewBuilder
    private func shareToggle(id: UUID, isOn: Bool, set: @escaping (Bool) async -> Void) -> some View {
        if busyIds.contains(id) {
            ProgressView()
        } else {
            HouseholdPickerToggle(
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        busyIds.insert(id)
                        Task {
                            await set(newValue)
                            busyIds.remove(id)
                        }
                    }
                )
            )
        }
    }

    // MARK: - Writes

    private func setAccountShared(_ id: UUID, shared: Bool) async {
        errorMessage = nil
        do {
            if shared {
                try await HouseholdRepository.share(client: session.client, accountId: id)
            } else {
                try await HouseholdRepository.unshare(client: session.client, accountId: id)
            }
            await session.syncNow()
            session.refresh.bump()
            onChange()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }

    private func setCategoryShared(_ id: UUID, shared: Bool) async {
        errorMessage = nil
        do {
            if shared {
                try await HouseholdRepository.shareCategory(client: session.client, categoryId: id)
            } else {
                // Unlinks the whole group, including a merge. That is the
                // right blast radius: a shared category with one member left
                // in it is a private category wearing a badge.
                try await HouseholdRepository.unshareCategory(client: session.client, categoryId: id)
            }
            await session.syncNow()
            session.refresh.bump()
            onChange()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}

/// A category as the summary needs it, flattened out of the three shapes it
/// can arrive in (merged, extra, private).
private struct SummaryCategoryRow: Identifiable {
    let id: UUID
    let name: String
    let icon: String
    let color: String
    let isMine: Bool
    let isShared: Bool
}
