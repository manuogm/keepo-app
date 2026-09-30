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

    /// The picker's way to a category that does not exist yet — the answer to
    /// "it isn't in the list", which until now ended at `More` and a list that
    /// still did not have it.
    ///
    /// `nil` on somebody else's account — `AccountCategories.canCreate` says
    /// why, beside the rest of the rules about whose categories go where.
    ///
    /// The selection itself arrives through `userCategoryBinding` like any
    /// tap, so a created category counts as chosen and a later title stops
    /// proposing over it.
    var categoryCreation: CategoryCreation? {
        guard let viewer = session.profile?.id,
              AccountCategories.canCreate(onAccountOwnedBy: fromAccount?.ownerId, viewer: viewer) else { return nil }
        return CategoryCreation(session: session, kind: kind == .income ? .income : .expense) {
            await reloadCategories()
        }
    }

    /// Re-reads the viewer's categories after one is created from the picker.
    /// `submitCreateCategory` awaits its own local write-through, so by the
    /// time this runs the new row is already in the mirror and this is an
    /// ordinary read rather than anything optimistic.
    ///
    /// The ranked suggestions are deliberately left alone: a category created
    /// a second ago has no history to rank on, and the row puts the selection
    /// in its first slot anyway.
    func reloadCategories() async {
        guard let ownerId = session.profile?.id else { return }
        guard let reloaded = try? await session.dbQueue.read({ database in
            try LocalTableQueries.categories(database, ownerId: ownerId.uuidString)
        }) else { return }
        categories = reloaded
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
