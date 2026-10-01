import Foundation

/// **Which categories a form puts on its row, and in what order** — asked in
/// one place because the transaction form and the recurring-rule form draw
/// the same row and must answer it identically.
///
/// The row has a fixed number of seats, and this fills every one of them
/// that can be filled. It used to be the ranking alone, straight from
/// `LocalCategoryRanking`, which meant the row showed as many chips as the
/// user had history for and no more: a new account, a new install, or a
/// ledger where everything so far went to one category all drew a row with
/// **one** tile on it beside "More", while a dozen perfectly good categories
/// sat behind a sheet. History is how the seats are *ordered*; it was never
/// meant to be how many there are.
public enum CategorySuggestions {
    /// - Parameters:
    ///   - ranked: category ids most-used first — this account's own habits
    ///     ahead of the whole ledger's, as the callers read them. Ids that
    ///     are not on offer here (another account's, a deleted one) are
    ///     skipped rather than counted, which is why the callers must not
    ///     pre-trim this to `count`: three ranked ids of which two are
    ///     invalid is a one-tile row again.
    ///   - offered: every category valid for the kind and the account on
    ///     screen, in the order the picker lists them.
    ///   - count: how many seats the row has.
    ///
    /// Ranked-and-offered first, then the rest of `offered` in its own order
    /// until the seats run out. So: fewer categories than seats shows all of
    /// them; thin history shows what there is and completes the row with the
    /// categories the user actually has; ample history is the top `count`,
    /// untouched by any of this.
    ///
    /// **The padding is the list's order, not a random pick.** These tiles
    /// animate a swap when one is chosen, and the row is meant to be learned
    /// by position — "groceries is the middle one". A fill that re-rolled
    /// every time the account changed, or every time the form reopened,
    /// would move the tiles under a finger that had stopped looking.
    public static func build(
        ranked: [UUID], offered: [PublicSchema.CategoriesSelect], count: Int
    ) -> [PublicSchema.CategoriesSelect] {
        guard count > 0 else { return [] }
        var taken: Set<UUID> = []
        var seated: [PublicSchema.CategoriesSelect] = []

        for id in ranked {
            guard seated.count < count else { return seated }
            guard taken.insert(id).inserted, let category = offered.first(where: { $0.id == id }) else { continue }
            seated.append(category)
        }
        for category in offered {
            guard seated.count < count else { break }
            if taken.insert(category.id).inserted { seated.append(category) }
        }
        return seated
    }

    /// The category a typed title points at, moved to the front of a row
    /// that is already built.
    ///
    /// **Not folded into `build`.** The row is built from a database read,
    /// which happens when the account or the kind changes; the title's match
    /// arrives on its own clock, several keystrokes later, and must re-order
    /// the seats without going back to the database for them.
    ///
    /// The row keeps its length, so the match costs the weakest seat — the
    /// last one — rather than adding a fourth. `nil`, or a match already
    /// seated first, leaves the row exactly as it was.
    public static func prioritizing(
        _ match: PublicSchema.CategoriesSelect?, in seated: [PublicSchema.CategoriesSelect]
    ) -> [PublicSchema.CategoriesSelect] {
        guard let match, !seated.isEmpty else { return seated }
        return Array(([match] + seated.filter { $0.id != match.id }).prefix(seated.count))
    }
}
