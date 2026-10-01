import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The draft store's one job is that **nothing is lost when iOS kills the
/// app**, which it is free to do while the user is away in Shortcuts
/// building their automation. Every test here is a variation on that.
@Suite("Onboarding draft store")
@MainActor
struct OnboardingDraftStoreTests {
    /// A private suite of `UserDefaults` per test, so these never touch the
    /// simulator's real settings and never see each other's.
    private func makeDefaults() -> UserDefaults {
        let suite = "onboarding-draft-tests-\(UUID().uuidString)"
        // `UserDefaults(suiteName:)` only returns nil for a reserved name;
        // a fresh UUID is not one. Falling back to `.standard` would make a
        // failure here silently write to the real settings, so an empty
        // in-memory stand-in is the safer fallback.
        return UserDefaults(suiteName: suite) ?? UserDefaults()
    }

    @Test("a first run starts on the first step and is not a resume")
    func freshStart() {
        let store = OnboardingDraftStore(defaults: makeDefaults())
        #expect(store.draft.step == .profile)
        #expect(store.didResume == false)
    }

    /// The whole reason this type exists rather than `@State`.
    @Test("a draft survives the app being terminated mid-flow")
    func survivesTermination() {
        let defaults = makeDefaults()
        let first = OnboardingDraftStore(defaults: defaults)
        first.update {
            $0.step = .capture
            $0.displayName = "Manu"
            $0.baseCurrency = "EUR"
        }

        // A second store is what the next launch builds.
        let relaunched = OnboardingDraftStore(defaults: defaults)
        #expect(relaunched.draft.step == .capture)
        #expect(relaunched.draft.displayName == "Manu")
        #expect(relaunched.draft.baseCurrency == "EUR")
        #expect(relaunched.didResume)
    }

    /// Restoring onto the first step is a user who opened setup and went no
    /// further — telling them they are picking up where they left off would
    /// be telling them about a place they never left.
    @Test("stopping on the very first step is not a resume")
    func firstStepIsNotAResume() {
        let defaults = makeDefaults()
        OnboardingDraftStore(defaults: defaults).update { $0.displayName = "Manu" }
        #expect(OnboardingDraftStore(defaults: defaults).didResume == false)
    }

    @Test("every mutation is persisted, with no save step to forget")
    func mutationsPersist() {
        let defaults = makeDefaults()
        let store = OnboardingDraftStore(defaults: defaults)
        store.advance()
        store.advance()
        #expect(OnboardingDraftStore(defaults: defaults).draft.step == .account)
        store.goBack()
        #expect(OnboardingDraftStore(defaults: defaults).draft.step == .currency)
    }

    @Test("stepping past either end does nothing")
    func stepsClampAtBothEnds() {
        let store = OnboardingDraftStore(defaults: makeDefaults())
        store.goBack()
        #expect(store.draft.step == .profile)
        for _ in SetupStep.allCases { store.advance() }
        #expect(store.draft.step == .allSet)
        store.advance()
        #expect(store.draft.step == .allSet)
    }

    /// Once the commit succeeds everything in the draft is either on the
    /// server or on its way through the outbox, and a leftover would put a
    /// finished user back into setup on the next launch.
    @Test("clearing leaves nothing behind for the next launch")
    func clearingRemovesTheDraft() {
        let defaults = makeDefaults()
        let store = OnboardingDraftStore(defaults: defaults)
        store.update { $0.step = .dashboard }
        store.clear()

        #expect(store.draft.step == .profile)
        #expect(defaults.data(forKey: AppSettingsKeys.onboardingDraft) == nil)
        #expect(OnboardingDraftStore(defaults: defaults).didResume == false)
    }

    /// A draft written by an older build, or a hand-edited defaults plist,
    /// must not take the flow down with it.
    @Test("unreadable stored data falls back to a fresh draft")
    func corruptDataFallsBack() {
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AppSettingsKeys.onboardingDraft)
        let store = OnboardingDraftStore(defaults: defaults)
        #expect(store.draft.step == .profile)
        #expect(store.didResume == false)
    }
}
