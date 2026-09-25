import Foundation

/// Which categories a form offers for a row on an account.
///
/// A transaction or recurring rule belongs to its account's owner, and so
/// does its category — `(category_id, owner_id)` is a foreign key. On
/// someone else's account the viewer is offered only their own categories
/// that have a counterpart there (user's decision, 2026-09-24):
/// - one shared with the household. A shared category is one row per
///   member, joined by `sharedGroupId`;
/// - their default, "Other". Each member has exactly one per kind.
///
/// The server swaps the viewer's row for the owner's counterpart
/// (`owners_category`, 20261015100000). A private category has no
/// counterpart, so it is not offered, and the server refuses it anyway.
public enum AccountCategories {
    /// `categories` are the viewer's own, plus — when editing the owner's
    /// row — the owner's category it already carries, which is always
    /// valid on the owner's account.
    public static func offered(
        _ categories: [PublicSchema.CategoriesSelect], onAccountOwnedBy owner: UUID, viewer: UUID
    ) -> [PublicSchema.CategoriesSelect] {
        guard owner != viewer else { return categories }
        return categories.filter { $0.ownerId == owner || hasCounterpart($0) }
    }

    /// The viewer's own row for a category someone else's row carries, when
    /// the two are the same category: the same shared group, or both the
    /// default of their kind. Nil for a category private to its owner — the
    /// form then shows the owner's row itself.
    public static func viewersCounterpart(
        of category: PublicSchema.CategoriesSelect, among mine: [PublicSchema.CategoriesSelect]
    ) -> PublicSchema.CategoriesSelect? {
        if category.isDefault {
            return mine.first { $0.isDefault && $0.kind == category.kind }
        }
        guard let group = category.sharedGroupId else { return nil }
        return mine.first { $0.sharedGroupId == group && $0.kind == category.kind }
    }

    /// What a form editing a row shows for the category the row carries,
    /// and the list it offers. The row's category, when it is the viewer's
    /// own; the viewer's own row for it, when the two are the same category
    /// (the server swaps it back on save); otherwise the owner's row itself,
    /// added to the list, since a category is readable wherever it labels a
    /// row the viewer can see.
    public static func editing(
        held: PublicSchema.CategoriesSelect, among mine: [PublicSchema.CategoriesSelect]
    ) -> (selection: UUID, categories: [PublicSchema.CategoriesSelect]) {
        if mine.contains(where: { $0.id == held.id }) { return (held.id, mine) }
        if let counterpart = viewersCounterpart(of: held, among: mine) { return (counterpart.id, mine) }
        return (held.id, mine + [held])
    }

    private static func hasCounterpart(_ category: PublicSchema.CategoriesSelect) -> Bool {
        category.isDefault || category.sharedGroupId != nil
    }
}
