import KeepoCore
import SwiftUI

/// Step 5 — the categories the user will actually file against, chosen
/// before there is anything to file.
///
/// **Nothing here is `is_default`, and that is a schema constraint rather
/// than a taste.** The backend seeds exactly one default category per kind
/// at signup — the two "Other" rows — and
/// `categories_one_default_per_kind` means there can never be a second, so
/// `DefaultCategoryCatalog` deliberately offers no "Other" of its own.
/// Skipping this step is therefore not "no categories": it is those two
/// rows, which is a working if blunt app.
///
/// Seven arrive selected. A catalogue with everything ticked is a list
/// nobody reads, and twenty categories on day one is twenty places to
/// second-guess a purchase — so the default is the short list almost
/// everyone files against, and the other thirteen are one tap away.
struct SetupCategoriesStep: View {
    let store: OnboardingDraftStore

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.s), count: 3
    )

    var body: some View {
        OnboardingScaffold(
            title: "Pick your categories",
            subtitle: "You can always add more or customize your selection later.",
            step: .categories,
            onBack: store.goBack,
            onSkip: skip,
            onPrimary: store.advance
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                group("Expenses", DefaultCategoryCatalog.expenses)
                group("Income", DefaultCategoryCatalog.income)
            }
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: store.draft.selectedCategories)
        }
    }

    private func group(_ title: String, _ categories: [DefaultCategory]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text(title)
                .font(AppTheme.Typography.rowTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            LazyVGrid(columns: Self.columns, spacing: AppTheme.Spacing.s) {
                ForEach(categories) { category in
                    Button {
                        toggle(category.key)
                    } label: {
                        CategoryTile(category: category, isSelected: isSelected(category.key))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.name)
                    .accessibilityAddTraits(isSelected(category.key) ? .isSelected : [])
                }
            }
        }
    }

    private func isSelected(_ key: DefaultCategoryKey) -> Bool {
        store.draft.selectedCategories.contains(key)
    }

    /// Appends rather than inserting in catalogue order, which costs
    /// nothing here — categories have no hierarchy, unlike the dashboard's
    /// widgets, so the only thing order affects is the sequence the outbox
    /// writes them in.
    private func toggle(_ key: DefaultCategoryKey) {
        store.update { draft in
            if let index = draft.selectedCategories.firstIndex(of: key) {
                draft.selectedCategories.remove(at: index)
            } else {
                draft.selectedCategories.append(key)
            }
        }
    }

    /// Skip means the two `Other` rows the backend already seeded and
    /// nothing else — so it has to *clear* the seven that arrived ticked.
    /// Leaving them would make Skip mean "accept these seven", which is
    /// what Next already means.
    private func skip() {
        store.update { $0.selectedCategories = [] }
        store.advance()
    }
}
