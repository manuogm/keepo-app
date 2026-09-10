import KeepoCore
import SwiftUI

/// Which of your accounts join the household, grouped the way the Accounts
/// screen groups them.
///
/// Everyday and Investment, in that order, because that is the order the
/// Accounts list uses and a user choosing accounts here is picturing that
/// list. A group with nothing in it is not drawn at all — an empty
/// "Investment" header on a screen full of switches reads as a group that
/// failed to load.
struct HouseholdAccountPicker<Footer: View>: View {
    let accounts: [LocalAccountRow]
    /// False until the read lands. "You have no accounts to share yet" is a
    /// claim about the user's data, and making it before looking is worse
    /// than showing nothing — the same rule `ScopeContext.isLoaded` exists for.
    let isLoaded: Bool
    @Binding var selection: Set<UUID>
    @ViewBuilder var footer: Footer

    var body: some View {
        HouseholdPickerScaffold(
            title: "Shared accounts",
            subtitle: nil,
            isLoaded: isLoaded,
            isEmpty: accounts.isEmpty,
            emptyMessage: "You have no accounts to share yet.",
            footer: { footer },
            content: {
                    ForEach(HouseholdAccountGroup.allCases, id: \.self) { group in
                    let rows = accounts.filter { $0.kind == group.kind }
                    if !rows.isEmpty {
                        HouseholdPickerSection(title: group.title) {
                            ForEach(rows) { account in
                                HouseholdAccountRow(
                                    name: account.name,
                                    icon: account.icon,
                                    color: Color(hex: account.color),
                                    isInvestment: account.kind == .investment
                                ) {
                                    HouseholdPickerToggle(isOn: binding(for: account.id))
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}

enum HouseholdAccountGroup: CaseIterable {
    case everyday
    case investment

    var kind: PublicSchema.AccountKind { self == .everyday ? .regular : .investment }
    var title: String { self == .everyday ? "Everyday" : "Investment" }
}

/// Which of your categories join the household, split by kind.
struct HouseholdCategoryPicker<Footer: View>: View {
    let categories: [PublicSchema.CategoriesSelect]
    let isLoaded: Bool
    @Binding var selection: Set<UUID>
    @ViewBuilder var footer: Footer

    var body: some View {
        HouseholdPickerScaffold(
            title: "Shared categories",
            subtitle: nil,
            isLoaded: isLoaded,
            isEmpty: categories.isEmpty,
            emptyMessage: "You have no categories to share yet.",
            footer: { footer },
            content: {
                    ForEach([PublicSchema.CategoryKind.expense, .income], id: \.self) { kind in
                    let rows = categories.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        HouseholdPickerSection(title: kind == .expense ? "Expenses" : "Income") {
                            ForEach(rows, id: \.id) { category in
                                HouseholdCategoryRow(
                                    name: category.name,
                                    icon: category.icon,
                                    color: Color(hex: category.color)
                                ) {
                                    HouseholdPickerToggle(isOn: binding(for: category.id))
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}

// MARK: - Shared shell

/// The page both pickers are: a title, an optional sentence explaining the
/// consequence, and grouped cards of switches. The intro screen now carries
/// the explanation, so both pickers pass `subtitle: nil` and the row of
/// switches sits directly under the heading.
private struct HouseholdPickerScaffold<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyMessage: String
    /// The step's action, rendered as the last thing in the scroll rather
    /// than pinned over it — a list of switches with a button floating on top
    /// hides whichever row is underneath it, and the row it hides is always
    /// the last one.
    @ViewBuilder var footer: Footer
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(AppTheme.Typography.screenTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, AppTheme.Spacing.xl)
                } else if isEmpty {
                    Text(emptyMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    content
                }

                footer
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.s)
            .padding(.bottom, AppTheme.Spacing.l)
        }
        .background(AppTheme.Palette.bgCanvas)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One titled group of rows on its own card.
struct HouseholdPickerSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(title.uppercased())
                .font(AppTheme.Typography.nanoEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .kerning(0.6)
            FormCard(padding: AppTheme.Spacing.m) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    content
                }
            }
        }
    }
}

/// The switch on a picker row.
///
/// A `Toggle` with no label rather than the checkmark circle the old invite
/// flow used: the spec asks for a toggle, and it is also the control the rest
/// of the app uses for "this is on" — the summary screen has the identical
/// switch doing the identical thing after the household exists, and the two
/// screens showing one state two ways would be the worse inconsistency.
struct HouseholdPickerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(PublicSchema.AccountScope.household.tint)
            .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isOn)
    }
}
