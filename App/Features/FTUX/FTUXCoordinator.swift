import KeepoCore
import Observation
import SwiftUI
import TipKit

/// Owns the one-shot spotlight and the switch that turns it back on.
///
/// Small on purpose. Everything else the first-time experience does is
/// TipKit's job — eligibility, frequency, persistence, dismissal — and the
/// "reuse before writing" call here was to hand-roll only the one thing
/// TipKit genuinely cannot do (dim the screen and cut a hole in it) rather
/// than to build a coach-mark framework beside one that ships with the OS.
@Observable
@MainActor
final class FTUXCoordinator {
    /// Whether the spotlight is on screen right now.
    private(set) var isSpotlightVisible = false

    /// Long enough for the tab view to have drawn and the phase transition
    /// out of setup to have settled, short enough that it still reads as
    /// part of arriving rather than as something that appeared later.
    private static let settle = Duration.milliseconds(600)

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Tips are gated on the spotlight being finished — see
        // `LessonTip.rules`. Synced here so a returning user who closed it
        // long ago is not held behind a coach mark they will never see
        // again.
        LessonTip.isSpotlightDone = hasSeenSpotlight
    }

    var hasSeenSpotlight: Bool {
        defaults.bool(forKey: AppSettingsKeys.hasSeenScopeSpotlight)
    }

    /// Shows the spotlight once, ever — unless "Show me around" has asked
    /// for it again.
    func showSpotlightIfNeeded() async {
        guard !hasSeenSpotlight, !isSpotlightVisible else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }
        isSpotlightVisible = true
    }

    func dismissSpotlight() {
        isSpotlightVisible = false
        defaults.set(true, forKey: AppSettingsKeys.hasSeenScopeSpotlight)
        // Releases the just-in-time tips. They stay silent until the one
        // mandatory thing is out of the way.
        LessonTip.isSpotlightDone = true
    }

    /// The replay, from Profile → Help & Support. Shows it immediately
    /// rather than on the next settle: the user just asked for it, so there
    /// is nothing to wait for.
    func replaySpotlight() {
        defaults.set(false, forKey: AppSettingsKeys.hasSeenScopeSpotlight)
        isSpotlightVisible = true
        // Holds the tips back again for as long as it is up, for the same
        // reason they were held back the first time.
        LessonTip.isSpotlightDone = false
    }

    /// The lesson the spotlight teaches. Read from `FTUXLessons` rather
    /// than written here, so the spotlight and the "Show me around" screen
    /// cannot describe the same gesture differently.
    var spotlightLesson: FTUXLesson { FTUXLessons.scope }
}

/// TipKit, configured once at launch.
///
/// **`displayFrequency(.hourly)` is the whole answer to §3.11's objection.**
/// Six things worth teaching, taught in a row, is six more screens for
/// someone who has just finished eight — so they are spread out instead. A
/// user exploring in one sitting meets one tip; the rest arrive on later
/// visits, each on the screen it is about. It is one line because TipKit
/// already owns eligibility, frequency and persistence, which is exactly
/// why the tips are TipKit's and only the spotlight is ours.
enum KeepoTipsConfiguration {
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.hourly),
            .datastoreLocation(.applicationDefault)
        ])
    }
}
