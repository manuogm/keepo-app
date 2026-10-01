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
/// rows, which is a working if blunt app — and the Categories tab offers
/// this same catalogue again until the user makes a category of their own
/// (see `CategoriesView.offersSuggestions`).
///
/// Seven arrive selected. A catalogue with everything ticked is a list
/// nobody reads, and twenty categories on day one is twenty places to
/// second-guess a purchase — so the default is the short list almost
/// everyone files against, and the other thirteen are one tap away.
struct SetupCategoriesStep: View {
    let store: OnboardingDraftStore

    var body: some View {
        OnboardingScaffold(
            title: "Pick your categories",
            subtitle: "You can always add more or customize your selection later.",
            step: .categories,
            onBack: store.goBack,
            onSkip: skip,
            onPrimary: store.advance
        ) {
            DefaultCategoryCatalogGrid(selection: selection)
        }
    }

    private var selection: Binding<[DefaultCategoryKey]> {
        Binding(
            get: { store.draft.selectedCategories },
            set: { keys in store.update { $0.selectedCategories = keys } }
        )
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
