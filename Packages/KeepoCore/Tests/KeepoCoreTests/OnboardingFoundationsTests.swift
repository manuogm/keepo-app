import Foundation
import Testing
@testable import KeepoCore

@Suite("DefaultCategoryCatalog")
struct DefaultCategoryCatalogTests {
    /// `categories_one_default_per_kind` means the backend's seeded "Other"
    /// is the only default that can exist — offering a second would be
    /// offering a row the database refuses.
    @Test("the catalogue never offers an Other")
    func noOtherCategory() {
        #expect(!DefaultCategoryCatalog.all.contains { $0.name.localizedCaseInsensitiveCompare("Other") == .orderedSame })
    }

    @Test("every key appears exactly once")
    func keysAreUnique() {
        let keys = DefaultCategoryCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(Set(keys) == Set(DefaultCategoryKey.allCases))
    }

    /// The colours a category is given at setup and the colours the icon
    /// catalogue offers must be the same set, or a category made here can
    /// never be recoloured to match one made later.
    @Test("every colour comes from the shared palette")
    func coloursComeFromThePalette() {
        for category in DefaultCategoryCatalog.all {
            #expect(CategoryAppearance.palette.contains(category.color), "\(category.name) is off-palette")
        }
    }

    @Test("kinds are split the way the two tabs expect")
    func kindsAreSplitCorrectly() {
        #expect(DefaultCategoryCatalog.expenses.allSatisfy { $0.kind == .expense })
        #expect(DefaultCategoryCatalog.income.allSatisfy { $0.kind == .income })
        #expect(DefaultCategoryCatalog.expenses.count == 14)
        #expect(DefaultCategoryCatalog.income.count == 9)
    }

    @Test("everything preselected is really in the catalogue")
    func preselectedResolves() {
        for key in DefaultCategoryCatalog.preselected {
            #expect(DefaultCategoryCatalog.category(for: key) != nil)
        }
    }
}

@Suite("OnboardingDraft")
struct OnboardingDraftTests {
    /// The draft is persisted across an app *termination* — iOS may kill
    /// Keepo while the user is away in Shortcuts — so a round trip through
    /// JSON is the actual contract, not an implementation detail.
    @Test("round-trips through JSON unchanged")
    func roundTrips() throws {
        var draft = OnboardingDraft()
        draft.step = .capture
        draft.baseCurrency = "EUR"
        draft.account = DraftAccount(name: "Checking", currency: "EUR", openingBalanceE4: 1_250_000)
        draft.selectedMetrics = [.netWorth, .cashflow]
        draft.walkthroughStep = 2

        let decoded = try JSONDecoder().decode(OnboardingDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded == draft)
    }

    @Test("a fresh draft starts on the first step with the common categories")
    func freshDraftDefaults() {
        let draft = OnboardingDraft()
        #expect(draft.step == .currency)
        #expect(draft.selectedCategories == DefaultCategoryCatalog.preselected)
        // Net Worth is always present — a dashboard with nothing on it is
        // the one outcome the Dashboard step must not be able to produce.
        #expect(draft.selectedMetrics == [.netWorth])
    }

    /// `.currency` has nothing but a default — its Skip would have been
    /// Next wearing a different label. `.account` is skippable: Skip there
    /// means no account yet, and the app's empty state picks it up.
    @Test("only the currency step offers no Skip")
    func stepsWithoutASkip() {
        for step in SetupStep.allCases {
            #expect(step.isSkippable == (step != .currency))
        }
    }

    @Test("the progress dots count only the steps with something to answer")
    func progressStepsExcludeTheEnding() {
        #expect(SetupStep.progressSteps.count == 5)
        #expect(!SetupStep.progressSteps.contains(.committing))
        #expect(!SetupStep.progressSteps.contains(.allSet))
    }

    @Test("stepping forward and back walks the whole flow")
    func stepNavigation() {
        #expect(SetupStep.currency.previous == nil)
        #expect(SetupStep.allSet.next == nil)
        var step = SetupStep.currency
        var visited = [step]
        while let next = step.next {
            step = next
            visited.append(step)
        }
        #expect(visited == SetupStep.allCases)
    }

    /// A draft saved on the removed profile step names step 0, which no case
    /// has any more — it must fail to decode (the store then starts clean)
    /// rather than land the user on a different screen.
    @Test("a draft saved on the removed profile step does not decode")
    func removedProfileStepDoesNotDecode() throws {
        let encoded = try JSONEncoder().encode(OnboardingDraft())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["step"] = 0
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OnboardingDraft.self, from: json) }
    }

    /// The raw values are what a persisted draft names its step by, so a
    /// user mid-flow when the app updates must land on the same screen.
    @Test("step raw values are stable")
    func rawValuesAreStable() {
        #expect(SetupStep.currency.rawValue == 1)
        #expect(SetupStep.capture.rawValue == 3)
        #expect(SetupStep.allSet.rawValue == 7)
    }
}

/// The install link is the one part of onboarding that could break with no
/// code changing, so the redirect in front of it is worth pinning.
@Suite("Shortcut install link")
struct ShortcutInstallLinkTests {
    /// Prefers the Edge Function, so a dead share link is a
    /// `supabase secrets set` rather than an App Store release.
    @Test("a configured project points at the capture-shortcut redirect")
    func prefersTheRedirect() throws {
        let base = try #require(URL(string: "https://abcdefgh.supabase.co"))
        let url = try #require(ShortcutsWalkthrough.installURL(functionsBaseURL: base))
        #expect(url.absoluteString == "https://abcdefgh.supabase.co/functions/v1/capture-shortcut")
    }

    /// A build with no configuration must still show a working button —
    /// which is the whole reason the literal link survives.
    @Test("no project falls back to the published iCloud link")
    func fallsBackToICloud() {
        let url = ShortcutsWalkthrough.installURL(functionsBaseURL: nil)
        #expect(url?.absoluteString == ShortcutsWalkthrough.installURLString)
    }

    /// Renaming one without the other leaves every new user's install
    /// button on a 404, and nothing in the app would say so.
    @Test("the function name matches the folder under supabase/functions")
    func functionNameIsStable() {
        #expect(ShortcutsWalkthrough.redirectFunctionName == "capture-shortcut")
    }

    /// The fallback is what the Edge Function itself defaults to, so the
    /// two cannot drift into pointing at different shortcuts.
    @Test("the fallback is still an iCloud shortcut link")
    func fallbackShape() {
        #expect(ShortcutsWalkthrough.installURLString.hasPrefix("https://www.icloud.com/shortcuts/"))
    }
}
