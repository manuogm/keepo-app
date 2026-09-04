import KeepoCore
import SwiftUI

// The category half of the Household screen, split out of HouseholdView.swift
// for the project's file-length lint — same precedent as ProfileView's own
// split. `myCategories` and `errorMessage` are internal rather than private
// for the same reason: `private` is file-scoped.

extension HouseholdView {
    /// The same shape as the account toggles above, because it is the same
    /// question. A shared category is one category on both phones — renaming
    /// it renames it for both — and it shares the label, never the spending:
    /// only a shared *account* shows its transactions.
    @ViewBuilder
    var shareCategoriesSection: some View {
        Section {
            ForEach(myCategories.filter { !$0.isDefault }, id: \.id) { category in
                Toggle(category.name, isOn: sharedCategoryBinding(for: category))
                    .tint(AppTheme.Palette.statusPositive)
            }
        } header: {
            Text("Share categories")
        } footer: {
            Text("A shared category is one category on both phones. It shares the name, not your spending.")
        }
    }

    func sharedCategoryBinding(for category: PublicSchema.CategoriesSelect) -> Binding<Bool> {
        Binding(
            get: { category.sharedGroupId != nil },
            set: { newValue in Task { await setCategoryShared(category.id, shared: newValue) } }
        )
    }

    func setCategoryShared(_ categoryId: UUID, shared: Bool) async {
        errorMessage = nil
        do {
            if shared {
                try await HouseholdRepository.shareCategory(client: session.client, categoryId: categoryId)
            } else {
                try await HouseholdRepository.unshareCategory(client: session.client, categoryId: categoryId)
            }
            await session.syncNow()
            await load()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}
