import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The one piece of the first-time experience Keepo owns rather than
/// TipKit: the scope-banner spotlight's once-ever state, and the switch
/// that turns it back on.
@Suite("FTUX coordinator")
@MainActor
struct FTUXCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "ftux-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? UserDefaults()
    }

    @Test("a fresh install has not seen the spotlight and shows nothing yet")
    func freshStart() {
        let ftux = FTUXCoordinator(defaults: makeDefaults())
        #expect(ftux.hasSeenSpotlight == false)
        // It appears on a settle beat, not on construction — a coach mark
        // drawn before the screen it points at would point at nothing.
        #expect(ftux.isSpotlightVisible == false)
    }

    /// **Once ever.** It teaches a gesture, and a gesture only needs
    /// teaching once — so dismissing has to be what records that, not
    /// showing.
    @Test("dismissing records it, and it never comes back on its own")
    func dismissIsOneShot() async {
        let defaults = makeDefaults()
        let ftux = FTUXCoordinator(defaults: defaults)

        await ftux.showSpotlightIfNeeded()
        #expect(ftux.isSpotlightVisible)

        ftux.dismissSpotlight()
        #expect(ftux.isSpotlightVisible == false)
        #expect(ftux.hasSeenSpotlight)

        await ftux.showSpotlightIfNeeded()
        #expect(ftux.isSpotlightVisible == false)
    }

    /// Survives relaunch — the flag is the persisted half, the visibility
    /// is not.
    @Test("a dismissed spotlight stays dismissed across launches")
    func survivesRelaunch() async {
        let defaults = makeDefaults()
        let first = FTUXCoordinator(defaults: defaults)
        await first.showSpotlightIfNeeded()
        first.dismissSpotlight()

        let second = FTUXCoordinator(defaults: defaults)
        #expect(second.hasSeenSpotlight)
        await second.showSpotlightIfNeeded()
        #expect(second.isSpotlightVisible == false)
    }

    /// "Show me around" shows it immediately rather than on the next settle
    /// beat: the user just asked, so there is nothing to wait for.
    @Test("Show me around replays it at once, and it can be dismissed again")
    func replayIsImmediate() {
        let defaults = makeDefaults()
        let ftux = FTUXCoordinator(defaults: defaults)
        ftux.dismissSpotlight()
        #expect(ftux.hasSeenSpotlight)

        ftux.replaySpotlight()
        #expect(ftux.isSpotlightVisible)
        #expect(ftux.hasSeenSpotlight == false)

        ftux.dismissSpotlight()
        #expect(ftux.hasSeenSpotlight)
    }

    /// The coach mark and the tour must describe the same gesture, so the
    /// spotlight reads its copy from `FTUXLessons` rather than carrying its
    /// own.
    @Test("the spotlight teaches the tour's own scope lesson")
    func spotlightUsesTheSharedLesson() {
        let ftux = FTUXCoordinator(defaults: makeDefaults())
        #expect(ftux.spotlightLesson == FTUXLessons.scope)
    }
}
