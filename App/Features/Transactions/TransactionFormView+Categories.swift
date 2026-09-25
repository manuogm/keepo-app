import KeepoCore
import SwiftUI

// Which categories the form offers, and which it shows on a row it is
// editing. Split out of TransactionFormView.swift for the project's
// file-length lint, same precedent as TransactionFormView+Date.swift.

extension TransactionFormView {
    /// On someone else's account, only the categories that have a
    /// counterpart there — see `AccountCategories`. `adoptContext()` swaps a
    /// held category that stops being offered when the account changes.
    var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        var offered = categories
        if let account = fromAccount, let viewer = session.profile?.id {
            offered = AccountCategories.offered(categories, onAccountOwnedBy: account.ownerId, viewer: viewer)
        }
        return offered.filter { $0.kind == categoryKind }
    }

    /// A row on someone else's account carries the owner's category, which
    /// is not among the viewer's own — `AccountCategories.editing` says what
    /// to show. Without it, `adoptContext()` would find the held category
    /// missing and quietly replace it with a suggestion.
    ///
    /// Synchronous, straight after `apply`, and fed from `load()`'s own read:
    /// setting the account wakes `adoptContext()`, and an `await` here would
    /// give it the gap to replace the category first.
    func adoptEditedCategory(_ held: PublicSchema.CategoriesSelect?) {
        guard let held, held.id == selectedCategoryId else { return }
        let resolved = AccountCategories.editing(held: held, among: categories)
        categories = resolved.categories
        selectedCategoryId = resolved.selection
    }
}
