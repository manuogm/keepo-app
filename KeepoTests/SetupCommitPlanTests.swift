import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// Six screens of draft become a profile patch, an account, some
/// categories and a dashboard. This is the translation, and it is where
/// the mistakes would be invisible: a category filed under the wrong kind
/// or a selection order quietly sorted looks fine in a screenshot and is
/// wrong forever afterwards.
@Suite("Setup commit plan")
struct SetupCommitPlanTests {
    private let userId = UUID()

    private func draft(_ change: (inout OnboardingDraft) -> Void = { _ in }) -> OnboardingDraft {
        var value = OnboardingDraft(baseCurrency: "EUR")
        value.account = DraftAccount(
            name: "Checking", kind: .regular, currency: "EUR",
            openingBalanceE4: 1_250_7500, icon: "banknote.fill", color: "#34C759"
        )
        change(&value)
        return value
    }

    /// `onboarded_requires_base_currency` is a CHECK. A plan that cannot
    /// satisfy it must not exist, rather than producing a patch the
    /// database rejects with an error the user cannot act on.
    @Test("a draft with no base currency is not committable")
    func requiresBaseCurrency() {
        var value = draft()
        value.baseCurrency = nil
        #expect(SetupCommitPlan.make(draft: value, userId: userId) == nil)
    }

    // MARK: - The name

    /// `profiles_display_name_length` allows null but refuses the empty
    /// string, so "skipped the profile step" has to be absence.
    @Test("a skipped or blank name commits as nothing, never as an empty string")
    func blankNameIsAbsent() {
        for raw in [nil, "", "   ", "\n"] as [String?] {
            let plan = SetupCommitPlan.make(draft: draft { $0.displayName = raw }, userId: userId)
            #expect(plan?.displayName == nil)
        }
    }

    @Test("a name is trimmed, not rejected, for the whitespace around it")
    func nameIsTrimmed() {
        let plan = SetupCommitPlan.make(draft: draft { $0.displayName = "  Manu " }, userId: userId)
        #expect(plan?.displayName == "Manu")
    }

    /// The field caps typing at 60; this is the backstop for a draft
    /// restored from a build that did not.
    @Test("a name past the column's ceiling is clamped rather than failing the patch")
    func nameIsClamped() {
        let plan = SetupCommitPlan.make(draft: draft { $0.displayName = String(repeating: "a", count: 90) },
                                        userId: userId)
        #expect(plan?.displayName?.count == 60)
    }

    // MARK: - The account

    /// The id has to survive a retry, or a commit that failed halfway and
    /// was tried again leaves two accounts behind.
    @Test("the account keeps the id the draft minted")
    func accountIdComesFromTheDraft() {
        let id = UUID()
        let value = draft { $0.account?.id = id }
        let plan = SetupCommitPlan.make(draft: value, userId: userId)
        #expect(plan?.account?.id == id)
        // And again, from the same draft — a retry is the same row.
        #expect(SetupCommitPlan.make(draft: value, userId: userId)?.account?.id == id)
    }

    @Test("the account carries everything the user described")
    func accountFields() throws {
        let account = try #require(SetupCommitPlan.make(draft: draft(), userId: userId)?.account)
        #expect(account.ownerId == userId)
        #expect(account.name == "Checking")
        #expect(account.kind == .regular)
        #expect(account.currency == "EUR")
        #expect(account.openingBalanceE4 == 1_250_7500)
        #expect(account.icon == "banknote.fill")
        #expect(account.color == "#34C759")
    }

    /// Unreachable from the UI — the step's Next stays disabled until the
    /// account has a name — but an account row named `""` would be worse
    /// than none at all.
    @Test("an unnamed account is no account")
    func unnamedAccountIsDropped() {
        #expect(SetupCommitPlan.make(draft: draft { $0.account?.name = "  " }, userId: userId)?.account == nil)
    }

    /// An account in a currency other than the base one is the case
    /// Feature 3 sells, so it must survive the translation untouched.
    @Test("an account in a currency other than the base one keeps its own")
    func foreignAccountCurrency() {
        let value = draft { $0.account?.currency = "JPY" }
        let plan = SetupCommitPlan.make(draft: value, userId: userId)
        #expect(plan?.baseCurrency == "EUR")
        #expect(plan?.account?.currency == "JPY")
    }

    // MARK: - Categories

    @Test("categories come out in the order they were chosen, with the catalogue's own icon and colour")
    func categoriesMapFromTheCatalogue() throws {
        let keys: [DefaultCategoryKey] = [.salary, .groceries, .pets]
        let plan = try #require(SetupCommitPlan.make(draft: draft { $0.selectedCategories = keys },
                                                     userId: userId))
        #expect(plan.categories.map(\.name) == ["Salary", "Groceries", "Pets"])
        #expect(plan.categories.map(\.kind) == [.income, .expense, .expense])
        #expect(plan.categories.map(\.icon) == ["banknote.fill", "cart.fill", "pawprint.fill"])
        #expect(plan.categories.allSatisfy { $0.ownerId == userId })
    }

    @Test("every category gets its own id")
    func categoryIdsAreDistinct() {
        let plan = SetupCommitPlan.make(draft: draft { $0.selectedCategories = DefaultCategoryKey.allCases },
                                        userId: userId)
        let ids = Set(plan?.categories.map(\.id) ?? [])
        #expect(ids.count == DefaultCategoryKey.allCases.count)
    }

    /// Skipping the categories step means the two `Other` rows the backend
    /// already seeded at signup, and nothing else.
    @Test("no categories chosen writes no categories")
    func noCategories() {
        let plan = SetupCommitPlan.make(draft: draft { $0.selectedCategories = [] }, userId: userId)
        #expect(plan?.categories.isEmpty == true)
    }

    // MARK: - The dashboard

    /// Order is the hierarchy — `DashboardArrangement.append` fills reading
    /// order — so a sort here would silently rearrange the dashboard the
    /// user just built.
    @Test("widgets keep their selection order")
    func widgetOrderIsPreserved() {
        let kinds: [DashboardWidgetKind] = [.netWorth, .cashflow, .investingRatio]
        let plan = SetupCommitPlan.make(draft: draft { $0.selectedMetrics = kinds }, userId: userId)
        #expect(plan?.widgets == kinds)
    }

    /// The dashboard holds one widget per kind; two of one would be a
    /// duplicate tile the catalogue could never have produced.
    @Test("a repeated widget kind is dropped, keeping the first place it was chosen")
    func widgetsAreDeduplicated() {
        let plan = SetupCommitPlan.make(
            draft: draft { $0.selectedMetrics = [.netWorth, .cashflow, .netWorth] }, userId: userId
        )
        #expect(plan?.widgets == [.netWorth, .cashflow])
    }

    // MARK: - Skipping everything skippable

    /// Profile skipped, categories skipped, dashboard left at its seed:
    /// the flow still produces a committable plan, because the account and
    /// the currency are the only two things it genuinely needs.
    @Test("a run that skipped everything it could still commits")
    func minimalRun() throws {
        var value = draft()
        value.displayName = nil
        value.avatarJPEG = nil
        value.selectedCategories = []
        let plan = try #require(SetupCommitPlan.make(draft: value, userId: userId))
        #expect(plan.displayName == nil)
        #expect(plan.avatarJPEG == nil)
        #expect(plan.categories.isEmpty)
        #expect(plan.account != nil)
        #expect(plan.baseCurrency == "EUR")
    }
}
