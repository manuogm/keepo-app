import Foundation
@testable import KeepoCore
import Testing

/// How many chips the form's category row shows, and in what order — the
/// three cases the row is judged by, plus the household one that made it
/// misbehave in the first place.
@Suite("Category suggestions")
struct CategorySuggestionsTests {
    private func category(_ name: String) -> PublicSchema.CategoriesSelect {
        PublicSchema.CategoriesSelect(
            color: "#8E8E93", createdAsTwin: false, createdAt: "", deletedAt: nil, icon: "tag.fill", id: UUID(),
            isDefault: false, kind: .expense, mergeOrigin: nil, name: name, ownerId: UUID(), preMergeColor: nil,
            preMergeIcon: nil, preMergeName: nil, sharedGroupId: nil, syncSeq: 0, updatedAt: "", version: 1
        )
    }

    @Test("fewer categories than seats shows every one of them")
    func fewerThanSeats() {
        let offered = [category("Groceries"), category("Rent")]
        let seated = CategorySuggestions.build(ranked: [offered[1].id], offered: offered, count: 3)
        #expect(seated.map(\.name) == ["Rent", "Groceries"])
    }

    @Test("thin history fills the rest of the row from the categories that exist")
    func thinHistoryPads() {
        let offered = (1...6).map { category("C\($0)") }
        let seated = CategorySuggestions.build(ranked: [offered[4].id], offered: offered, count: 3)
        // The one used, then the list's own order for the empty seats.
        #expect(seated.map(\.name) == ["C5", "C1", "C2"])
    }

    @Test("ample history is the ranking, untouched")
    func ampleHistory() {
        let offered = (1...6).map { category("C\($0)") }
        let ranked = [offered[3].id, offered[0].id, offered[5].id, offered[1].id]
        let seated = CategorySuggestions.build(ranked: ranked, offered: offered, count: 3)
        #expect(seated.map(\.name) == ["C4", "C1", "C6"])
    }

    /// The regression: on a household member's account most of the viewer's
    /// own categories are not on offer, so a ranking full of them used to
    /// leave a row with one tile on it.
    @Test("ranked ids that are not on offer cost no seat")
    func rankedButNotOffered() {
        let offered = [category("Shared"), category("Other"), category("Kids")]
        let mine = (1...3).map { category("Private\($0)") }
        let ranked = mine.map(\.id) + [offered[2].id]
        let seated = CategorySuggestions.build(ranked: ranked, offered: offered, count: 3)
        #expect(seated.map(\.name) == ["Kids", "Shared", "Other"])
    }

    @Test("a category ranked twice — this account, then the whole ledger — takes one seat")
    func duplicateRanking() {
        let offered = (1...4).map { category("C\($0)") }
        let ranked = [offered[2].id, offered[2].id, offered[0].id]
        let seated = CategorySuggestions.build(ranked: ranked, offered: offered, count: 3)
        #expect(seated.map(\.name) == ["C3", "C1", "C2"])
    }

    @Test("the title's match takes the front seat, and the weakest one leaves")
    func titleMatchGoesFirst() {
        let offered = (1...5).map { category("C\($0)") }
        let seated = CategorySuggestions.build(ranked: [], offered: offered, count: 3)
        let prioritized = CategorySuggestions.prioritizing(offered[4], in: seated)
        #expect(prioritized.map(\.name) == ["C5", "C1", "C2"])
    }

    @Test("a match already seated is reordered, never duplicated")
    func titleMatchAlreadySeated() {
        let offered = (1...4).map { category("C\($0)") }
        let seated = CategorySuggestions.build(ranked: [], offered: offered, count: 3)
        let prioritized = CategorySuggestions.prioritizing(offered[2], in: seated)
        #expect(prioritized.map(\.name) == ["C3", "C1", "C2"])
    }

    @Test("no match leaves the row exactly as it was")
    func noTitleMatch() {
        let offered = (1...4).map { category("C\($0)") }
        let seated = CategorySuggestions.build(ranked: [], offered: offered, count: 3)
        #expect(CategorySuggestions.prioritizing(nil, in: seated).map(\.name) == seated.map(\.name))
    }

    @Test("no categories at all is an empty row, not a crash")
    func nothingOffered() {
        #expect(CategorySuggestions.build(ranked: [UUID()], offered: [], count: 3).isEmpty)
    }
}
