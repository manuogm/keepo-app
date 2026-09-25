import Foundation
@testable import KeepoCore
import Testing

/// The phone's side of `owners_category` (20261015100000): what a form
/// offers on someone else's account, and which of the viewer's own rows is
/// the same category as the owner's.
@Suite("AccountCategories")
struct AccountCategoriesTests {
    private let owner = UUID()
    private let partner = UUID()
    private let group = UUID()

    private func category(
        _ name: String, of person: UUID, kind: PublicSchema.CategoryKind = .expense,
        isDefault: Bool = false, group: UUID? = nil
    ) -> PublicSchema.CategoriesSelect {
        PublicSchema.CategoriesSelect(
            color: "#8E8E93", createdAsTwin: false, createdAt: "", deletedAt: nil, icon: "tag.fill", id: UUID(),
            isDefault: isDefault, kind: kind, mergeOrigin: nil, name: name, ownerId: person, preMergeColor: nil,
            preMergeIcon: nil, preMergeName: nil, sharedGroupId: group, syncSeq: 0, updatedAt: "", version: 1
        )
    }

    private var partners: [PublicSchema.CategoriesSelect] {
        [
            category("Other", of: partner, isDefault: true),
            category("Other", of: partner, kind: .income, isDefault: true),
            category("Kids", of: partner, group: group),
            category("Hobby", of: partner)
        ]
    }

    @Test("on your own account, every one of your categories")
    func ownAccount() {
        #expect(AccountCategories.offered(partners, onAccountOwnedBy: partner, viewer: partner).count == 4)
    }

    @Test("on the owner's account, only the shared ones and Other")
    func partnersAccount() {
        let offered = AccountCategories.offered(partners, onAccountOwnedBy: owner, viewer: partner)
        #expect(offered.map(\.name).sorted() == ["Kids", "Other", "Other"])
    }

    @Test("the owner's category already on a row being edited stays on offer")
    func ownersCategoryKept() {
        let dining = category("Dining", of: owner)
        let offered = AccountCategories.offered(partners + [dining], onAccountOwnedBy: owner, viewer: partner)
        #expect(offered.contains { $0.id == dining.id })
    }

    @Test("the viewer's own row for the owner's shared category, or Other")
    func counterpart() {
        let kids = category("Kids", of: owner, group: group)
        let other = category("Other", of: owner, isDefault: true)
        let otherIncome = category("Other", of: owner, kind: .income, isDefault: true)
        let dining = category("Dining", of: owner)
        #expect(AccountCategories.viewersCounterpart(of: kids, among: partners)?.name == "Kids")
        #expect(AccountCategories.viewersCounterpart(of: other, among: partners)?.kind == .expense)
        #expect(AccountCategories.viewersCounterpart(of: otherIncome, among: partners)?.kind == .income)
        #expect(AccountCategories.viewersCounterpart(of: dining, among: partners) == nil)
    }

    @Test("editing the owner's row: your own copy of a shared category, else the owner's own")
    func editing() {
        let mine = partners
        let kids = category("Kids", of: owner, group: group)
        let dining = category("Dining", of: owner)

        let shared = AccountCategories.editing(held: kids, among: mine)
        #expect(shared.selection == mine[2].id)
        #expect(shared.categories.count == mine.count)

        let privateToOwner = AccountCategories.editing(held: dining, among: mine)
        #expect(privateToOwner.selection == dining.id)
        #expect(privateToOwner.categories.last?.id == dining.id)

        let own = AccountCategories.editing(held: mine[3], among: mine)
        #expect(own.selection == mine[3].id)
        #expect(own.categories.count == mine.count)
    }
}
