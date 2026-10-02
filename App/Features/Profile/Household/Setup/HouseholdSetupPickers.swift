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
    /// Which selected accounts also bring their past transactions.
    @Binding var fullHistory: Set<UUID>
    @ViewBuilder var footer: Footer

    var body: some View {
        HouseholdPickerScaffold(
            title: "Shared accounts",
            isLoaded: isLoaded,
            isEmpty: accounts.isEmpty,
            emptyMessage: "You have no accounts to share yet.",
            footer: { footer },
            content: {
                    ForEach(HouseholdAccountGroup.allCases, id: \.self) { group in
                    let rows = accounts.filter { $0.kind == group.kind }
                    if !rows.isEmpty {
                        HouseholdPickerSection(
                            title: group.title,
                            ids: rows.map(\.id),
                            selection: $selection
                        ) {
                            ForEach(rows) { account in
                                HouseholdAccountRow(
                                    name: account.name,
                                    icon: account.icon,
                                    color: Color(hex: account.color),
                                    isInvestment: account.kind == .investment
                                ) {
                                    if selection.contains(account.id) {
                                        HouseholdHistoryPill(isOn: historyBinding(for: account.id))
                                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                                    }
                                } trailing: {
                                    HouseholdPickerToggle(isOn: binding(for: account.id))
                                }
                                .animation(AppTheme.Motion.standard, value: selection.contains(account.id))
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

    private func historyBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { fullHistory.contains(id) },
            set: { isOn in
                if isOn { fullHistory.insert(id) } else { fullHistory.remove(id) }
            }
        )
    }
}

/// The second question an account asks once it is switched on: does the
/// household see what happened on it before today? Off by default (user's
/// decision, 2026-09-23) — sharing an account's future is the ordinary case,
/// and handing over its whole past should be a choice someone made.
///
/// A pill under the account's name rather than a second switch on a row of
/// its own: a second row read as one more account, and a second switch made
/// every shared account look like two decisions of equal weight. Filled in
/// the household tint when on, so the state reads without a label change.
struct HouseholdHistoryPill: View {
    @Binding var isOn: Bool

    private var tint: Color { PublicSchema.AccountScope.household.tint }

    var body: some View {
        Button {
            withAnimation(AppTheme.Motion.quick) { isOn.toggle() }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: isOn ? "checkmark" : "plus")
                Text("Share past history")
            }
            .font(AppTheme.Typography.microEmphasis)
            .foregroundStyle(isOn ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(isOn ? tint : AppTheme.Palette.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isOn)
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
            isLoaded: isLoaded,
            isEmpty: categories.isEmpty,
            emptyMessage: "You have no categories to share yet.",
            footer: { footer },
            content: {
                    ForEach([PublicSchema.CategoryKind.expense, .income], id: \.self) { kind in
                    let rows = categories.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        HouseholdPickerSection(
                            title: kind == .expense ? "Expenses" : "Income",
                            ids: rows.map(\.id),
                            selection: $selection
                        ) {
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

/// The page both pickers are: a title and grouped cards of switches. No
/// explanatory sentence — the intro screen carries the explanation, and the
/// one thing it cannot say (how much of an account's past is shared) is the
/// pill on the account itself.
private struct HouseholdPickerScaffold<Content: View, Footer: View>: View {
    let title: String
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
                Text(title)
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
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

/// One titled group of rows on its own card, with its own Select All.
///
/// **Per group, on the group's own line.** Flipping a long list one toggle at
/// a time is the tedious part of this screen, and the fastest route to "most
/// of them" is all-on then untick a few. One control for the whole screen was
/// tried first and is worse in both directions: it has to sit somewhere that
/// is not beside anything it acts on, and on the categories step it silently
/// covers Income as well as Expenses. Beside the heading it names exactly
/// what it will do.
struct HouseholdPickerSection<Content: View>: View {
    let title: String
    /// Every id this group lists — the scope of its own button, and nothing
    /// else's.
    let ids: [UUID]
    @Binding var selection: Set<UUID>
    @ViewBuilder var content: Content

    private var isEverythingSelected: Bool {
        !ids.isEmpty && ids.allSatisfy(selection.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .kerning(0.6)
                Spacer(minLength: AppTheme.Spacing.s)
                selectAll
            }
            FormCard(padding: AppTheme.Spacing.m) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    content
                }
            }
        }
    }

    /// One control with two jobs, because they are the same job. Which one it
    /// offers is read off the list rather than remembered, so it is always the
    /// one that would change something.
    ///
    /// Plain text rather than a capsule: it sits on a line of small grey
    /// uppercase metadata, and a filled pill there would outweigh the heading
    /// it belongs to. The padding is inside the label — `hitTarget()` overlays
    /// a hit-testable `Color.clear`, which on a `Button` lands on top of it
    /// and swallows every tap (found on the Household screen's info glyph).
    private var selectAll: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) {
                if isEverythingSelected {
                    selection.subtract(ids)
                } else {
                    selection.formUnion(ids)
                }
            }
        } label: {
            Text(isEverythingSelected ? "Deselect All" : "Select All")
                .font(AppTheme.Typography.microEmphasis)
                .foregroundStyle(PublicSchema.AccountScope.household.tint)
                .padding(.vertical, AppTheme.Spacing.xs)
                .padding(.leading, AppTheme.Spacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isEverythingSelected)
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
