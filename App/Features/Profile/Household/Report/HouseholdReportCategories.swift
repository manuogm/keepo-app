import KeepoCore
import SwiftUI

/// Report screen three: which categories became one, and which did not.
///
/// The only screen in the report with real power behind it. Everything else
/// reviews; this one decides — and the decision is permanent enough to be
/// worth a person's attention, because merging two categories is saying that
/// two people's years of records were about the same thing.
///
/// **Merged** is what the fuzzy pass proposed plus whatever the owner joins by
/// hand. **Extra** is everything with no partner: yours, which can still be
/// merged, and theirs, which cannot be the *starting* point of a merge —
/// you merge one of yours *into* one of theirs, and offering the operation
/// from both ends would be two buttons for one act.
struct HouseholdReportCategories: View {
    let session: SessionStore
    let snapshot: HouseholdSnapshot
    var onChange: () -> Void

    @State private var editing: CategoryMergeSheet.Subject?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            countsCard
            list(for: .expense, title: "Expense categories")
            list(for: .income, title: "Income categories")
        }
        .sheet(item: $editing) { subject in
            CategoryMergeSheet(
                session: session, snapshot: snapshot, subject: subject, onChange: onChange
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var countsCard: some View {
        HouseholdCard(
            title: "Household categories",
            subtitle: "Merged ones are shared by both. Merge any Extra that mean the same thing."
        ) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.l) {
                HouseholdMetric(
                    value: snapshot.mergedCategories.count,
                    label: "Merged",
                    tint: PublicSchema.AccountScope.household.tint
                )
                HouseholdMetric(value: snapshot.extraCategories.count, label: "Extra")
            }
        }
    }

    private func list(for kind: PublicSchema.CategoryKind, title: String) -> some View {
        HouseholdCard(title: title) {
            CategoryKindSection(
                merged: snapshot.merged(kind),
                extras: snapshot.extras(kind),
                onOpen: { editing = $0 }
            )
        }
    }
}

/// One kind's Merged and Extra lists.
///
/// Split into its own view purely so each kind keeps its **own** expansion
/// state. Hoisted into the parent, opening Merged under Expenses would open it
/// under Income too, and the two lists are read independently.
private struct CategoryKindSection: View {
    let merged: [HouseholdMergedCategory]
    let extras: [HouseholdExtraCategory]
    var onOpen: (CategoryMergeSheet.Subject) -> Void

    @State private var isMergedExpanded = true
    @State private var isExtraExpanded = true

    private var mine: [HouseholdExtraCategory] { extras.filter(\.isMine) }
    private var theirs: [HouseholdExtraCategory] { extras.filter { !$0.isMine } }

    var body: some View {
        VStack(spacing: 0) {
            HouseholdDisclosure(title: "Merged", count: merged.count, isExpanded: $isMergedExpanded) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(merged) { category in
                        Button {
                            onOpen(.existing(category))
                        } label: {
                            HouseholdCategoryRow(
                                name: category.name,
                                icon: category.icon,
                                color: Color(hex: category.color)
                            ) {
                                HStack(spacing: AppTheme.Spacing.xs) {
                                    if category.isAutomatic {
                                        KeepoIcon(name: "icon-robot", size: AppTheme.Size.glyphNano)
                                            .foregroundStyle(AppTheme.Palette.textSecondary)
                                            .accessibilityLabel("Merged automatically")
                                    }
                                    Image(systemName: "link")
                                        .font(AppTheme.Typography.micro)
                                        .foregroundStyle(PublicSchema.AccountScope.household.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressableRow)
                    }
                }
                .padding(.bottom, AppTheme.Spacing.s)
            }

            Divider()

            HouseholdDisclosure(title: "Extra", count: extras.count, isExpanded: $isExtraExpanded) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    subgroup("Shared by you", mine, canMerge: true)
                    subgroup("Shared with you", theirs, canMerge: false)
                }
                .padding(.bottom, AppTheme.Spacing.s)
            }
        }
    }

    @ViewBuilder
    private func subgroup(_ title: String, _ rows: [HouseholdExtraCategory], canMerge: Bool) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .padding(.top, AppTheme.Spacing.xs)

            ForEach(rows) { extra in
                HouseholdCategoryRow(
                    name: extra.category.name,
                    icon: extra.category.icon,
                    color: Color(hex: extra.category.color)
                ) {
                    if canMerge {
                        Button { onOpen(.new(extra)) } label: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Image(systemName: "link")
                                Text("Merge")
                            }
                            .font(AppTheme.Typography.microEmphasis)
                            .foregroundStyle(PublicSchema.AccountScope.household.tint)
                            .padding(.horizontal, AppTheme.Spacing.s)
                            .padding(.vertical, AppTheme.Spacing.xs)
                            .background(
                                PublicSchema.AccountScope.household.tint
                                    .opacity(AppTheme.Opacity.fill),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.pressableCard)
                    } else {
                        SharedByThemIcon()
                    }
                }
            }
        }
    }
}
