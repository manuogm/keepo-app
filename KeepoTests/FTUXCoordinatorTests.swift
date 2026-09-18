import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The whole first-time experience: each coach mark's once-ever state,
/// which of the ones a screen is offering is allowed on screen, and the
/// switch that turns them back on.
@Suite("FTUX coordinator")
@MainActor
struct FTUXCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "ftux-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? UserDefaults()
    }

    /// `dismiss()` hands the next one off to an unstructured task, so a
    /// test that wants to see what follows has to wait out the same settle
    /// beat the user does.
    private func waitForNext() async {
        try? await Task.sleep(for: .milliseconds(900))
    }

    @Test("a fresh install has seen nothing and shows nothing yet")
    func freshStart() {
        let ftux = FTUXCoordinator(defaults: makeDefaults())
        for lesson in FTUXLessons.all {
            #expect(ftux.hasSeen(lesson) == false)
        }
        // They appear on a settle beat, not on construction — a coach mark
        // drawn before the screen it points at would point at nothing.
        #expect(ftux.visible == nil)
    }

    /// **Once ever.** Each teaches a gesture, and a gesture only needs
    /// teaching once — so dismissing has to be what records that, not
    /// showing.
    @Test("dismissing records it, and it never comes back on its own")
    func dismissIsOneShot() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())

        await ftux.offer([FTUXLessons.scope])
        #expect(ftux.isVisible(FTUXLessons.scope))

        ftux.dismiss()
        #expect(ftux.visible == nil)
        #expect(ftux.hasSeen(FTUXLessons.scope))

        await ftux.offer([FTUXLessons.scope])
        #expect(ftux.visible == nil)
    }

    /// **The screen offers a set; the order is the tour's.** Two coach
    /// marks on one screen are asked for by different parts of it — the
    /// Transactions ledger and its inbox drawer — so the sequence cannot
    /// depend on which asked first.
    @Test("the tour's order decides which of a screen's lessons goes first")
    func orderFollowsTheTour() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())

        await ftux.offer([FTUXLessons.widgets, FTUXLessons.scope])
        #expect(ftux.isVisible(FTUXLessons.scope))

        ftux.dismiss()
        await waitForNext()
        #expect(ftux.isVisible(FTUXLessons.widgets))
    }

    /// Leaving the screen ends what it was teaching: the tab underneath is
    /// gone, so the hole would be cut around nothing.
    @Test("clearing the queue stops the next one arriving")
    func clearingStopsTheQueue() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())

        await ftux.offer([FTUXLessons.scope, FTUXLessons.widgets])
        ftux.dismiss()
        ftux.clearQueue()
        await waitForNext()

        #expect(ftux.visible == nil)
        #expect(ftux.hasSeen(FTUXLessons.widgets) == false)
    }

    /// **The keys are per lesson.** One shared flag would mean the first
    /// coach mark a user met silently spent every other one.
    @Test("seeing one coach mark leaves the others unseen")
    func flagsAreIndependent() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())

        await ftux.offer([FTUXLessons.scope])
        ftux.dismiss()

        #expect(ftux.hasSeen(FTUXLessons.scope))
        #expect(ftux.hasSeen(FTUXLessons.accounts) == false)
        #expect(ftux.hasSeen(FTUXLessons.add) == false)

        ftux.clearQueue()
        await ftux.offer([FTUXLessons.accounts])
        #expect(ftux.isVisible(FTUXLessons.accounts))
    }

    /// A coach mark under a modal points at something the user cannot see,
    /// and would spend its one showing doing it.
    @Test("nothing is shown while a sheet is up")
    func suppressedByAModal() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())
        ftux.isModalPresented = true

        await ftux.offer([FTUXLessons.scope])
        #expect(ftux.visible == nil)
        #expect(ftux.hasSeen(FTUXLessons.scope) == false)

        // What the screen does when the sheet closes: ask again with what
        // it was already offering.
        ftux.isModalPresented = false
        await ftux.retry()
        #expect(ftux.isVisible(FTUXLessons.scope))
    }

    /// `dismiss(_:)` is what a host calls when the user performs the very
    /// gesture being taught. It must not take down somebody else's coach
    /// mark — the Accounts row reporting a drag while the scope mark is up
    /// would close a lesson the user has not read.
    @Test("dismissing by lesson only closes that lesson")
    func dismissByLessonIsScoped() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())

        await ftux.offer([FTUXLessons.scope])
        ftux.dismiss(FTUXLessons.accounts)
        #expect(ftux.isVisible(FTUXLessons.scope))
        #expect(ftux.hasSeen(FTUXLessons.accounts) == false)

        ftux.dismiss(FTUXLessons.scope)
        #expect(ftux.visible == nil)
    }

    /// Survives relaunch — the flag is the persisted half, the visibility
    /// is not.
    @Test("a dismissed coach mark stays dismissed across launches")
    func survivesRelaunch() async {
        let defaults = makeDefaults()
        let first = FTUXCoordinator(defaults: defaults)
        await first.offer([FTUXLessons.scope])
        first.dismiss()

        let second = FTUXCoordinator(defaults: defaults)
        #expect(second.hasSeen(FTUXLessons.scope))
        await second.offer([FTUXLessons.scope])
        #expect(second.visible == nil)
    }

    /// **Show Tips arms every one, and shows none of them.** The sheet it
    /// is pressed in covers the screen the first mark belongs to, and the
    /// other two are on tabs the user has not reached — so the button
    /// clears the flags and the screens do the rest.
    @Test("Show Tips arms every coach mark without showing one")
    func replayAllArmsEverything() async {
        let ftux = FTUXCoordinator(defaults: makeDefaults())
        await ftux.offer([FTUXLessons.scope])
        ftux.dismiss()
        #expect(ftux.hasSeen(FTUXLessons.scope))

        ftux.replayAll()
        for lesson in FTUXLessons.all {
            #expect(ftux.hasSeen(lesson) == false)
        }
        #expect(ftux.visible == nil)

        // What the sheet closing does: ask again with what the screen
        // underneath was already offering.
        await ftux.retry()
        #expect(ftux.isVisible(FTUXLessons.scope))
    }
}
