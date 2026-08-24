import Foundation
import KeepoCore
import Testing
import UserNotifications
@testable import Keepo

/// `CaptureQuickActions.build(for:)` — the button set for each of
/// `CaptureNotificationCopy`'s four resolution branches, crossed with the
/// duplicate override. Pure logic, no `UNUserNotificationCenter` involved.
@Suite("Capture quick actions")
struct CaptureQuickActionsTests {
    private func suggestion(_ name: String) -> CaptureLocalWrite.Suggestion {
        CaptureLocalWrite.Suggestion(id: UUID().uuidString, name: name)
    }

    private func resolution(
        accountId: String?, categoryIsDefault: Bool, suggestedCategories: [CaptureLocalWrite.Suggestion] = [],
        suggestedAccounts: [CaptureLocalWrite.Suggestion] = [], isPossibleDuplicate: Bool = false
    ) -> CaptureLocalWrite.Resolution {
        CaptureLocalWrite.Resolution(
            accountName: accountId != nil ? "Revolut" : nil, categoryName: "Coffee",
            categoryIsDefault: categoryIsDefault, currency: accountId != nil ? "EUR" : nil, minorUnit: 2,
            categoryId: UUID().uuidString, accountId: accountId, suggestedCategories: suggestedCategories,
            suggestedAccounts: suggestedAccounts, isPossibleDuplicate: isPossibleDuplicate
        )
    }

    @Test("both known — Confirm, 2 alternate categories, More options")
    func bothKnown() {
        let categories = [suggestion("Groceries"), suggestion("Dining"), suggestion("Transport")]
        let set = CaptureQuickActions.build(
            for: resolution(accountId: UUID().uuidString, categoryIsDefault: false, suggestedCategories: categories)
        )
        #expect(set.actions.map(\.identifier) == [
            CaptureQuickActions.confirmActionId, "capture.pick.0", "capture.pick.1", CaptureQuickActions.moreActionId
        ])
        #expect(set.userInfo[CaptureQuickActions.pickKindKey] as? String == "category")
        // The third, least-used suggestion is the one that gives up its
        // slot to More — the ids travelling in `userInfo` must match the
        // two buttons actually shown, or a tap would route to the wrong row.
        #expect(set.userInfo[CaptureQuickActions.pickIdsKey] as? [String] == categories.prefix(2).map(\.id))
    }

    @Test("both known + possible duplicate — Confirm, 1 alternate, More options, Delete")
    func bothKnownDuplicate() {
        let categories = [suggestion("Groceries"), suggestion("Dining"), suggestion("Transport")]
        let set = CaptureQuickActions.build(
            for: resolution(
                accountId: UUID().uuidString, categoryIsDefault: false, suggestedCategories: categories,
                isPossibleDuplicate: true
            )
        )
        #expect(set.actions.map(\.identifier) == [
            CaptureQuickActions.confirmActionId, "capture.pick.0", CaptureQuickActions.moreActionId,
            CaptureQuickActions.deleteActionId
        ])
        #expect(set.actions.last?.options.contains(.destructive) == true)
    }

    /// Regression (device testing): "More options" did nothing visible
    /// because it ran in a background-launched process instead of bringing
    /// Keepo forward. It is also the ONLY action that may foreground —
    /// every other one must complete its write without interrupting the user.
    @Test("More options is the only foreground action")
    func onlyMoreOptionsForegrounds() {
        let set = CaptureQuickActions.build(
            for: resolution(
                accountId: UUID().uuidString, categoryIsDefault: false,
                suggestedCategories: [suggestion("Groceries"), suggestion("Dining")], isPossibleDuplicate: true
            )
        )
        for action in set.actions {
            #expect(action.options.contains(.foreground) == (action.identifier == CaptureQuickActions.moreActionId))
        }
    }

    @Test("category unknown — up to 3 category picks plus More options")
    func categoryUnknown() {
        let categories = [suggestion("Groceries"), suggestion("Dining")]
        let set = CaptureQuickActions.build(
            for: resolution(accountId: UUID().uuidString, categoryIsDefault: true, suggestedCategories: categories)
        )
        #expect(set.actions.map(\.identifier) == ["capture.pick.0", "capture.pick.1", CaptureQuickActions.moreActionId])
        #expect(set.userInfo[CaptureQuickActions.pickKindKey] as? String == "category")
    }

    @Test("account unknown — up to 3 account picks plus More options")
    func accountUnknown() {
        let accounts = [suggestion("Checking"), suggestion("Savings"), suggestion("Cash")]
        let set = CaptureQuickActions.build(
            for: resolution(accountId: nil, categoryIsDefault: false, suggestedAccounts: accounts)
        )
        #expect(set.actions.map(\.identifier) == [
            "capture.pick.0", "capture.pick.1", "capture.pick.2", CaptureQuickActions.moreActionId
        ])
        #expect(set.userInfo[CaptureQuickActions.pickKindKey] as? String == "account")
        #expect(set.userInfo[CaptureQuickActions.pickIdsKey] as? [String] == accounts.map(\.id))
    }

    @Test("account unknown + possible duplicate — 2 picks, More, Delete")
    func accountUnknownDuplicate() {
        let accounts = [suggestion("Checking"), suggestion("Savings"), suggestion("Cash")]
        let set = CaptureQuickActions.build(
            for: resolution(
                accountId: nil, categoryIsDefault: false, suggestedAccounts: accounts, isPossibleDuplicate: true
            )
        )
        #expect(set.actions.map(\.identifier) == [
            "capture.pick.0", "capture.pick.1", CaptureQuickActions.moreActionId, CaptureQuickActions.deleteActionId
        ])
    }

    @Test("both unknown — no quick-action buttons at all")
    func bothUnknown() {
        let set = CaptureQuickActions.build(for: resolution(accountId: nil, categoryIsDefault: true))
        #expect(set.actions.isEmpty)
        #expect(set.userInfo.isEmpty)
    }

    /// The one branch the duplicate flag adds buttons to where there
    /// normally are none — a bare Delete, no "More options."
    @Test("both unknown + possible duplicate — just Delete")
    func bothUnknownDuplicate() {
        let set = CaptureQuickActions.build(
            for: resolution(accountId: nil, categoryIsDefault: true, isPossibleDuplicate: true)
        )
        #expect(set.actions.map(\.identifier) == [CaptureQuickActions.deleteActionId])
        #expect(set.userInfo.isEmpty)
    }

    @Test("fewer suggestions than slots still produces a valid, shorter button set")
    func fewerSuggestionsThanSlots() {
        let categories = [suggestion("Groceries")]
        let set = CaptureQuickActions.build(
            for: resolution(accountId: UUID().uuidString, categoryIsDefault: false, suggestedCategories: categories)
        )
        #expect(set.actions.map(\.identifier) == [
            CaptureQuickActions.confirmActionId, "capture.pick.0", CaptureQuickActions.moreActionId
        ])
    }
}
