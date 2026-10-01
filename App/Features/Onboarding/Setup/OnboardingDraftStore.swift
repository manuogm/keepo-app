import Foundation
import KeepoCore
import Observation

/// Owns the setup flow's draft and its persistence — the same shape and the
/// same reasoning as `DashboardStore`: every mutation is written straight
/// back to disk, so there is no "save" step to forget and no in-memory copy
/// that can drift from what the next launch reads.
///
/// **Persistence here is not a nicety.** Setup step 4 sends the user to the
/// Shortcuts app to build an automation, and they are gone for minutes —
/// long enough that iOS may *terminate* Keepo rather than merely background
/// it. The flow this replaces held its progress in `@State`, so that
/// termination silently restarted setup from the beginning.
///
/// The draft holds a name, a photo and an account the user has described —
/// **none of which has reached the server**, and all of which is discarded
/// the moment the commit succeeds. `UserDefaults` is the right home for the
/// same documented reason the other device-local keys give: it is progress
/// state, not data about the user's money.
@Observable
@MainActor
final class OnboardingDraftStore {
    private(set) var draft: OnboardingDraft
    /// True when this launch restored a draft that was already in progress,
    /// so the flow can say "picking up where you left off" once — and only
    /// once, and only when it is true.
    let didResume: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard
            let data = defaults.data(forKey: AppSettingsKeys.onboardingDraft),
            let stored = try? JSONDecoder().decode(OnboardingDraft.self, from: data)
        else {
            self.draft = OnboardingDraft()
            self.didResume = false
            return
        }
        self.draft = stored
        // Restoring onto the first step is not a resume — it is a user who
        // opened setup, went no further, and would be told they were
        // somewhere they never left.
        self.didResume = stored.step != .profile
    }

    /// The one way the draft changes. A closure rather than a setter per
    /// field: eight screens editing ten fields would otherwise be eighty
    /// chances to mutate without persisting.
    func update(_ change: (inout OnboardingDraft) -> Void) {
        change(&draft)
        persist()
    }

    func advance() {
        guard let next = draft.step.next else { return }
        update { $0.step = next }
    }

    func goBack() {
        guard let previous = draft.step.previous else { return }
        update { $0.step = previous }
    }

    /// Called once the commit has actually succeeded. Everything in here is
    /// then either on the server or on its way through the outbox, and a
    /// leftover draft would put a finished user back into setup on the next
    /// launch.
    func clear() {
        draft = OnboardingDraft()
        defaults.removeObject(forKey: AppSettingsKeys.onboardingDraft)
        // Lives outside the draft — see the key's own comment — so it has to
        // be cleared alongside it, or replaying onboarding opens on a
        // checklist that is already ticked.
        defaults.removeObject(forKey: AppSettingsKeys.walkthroughCompleted)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: AppSettingsKeys.onboardingDraft)
    }
}
